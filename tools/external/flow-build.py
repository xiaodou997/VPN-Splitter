#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the FLOW-01B App + Transparent Proxy system-extension candidate unsigned.
Never install, activate, open, register a configuration, or modify networking.
"""
from __future__ import annotations
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/external"))
from flow_project import generate

def main() -> int:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        print("E_PLATFORM: FLOW-01B requires macOS 26+ Apple Silicon; execution=NOT_RUN", file=sys.stderr)
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
        log_path = run / "build.log"
        command = ["/usr/bin/xcodebuild", "-project", str(project), "-target", "VPN-Splitter-FlowProbe",
                   "-configuration", "Release", "-sdk", "macosx", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO",
                   "SYMROOT=" + str(run / "Products"), "OBJROOT=" + str(run / "Intermediates"),
                   "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
                   "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", "build"]
        with log_path.open("wb") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1200)
        if result.returncode: raise subprocess.CalledProcessError(result.returncode, command)
        app = run / "Products/Release/VPN-Splitter-FlowProbe.app"
        extensions = list((app / "Contents/Library/SystemExtensions").glob("*.systemextension"))
        if len(extensions) != 1 or extensions[0].is_symlink(): raise ValueError("extension")
        info = plistlib.loads((extensions[0] / "Contents/Info.plist").read_bytes())
        classes = info.get("NetworkExtension", {}).get("NEProviderClasses", {})
        if classes.get("com.apple.networkextension.app-proxy") != "ExternalFlowProvider.ExternalTransparentProbeProvider":
            raise ValueError("provider-class")
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or Path(executable).name != executable: raise ValueError("executable")
        binary = extensions[0] / "Contents/MacOS" / executable
        if binary.is_symlink() or not binary.is_file(): raise ValueError("binary")
        if output(["/usr/bin/xcrun", "lipo", "-archs", str(binary)]) != "arm64": raise ValueError("arch")
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        (run / "result.txt").write_text(
            "schema=external-flow-build-v2\ncompile_link=PASS\nexecution=NOT_RUN\n"
            "network_settings=NOT_APPLIED\nextension_activation=NOT_REQUESTED\n"
            "signing=UNSIGNED\nflow_copying=NOT_IMPLEMENTED\n"
            f"extension_sha256={digest}\n"
        )
        print("schema=external-flow-build-v2")
        print("compile_link=PASS")
        print("execution=NOT_RUN")
        print("network_settings=NOT_APPLIED")
        print("extension_activation=NOT_REQUESTED")
        print("signing=UNSIGNED")
        print("flow_copying=NOT_IMPLEMENTED")
        print("App: " + str(app))
        print("Local results: " + str(run))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print("E_EXTERNAL_FLOW_BUILD: build failed; no provider was installed or activated", file=sys.stderr)
        if run: print("Local build log: " + str(run / "build.log"), file=sys.stderr)
        return 2
    finally:
        if lock is not None: os.close(lock)

if __name__ == "__main__":
    os.umask(0o077)
    raise SystemExit(main())
