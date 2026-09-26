#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""WG-INT-10: build the actual App/System Extension with the locked packetFlow backend.
Default is unsigned. --sign explicitly builds Release using local signing configuration.
Never install/open/activate, start a tunnel, alter Keychain, or change system networking.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
from runtime_project import generate

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/wireguard"))
import build as engine
from packet_flow_assets import require_packet_flow_symbols


def fingerprint() -> dict[str, str]:
    paths = []
    for directory in ("Packages", "integrations/wireguard", "apps/macos/App", "apps/macos/PacketTunnel"):
        paths.extend((ROOT / directory).rglob("*.swift"))
    # Exclude compiler outputs; no user data or private signing files are read here.
    return {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if not any(x in p.parts for x in (".build", ".local")) and not p.is_symlink()}

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true")
    parser.add_argument("--sign", action="store_true")
    args = parser.parse_args(); run = None
    try:
        lock = json.loads(engine.LOCK_PATH.read_text())
        env = engine.clean_environment(); commands = engine.Commands(env)
        tools = engine.preflight(commands, lock)
        engine.private_directory(ROOT / ".local")
        output = ROOT / ".local/wireguard-engine"; engine.private_directory(output)
        with engine.build_lock(output / "build.lock"):
            run = Path(tempfile.mkdtemp(prefix="provider.", dir=output))
            before = fingerprint()
            for name in ("gopath", "gocache", "gomodcache"): engine.private_directory(output / name)
            env.update(GOPATH=str(output / "gopath"), GOCACHE=str(output / "gocache"),
                       GOMODCACHE=str(output / "gomodcache"), GIT_CEILING_DIRECTORIES=str(output))
            commands = engine.Commands(env, run / "build.log")
            candidate = engine.build(commands, lock, tools, output, run, args.fetch, packet_flow=True)
            (run / "engine-result.json").write_text(json.dumps(candidate, indent=2) + "\n")
            project = generate(ROOT, run)
            arguments = ["/usr/bin/xcodebuild", "-project", str(project), "-target", "VPN-Splitter",
                "-configuration", "Release", "-sdk", "macosx", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
                "SYMROOT=" + str(run / "Products"), "OBJROOT=" + str(run / "Intermediates"),
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "build"]
            if not args.sign: arguments += ["CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"]
            commands.run(arguments, timeout=1200)
            app = run / "Products/Release/VPN-Splitter.app"
            extensions = list((app / "Contents/Library/SystemExtensions").glob("*.systemextension"))
            if len(extensions) != 1 or extensions[0].is_symlink(): raise ValueError("E_RUNTIME_EXTENSION")
            info = plistlib.loads((extensions[0] / "Contents/Info.plist").read_bytes())
            name = info.get("CFBundleExecutable")
            if not isinstance(name, str) or Path(name).name != name: raise ValueError("E_RUNTIME_EXECUTABLE")
            binary = extensions[0] / "Contents/MacOS" / name
            if binary.is_symlink() or not binary.is_file(): raise ValueError("E_RUNTIME_EXECUTABLE")
            if commands.run(["/usr/bin/xcrun", "lipo", "-archs", str(binary)]) != "arm64": raise ValueError("E_RUNTIME_ARCH")
            symbols = commands.run(["/usr/bin/xcrun", "nm", "-gU", str(binary)])
            require_packet_flow_symbols(symbols)
            if before != fingerprint(): raise ValueError("E_RUNTIME_SOURCE_CHANGED_DURING_BUILD")
            if args.sign:
                for bundle in (extensions[0], app):
                    commands.run(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(bundle)])
            result = dict(schema="provider-runtime-build-v1", provider_compile_link="PASS", artifact=str(app),
                signed_build=args.sign, signature_acceptance="NOT_RUN", execution="NOT_RUN",
                network_settings="NOT_APPLIED", extension_activation="NOT_REQUESTED", sources=before,
                extension_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
            (run / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            print("schema=provider-runtime-build-v1\nprovider_compile_link=PASS\nartifact_execution=NOT_RUN\nnetwork_settings=NOT_APPLIED\nextension_activation=NOT_REQUESTED")
            print("App: " + str(app)); print("Local results: " + str(run))
            if not args.sign: print("Unsigned compile only. Do not install or activate this artifact.")
            return 0
    except (engine.BuildError, ValueError, OSError, KeyError) as error:
        print("Provider build failed: " + str(error), file=sys.stderr)
        if run:
            (run / "failure.txt").write_text(type(error).__name__ + ": " + str(error) + "\n")
            print("Local failure results: " + str(run), file=sys.stderr)
        return 2

if __name__ == "__main__":
    os.umask(0o077)
    raise SystemExit(main())
