#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only FLOW-01E signing inventory. Lists Developer ID Application
identities and provisioning-profile names relevant to the Flow Probe bundles.
Never imports/deletes profiles, touches Keychain items, signs code or changes networking.
"""
from __future__ import annotations
import os, plistlib, platform, re, subprocess, sys
from pathlib import Path

APP_ID = "io.github.xiaodou997.VPNSplitter.FlowProbe"
EXT_ID = "io.github.xiaodou997.VPNSplitter.FlowProbeExtension"
NE_VALUE = "app-proxy-provider-systemextension"
PROFILE_ROOTS = [
    Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
    Path.home() / "Library/MobileDevice/Provisioning Profiles",
]

def developer_identities(text: str) -> list[str]:
    values = []
    for line in text.splitlines():
        match = re.search(r'"(Developer ID Application:[^"]+)"', line)
        if match and match.group(1) not in values:
            values.append(match.group(1))
    return values

def profile_matches(profile: dict, bundle_id: str, team: str | None = None) -> bool:
    name = profile.get("Name")
    entitlements = profile.get("Entitlements")
    if not isinstance(name, str) or not isinstance(entitlements, dict):
        return False
    values = entitlements.get("com.apple.developer.networking.networkextension")
    if not isinstance(values, list) or NE_VALUE not in values:
        return False
    teams = profile.get("TeamIdentifier")
    if team and (not isinstance(teams, list) or team not in teams):
        return False
    identifier = entitlements.get("application-identifier") or entitlements.get("com.apple.application-identifier")
    return isinstance(identifier, str) and identifier.endswith("." + bundle_id)

def installed_profiles(team: str | None = None) -> tuple[list[str], list[str]]:
    app, ext = [], []
    security = "/usr/bin/security"
    seen = set()
    for root in PROFILE_ROOTS:
        if root.is_symlink() or not root.is_dir():
            continue
        for path in root.iterdir():
            try:
                if path.is_symlink() or not path.is_file() or path.stat().st_size > 1_048_576:
                    continue
                data = subprocess.check_output([security, "cms", "-D", "-i", str(path)],
                                               stderr=subprocess.DEVNULL, timeout=5)
                profile = plistlib.loads(data)
            except (OSError, subprocess.SubprocessError, plistlib.InvalidFileException, ValueError):
                continue
            name = profile.get("Name")
            if not isinstance(name, str) or name in seen or any(ord(ch) < 32 for ch in name) or len(name) > 256:
                continue
            if profile_matches(profile, APP_ID, team):
                app.append(name); seen.add(name)
            elif profile_matches(profile, EXT_ID, team):
                ext.append(name); seen.add(name)
    return sorted(app), sorted(ext)

def main(argv: list[str] | None = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-id")
    args = parser.parse_args(argv)
    if args.team_id and not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        parser.error("--team-id must be exactly 10 uppercase letters/digits")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        print("E_PLATFORM: macOS Apple Silicon required; read_only=true", file=sys.stderr); return 69
    if os.getuid() == 0 or os.geteuid() == 0:
        print("E_RUN_AS_ROOT: ordinary user required; read_only=true", file=sys.stderr); return 77
    try:
        identity_text = subprocess.check_output(
            ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
            text=True, stderr=subprocess.STDOUT, timeout=15)
        identities = developer_identities(identity_text)
        app, ext = installed_profiles(args.team_id)
        print("schema=external-flow-signing-preflight-v1")
        print("read_only=true")
        print("developer_id_identities=" + str(len(identities)))
        for index, value in enumerate(identities, 1): print(f"identity[{index}]={value}")
        print("app_profiles=" + str(len(app)))
        for index, value in enumerate(app, 1): print(f"app_profile[{index}]={value}")
        print("extension_profiles=" + str(len(ext)))
        for index, value in enumerate(ext, 1): print(f"extension_profile[{index}]={value}")
        ready = bool(identities and app and ext)
        print("signing_inventory=" + ("READY" if ready else "INCOMPLETE"))
        print("keychain_changes=NONE\nprofile_changes=NONE\nnetwork_settings=NOT_APPLIED")
        return 0 if ready else 3
    except (OSError, subprocess.SubprocessError):
        print("E_FLOW_SIGNING_PREFLIGHT: inventory failed; no settings changed", file=sys.stderr)
        return 2

if __name__ == "__main__":
    raise SystemExit(main())
