#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate macOS AppIcon sets and the in-app brand mascot from the branding webp files.

Single source of truth for app icon assets. The repository currently ships the
mascot only as 256x256 optimized WebP files; this script upscales the
native-style owl into a full-bleed 1024x1024 master (background flood-filled so
no white margin survives), then derives every macOS icon size. When a true
high-resolution original becomes available, drop it in and re-run this script.

Usage: python3 tools/branding/generate_appicons.py
No network access. Writes only into the two apps' Assets.xcassets catalogs.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
BRANDING = ROOT / "assets" / "branding"
MACOS_ICON_WEBP = BRANDING / "mascot-owl-macos.webp"
FLAT_MASCOT_WEBP = BRANDING / "mascot-owl.webp"
MAIN_CATALOG = ROOT / "apps" / "macos" / "App" / "Assets.xcassets"
LOCALDEV_CATALOG = ROOT / "apps" / "macos" / "LocalDev" / "Assets.xcassets"

# macOS AppIcon sizes (points) and their @2x counterparts.
ICON_SIZES_PT = [16, 32, 128, 256, 512]
MASTER_SIZE = 1024
BG_THRESHOLD = 40  # distance from near-white background that counts as content
# The glossy highlight band is only slightly darker than the page; 70 lets the
# flood reach the owl's outlines (which block it) so the fill hugs the artwork.
FLOOD_THRESHOLD = 70
FLOOD_FRACTION_GUARD = 0.28  # above this the flood likely leaked into artwork


def fail(message: str) -> "NoReturn":  # noqa: F821 - kept simple for a dev tool
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def load_source(path: Path) -> Image.Image:
    if not path.is_file():
        fail(f"missing source image: {path}")
    image = Image.open(path).convert("RGB")
    if image.size != (256, 256):
        fail(f"unexpected source size {image.size} for {path.name}; regenerate manually")
    return image


def content_square(image: Image.Image) -> tuple[int, int, int, int]:
    """Locate the icon's rounded square despite the white owl, glossy highlight
    and soft drop shadow baked into the optimized WebP.

    The mid-row scan gives a clean width (purple bands flank the white face).
    The bottom edge is the last row that is almost full-width content; the top
    follows from the square assumption. Returns a (slightly conservative)
    square crop box that keeps the anti-aliased edge inside the content.
    """
    array = np.asarray(image).astype(np.int16)
    background = np.median(
        np.concatenate([array[0, :], array[-1, :], array[:, 0], array[:, -1]]),
        axis=0,
    )
    distance = np.abs(array - background).max(axis=2)
    content = distance > BG_THRESHOLD

    mid = image.height // 2
    xs = np.where(content[mid])[0]
    if len(xs) == 0:
        fail("could not locate the icon square in the source image")
    left, right = int(xs.min()), int(xs.max())
    side = right - left + 1
    center_x = (left + right) // 2
    x0 = min(max(center_x - side // 2, 0), image.width - side)

    # Anchor the bottom edge on the deep-purple content (the soft shadow and
    # anti-aliasing below it stay outside the crop).
    strong = distance > 80
    ys = np.where(strong[:, center_x])[0]
    if len(ys) == 0:
        fail("could not locate the icon square bottom edge")
    y1 = min(int(ys.max()) + 2, image.height)
    y0 = y1 - side
    if y0 < 0:
        y0, y1 = 0, side
    return x0, y0, x0 + side, y0 + side


def _flood(array: np.ndarray, background: np.ndarray, threshold: int) -> np.ndarray:
    distance = np.abs(array - background).max(axis=2)
    page = distance <= threshold
    span = array.max(axis=2) - array.min(axis=2)
    mean = array.mean(axis=2)
    shadow = (span <= 18) & (mean <= background.mean() - 14) & (mean > 40)
    near = page | shadow

    mask = np.zeros(near.shape, dtype=bool)
    mask[0, :] = near[0, :]
    mask[-1, :] = near[-1, :]
    mask[:, 0] = near[:, 0]
    mask[:, -1] = near[:, -1]
    while True:
        grown = mask.copy()
        padded = np.pad(mask, 1, mode="constant", constant_values=False)
        neighbors = np.zeros_like(mask)
        for dy in range(3):
            for dx in range(3):
                if dy == 1 and dx == 1:
                    continue
                neighbors |= padded[dy : dy + mask.shape[0], dx : dx + mask.shape[1]]
        grown |= neighbors & near
        if grown.sum() == mask.sum():
            break
        mask = grown
    return mask, distance


def flood_background(image: Image.Image) -> np.ndarray:
    """Mask of pixels connected to the border that still look like background.

    Background is the near-white page and glossy highlight band plus the soft
    gray drop shadow baked below the icon (neutral, slightly darker than the
    page). The owl's interior whites are blocked by its dark outlines; the
    fraction guard bails to a conservative threshold if that ever changes.
    """
    array = np.asarray(image).astype(np.int16)
    background = np.median(
        np.concatenate([array[0, :], array[-1, :], array[:, 0], array[:, -1]]),
        axis=0,
    )
    mask, distance = _flood(array, background, FLOOD_THRESHOLD)
    if mask.mean() > FLOOD_FRACTION_GUARD:
        mask, distance = _flood(array, background, 45)

    # Absorb the anti-aliased fringe inside each corner window so no off-white
    # speckle survives next to the planar fill. The owl artwork stays outside
    # these windows and its outlines exceed the distance threshold anyway.
    height, width = mask.shape
    window = min(52, height // 4, width // 4)
    fringe = distance <= 48
    corners = [
        (slice(0, window), slice(0, window)),
        (slice(0, window), slice(width - window, width)),
        (slice(height - window, height), slice(0, window)),
        (slice(height - window, height), slice(width - window, width)),
    ]
    for rows, cols in corners:
        mask[rows, cols] |= fringe[rows, cols]

    # Straight edges: absorb the anti-aliased border columns/rows so no light
    # fringe line survives along the sides. Only background gradient lives in
    # these strips; the owl artwork is well inside the crop.
    edge = distance <= 150
    strip = 4
    mask[:strip, :] |= edge[:strip, :]
    mask[-strip:, :] |= edge[-strip:, :]
    mask[:, :strip] |= edge[:, :strip]
    mask[:, -strip:] |= edge[:, -strip:]
    return mask


def _dilate(mask: np.ndarray, iterations: int) -> np.ndarray:
    grown = mask.copy()
    for _ in range(iterations):
        padded = np.pad(grown, 1, mode="constant", constant_values=False)
        neighbors = np.zeros_like(grown)
        for dy in range(3):
            for dx in range(3):
                if dy == 1 and dx == 1:
                    continue
                neighbors |= padded[dy : dy + grown.shape[0], dx : dx + grown.shape[1]]
        grown |= neighbors
    return grown


def _erode(mask: np.ndarray, iterations: int) -> np.ndarray:
    return ~_dilate(~mask, iterations)


def fill_background(image: Image.Image, mask: np.ndarray) -> Image.Image:
    """Extend the design gradient into the masked border region.

    Iterative averaging from solid design anchors (the anti-aliased fringe is
    already part of the mask, so the anchors are real background tones). This
    hugs outlines such as the owl's ears without letting artwork contaminate
    the fill. The mask boundary ring is feathered afterwards so the seam
    dissolves into the design.
    """
    array = np.asarray(image).astype(np.float64)
    current = array.copy()
    for _ in range(2000):
        padded = np.pad(current, ((1, 1), (1, 1), (0, 0)), mode="edge")
        total = np.zeros_like(current)
        for dy, dx in ((0, 1), (2, 1), (1, 0), (1, 2)):
            total += padded[dy : dy + current.shape[0], dx : dx + current.shape[1]]
        updated = current.copy()
        updated[mask] = (total[mask] / 4.0)
        delta = np.abs(updated[mask] - current[mask]).max()
        current = updated
        if delta < 0.02:
            break
    result = np.where(mask[..., None], current, array)

    filled_image = Image.fromarray(np.clip(result, 0, 255).astype(np.uint8), "RGB")
    ring = _dilate(mask, 2) & ~_erode(mask, 1)
    if ring.any():
        blurred = np.asarray(filled_image.filter(ImageFilter.GaussianBlur(1.6))).astype(np.float64)
        combined = np.asarray(filled_image).astype(np.float64)
        combined[ring] = 0.45 * combined[ring] + 0.55 * blurred[ring]
        filled_image = Image.fromarray(np.clip(combined, 0, 255).astype(np.uint8), "RGB")
    return filled_image


def full_bleed_master(image: Image.Image) -> Image.Image:
    box = content_square(image)
    cropped = image.crop(box)
    mask = flood_background(cropped)
    filled = fill_background(cropped, mask)
    # Slight inset already handled by the straight-edge crop; upscale to master.
    master = filled.resize((MASTER_SIZE, MASTER_SIZE), Image.LANCZOS)
    # Gentle unsharp mask to counter 4x upscale softness.
    master = master.filter(ImageFilter.UnsharpMask(radius=2.2, percent=58, threshold=2))
    return master


def draw_dev_badge(master: Image.Image) -> Image.Image:
    """Overlay a compact DEV badge so LocalDev stays distinguishable."""
    size = master.width
    badge_w, badge_h = int(size * 0.34), int(size * 0.165)
    margin = int(size * 0.035)
    radius = int(badge_h * 0.32)
    x0 = size - margin - badge_w
    y0 = size - margin - badge_h
    canvas = master.convert("RGBA")
    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    draw.rounded_rectangle(
        [x0, y0, x0 + badge_w, y0 + badge_h],
        radius=radius,
        fill=(26, 14, 71, 242),
        outline=(255, 255, 255, 235),
        width=max(2, int(size * 0.008)),
    )
    font_size = int(badge_h * 0.58)
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", font_size, index=1)
    text = "DEV"
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    bbox = probe.textbbox((0, 0), text, font=font)
    text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx = x0 + (badge_w - text_w) // 2 - bbox[0]
    ty = y0 + (badge_h - text_h) // 2 - bbox[1]
    draw.text((tx, ty), text, font=font, fill=(255, 255, 255, 255))
    return Image.alpha_composite(canvas, overlay).convert("RGB")


def write_appiconset(master: Image.Image, appiconset: Path) -> None:
    appiconset.mkdir(parents=True, exist_ok=True)
    entries = []
    for points in ICON_SIZES_PT:
        for scale in (1, 2):
            pixels = points * scale
            filename = f"icon_{points}x{points}.png" if scale == 1 else f"icon_{points}x{points}@2x.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(appiconset / filename)
            entries.append(
                {
                    "size": f"{points}x{points}",
                    "idiom": "mac",
                    "filename": filename,
                    "scale": f"{scale}x",
                }
            )
    contents = {"images": entries, "info": {"version": 1, "author": "xcode"}}
    (appiconset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_brand_mascot(catalog: Path) -> None:
    source = load_source(FLAT_MASCOT_WEBP)
    imageset = catalog / "BrandMascot.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    scales = [(128, "mascot-owl-128.png"), (256, "mascot-owl-256.png"), (384, "mascot-owl-384.png")]
    for pixels, filename in scales:
        source.resize((pixels, pixels), Image.LANCZOS).save(imageset / filename)
    contents = {
        "images": [
            {"idiom": "universal", "filename": "mascot-owl-128.png", "scale": "1x"},
            {"idiom": "universal", "filename": "mascot-owl-256.png", "scale": "2x"},
            {"idiom": "universal", "filename": "mascot-owl-384.png", "scale": "3x"},
        ],
        "info": {"version": 1, "author": "xcode"},
    }
    (imageset / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_catalog_contents(catalog: Path) -> None:
    catalog.mkdir(parents=True, exist_ok=True)
    contents = {"info": {"version": 1, "author": "xcode"}}
    (catalog / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def main() -> None:
    source = load_source(MACOS_ICON_WEBP)
    master = full_bleed_master(source)

    write_catalog_contents(MAIN_CATALOG)
    write_appiconset(master, MAIN_CATALOG / "AppIcon.appiconset")
    write_brand_mascot(MAIN_CATALOG)

    write_catalog_contents(LOCALDEV_CATALOG)
    write_appiconset(draw_dev_badge(master), LOCALDEV_CATALOG / "AppIcon.appiconset")

    print("main app icon set ->", MAIN_CATALOG / "AppIcon.appiconset")
    print("localdev icon set ->", LOCALDEV_CATALOG / "AppIcon.appiconset")
    print("brand mascot ->", MAIN_CATALOG / "BrandMascot.imageset")


if __name__ == "__main__":
    main()
