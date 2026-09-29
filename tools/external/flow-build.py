#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the FLOW-01E App + Transparent Proxy system-extension candidate.
Default is unsigned compile/link only. --sign requires explicit Developer ID
identity, Team ID and separate provisioning profiles. Never install, copy to
/Applications, open, activate, save Network Extension preferences or change networking.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/external"))
from flow_project import generate

APP_ID = "io.github.xiaodou997.VPNSplitter.FlowProbe"
EXT_ID = "io.github.xiaodou997.VPNSplitter.FlowProbeExtension"
NE_VALUE = "app-proxy-provider-systemextension"

def bounded_text(value: str | None, label: str) -> str:
    if value is None or not (1 <= len(value) <= 256) or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError(label)
    return value

def parse_args(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sign", action="store_true")
    parser.add_argument("--identity")
    parser.add_argument("--team-id")
    parser.add_argument("--app-profile")
    parser.add_argument("--extension-profile")
    args = parser.parse_args(argv)
    supplied = [args.identity, args.team_id, args.app_profile, args.extension_profile]
    if args.sign:
        if any(value is None for value in supplied):
            parser.error("--sign requires --identity, --team-id, --app-profile and --extension-profile")
        try:
            bounded_text(args.identity, "identity")
            bounded_text(args.app_profile, "app-profile")
            bounded_text(args.extension_profile, "extension-profile")
        except ValueError as error:
            parser.error(str(error) + " contains invalid characters or length")
        if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id or ""):
            parser.error("--team-id must be exactly 10 uppercase letters/digits")
    elif any(value is not None for value in supplied):
        parser.error("signing arguments require --sign")
    return args

def run_checked(command: list[str], *, timeout: int = 60, text: bool = True):
    return subprocess.run(command, check=True, timeout=timeout, capture_output=True, text=text)

def codesign_fields(path: Path) -> dict[str, str]:
    result = run_checked(["/usr/bin/codesign", "-d", "--verbose=4", str(path)])
    text = (result.stdout or "") + "\n" + (result.stderr or "")
    values = {}
    for line in text.splitlines():
        if line.startswith("Identifier="): values["identifier"] = line.split("=", 1)[1].strip()
        elif line.startswith("TeamIdentifier="): values["team"] = line.split("=", 1)[1].strip()
        elif line.startswith("Timestamp="): values["timestamp"] = line.split("=", 1)[1].strip()
    if "identifier" not in values or "team" not in values:
        raise ValueError("codesign-metadata")
    return values

def codesign_entitlements(path: Path) -> dict:
    result = run_checked(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(path)], text=False)
    candidates = [result.stdout or b"", result.stderr or b"", (result.stdout or b"") + (result.stderr or b"")]
    for data in candidates:
        start = data.find(b"<?xml")
        end = data.rfind(b"</plist>")
        if start >= 0 and end >= start:
            return plistlib.loads(data[start:end + len(b"</plist>")])
    raise ValueError("codesign-entitlements")

def verify_signed(path: Path, *, identifier: str, team: str, app: bool) -> None:
    run_checked(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(path)])
    fields = codesign_fields(path)
    if fields["identifier"] != identifier or fields["team"] != team:
        raise ValueError("codesign-identity")
    if not fields.get("timestamp"):
        raise ValueError("secure-timestamp")
    entitlements = codesign_entitlements(path)
    values = entitlements.get("com.apple.developer.networking.networkextension")
    if not isinstance(values, list) or NE_VALUE not in values:
        raise ValueError("networkextension-entitlement")
    if app and entitlements.get("com.apple.developer.system-extension.install") is not True:
        raise ValueError("systemextension-install-entitlement")
    if not app and entitlements.get("com.apple.developer.system-extension.install") is True:
        raise ValueError("extension-unexpected-install-entitlement")

def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        print("E_PLATFORM: FLOW-01E requires macOS 26+ Apple Silicon; execution=NOT_RUN", file=sys.stderr)
        return 69
    if os.getuid() == 0 or os.geteuid() == 0:
        print("E_BUILD_AS_ROOT: ordinary user required", file=sys.stderr); return 77
    run = None; lock = None
    try:
        def output(command): return subprocess.check_output(command, text=True, timeout=30).strip()
        if int(output(["/usr/bin/sw_vers", "-productVersion"]).split(".")[0]) < 26: raise ValueError("OS")
        if int(output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"]).split(".")[0]) < 26: raise ValueError("SDK")
        for folder in (ROOT / ".local", ROOT / ".local/external"):
            if folder.is_symlink(): raise ValueError("path")
            folder.mkdir(mode=0o700, exist_ok=True)
        lock = os.open(ROOT / ".local/external/build.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = Path(tempfile.mkdtemp(prefix="flow.", dir=ROOT / ".local/external"))
        project = generate(ROOT, run)
        configuration = "DeveloperID" if args.sign else "Release"
        log_path = run / "build.log"
        command = ["/usr/bin/xcodebuild", "-project", str(project), "-target", "VPN-Splitter-FlowProbe",
                   "-configuration", configuration, "-sdk", "macosx", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
                   "SYMROOT=" + str(run / "Products"), "OBJROOT=" + str(run / "Intermediates"),
                   "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO"]
        if args.sign:
            command += [
                "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=YES",
                "FLOW_DEVELOPMENT_TEAM=" + args.team_id,
                "FLOW_DEVELOPER_ID_IDENTITY=" + args.identity,
                "FLOW_APP_PROFILE_SPECIFIER=" + args.app_profile,
                "FLOW_EXTENSION_PROFILE_SPECIFIER=" + args.extension_profile,
            ]
        else:
            command += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
        with log_path.open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        if result.returncode:
            raise subprocess.CalledProcessError(result.returncode, command)

        app = run / "Products" / configuration / "VPN-Splitter-FlowProbe.app"
        extensions = list((app / "Contents/Library/SystemExtensions").glob("*.systemextension"))
        if len(extensions) != 1 or extensions[0].is_symlink(): raise ValueError("extension")
        extension = extensions[0]
        if extension.name != EXT_ID + ".systemextension": raise ValueError("extension-filename")
        info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleIdentifier") != EXT_ID: raise ValueError("extension-bundle-id")
        classes = info.get("NetworkExtension", {}).get("NEProviderClasses", {})
        if classes.get("com.apple.networkextension.app-proxy") != "ExternalFlowProvider.ExternalTransparentProbeProvider":
            raise ValueError("provider-class")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or Path(executable).name != executable: raise ValueError("executable")
        binary = extension / "Contents/MacOS" / executable
        if binary.is_symlink() or not binary.is_file(): raise ValueError("binary")
        if output(["/usr/bin/xcrun", "lipo", "-archs", str(binary)]) != "arm64": raise ValueError("arch")

        app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if app_info.get("CFBundleIdentifier") != APP_ID: raise ValueError("app-bundle-id")
        if args.sign:
            verify_signed(extension, identifier=EXT_ID, team=args.team_id, app=False)
            verify_signed(app, identifier=APP_ID, team=args.team_id, app=True)

        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        signing = "LOCAL_DEVELOPER_ID_VERIFIED" if args.sign else "UNSIGNED"
        result_text = (
            "schema=external-flow-build-v3\n"
            "compile_link=PASS\n"
            "execution=NOT_RUN\n"
            "network_settings=NOT_APPLIED\n"
            "extension_activation=NOT_REQUESTED\n"
            f"signing={signing}\n"
            "system_acceptance=NOT_RUN\n"
            "provider_roundtrip=NOT_RUN\n"
            "flow_copying=NOT_IMPLEMENTED\n"
            f"extension_sha256={digest}\n"
        )
        (run / "result.txt").write_text(result_text)
        print(result_text, end="")
        print("App: " + str(app))
        print("Local results: " + str(run))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("E_EXTERNAL_FLOW_BUILD: build/sign verification failed; no provider was installed or activated", file=sys.stderr)
        if run: print("Local build log: " + str(run / "build.log"), file=sys.stderr)
        return 2
    finally:
        if lock is not None: os.close(lock)

if __name__ == "__main__":
    os.umask(0o077)
    raise SystemExit(main())
