#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the read-only External preview. No developer identity, extension, Helper or Go.
Only 'run' opens the newly built local app; it reads no system network state before a button press.
"""
from __future__ import annotations
import argparse
import fcntl
import os
from pathlib import Path
import platform
import plistlib
import shutil
import shlex
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def swift_arguments(root: Path, run: Path, sdk: str) -> list[str]:
    return ['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(root / 'Packages/ExternalCore'),
            '--scratch-path', str(run / 'swift-build'), '--configuration', 'debug',
            '--triple', 'arm64-apple-macosx26.0', '--sdk', sdk, '--product', 'VPNExternalPreview',
            '-Xswiftc', '-warnings-as-errors']

def compile_once(arguments: list[str], log) -> None:
    # Retain the build lease until this process group has stopped, including timeout.
    process = subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        result = process.wait(timeout=600)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait()
        raise
    if result:
        raise subprocess.CalledProcessError(result, arguments)

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['build', 'run'], default='build', nargs='?')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        print('E_PLATFORM: External preview requires macOS 26+ on Apple Silicon.', file=sys.stderr)
        return 69
    if os.getuid() == 0 or os.geteuid() == 0:
        print('E_BUILD_AS_ROOT: use an ordinary user account.', file=sys.stderr)
        return 77
    run = None
    lock = None
    try:
        version = subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True, timeout=10).strip()
        sdk_version = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True, timeout=10).strip()
        if int(version.split('.')[0]) < 26 or int(sdk_version.split('.')[0]) < 26:
            raise ValueError('E_SDK: requires macOS and SDK 26+. No tools are installed automatically.')
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=10).strip()
        for directory in (ROOT / '.local', ROOT / '.local/external'):
            if directory.is_symlink(): raise ValueError('E_PATH: symlink output directory refused')
            directory.mkdir(mode=0o700, exist_ok=True)
        lock = os.open(ROOT / '.local/external/build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = Path(tempfile.mkdtemp(prefix='build.', dir=ROOT / '.local/external'))
        arguments = swift_arguments(ROOT, run, sdk)
        # Only local Swift packages; no --fetch mode or remote package is added.
        with (run / 'build.log').open('wb') as log:
            compile_once(arguments, log)
        binary_dir = subprocess.check_output(arguments + ['--show-bin-path'], text=True, timeout=60).strip().splitlines()[-1]
        source = Path(binary_dir) / 'VPNExternalPreview'
        if source.is_symlink() or not source.is_file(): raise ValueError('E_ARTIFACT: executable missing')
        app = run / 'VPN-Splitter-ExternalPreview.app'
        executable = app / 'Contents/MacOS/VPNExternalPreview'
        executable.parent.mkdir(parents=True, mode=0o700)
        shutil.copy2(source, executable)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'io.github.xiaodou997.VPNSplitter.ExternalPreview',
            'CFBundleName': 'VPN-Splitter External Preview', 'CFBundleExecutable': 'VPNExternalPreview',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1',
            'LSMinimumSystemVersion': '26.0', 'NSPrincipalClass': 'NSApplication',
            'NSHighResolutionCapable': True
        }))
        # Local development identity only; this app has NO privileged entitlement or extension.
        # Replace only this run's new bundle copy, as for the foreground executor.
        with (run / 'build.log').open('ab') as log:
            for command in (
                ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(app)],
                ['/usr/bin/codesign', '--verify', '--strict', str(app)]
            ):
                log.write(('\n$ ' + shlex.join(command) + '\n').encode('utf-8')); log.flush()
                subprocess.run(command, check=True, timeout=30, stdout=log, stderr=subprocess.STDOUT)
        print('schema=external-preview-build-v1\ncompile=PASS\nnetwork_settings=NOT_APPLIED\nextension_activation=NOT_REQUESTED')
        print('App: ' + str(app))
        if args.mode == 'run':
            subprocess.run(['/usr/bin/open', str(app)], check=True, timeout=30)
            print('open=REQUESTED; native UI and network observation are not verified by this build.')
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print('E_EXTERNAL_BUILD: build/open failed; no network settings were changed.', file=sys.stderr)
        if run: print('Local build log: ' + str(run / 'build.log'), file=sys.stderr)
        return 2
    finally:
        if lock is not None: os.close(lock)  # Never delete the cooperating-writer lock.

if __name__ == '__main__':
    os.umask(0o077)
    raise SystemExit(main())
