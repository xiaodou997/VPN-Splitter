#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build the finite foreground External executor. Never run it or acquire root.
No installed helper, launch service, extension activation or dependency download.
"""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def swift_arguments(root: Path, run: Path, sdk: str) -> list[str]:
    return ['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(root / 'Packages/ExternalExecution'),
            '--scratch-path', str(run / 'swift-build'), '--configuration', 'debug',
            '--triple', 'arm64-apple-macosx26.0', '--sdk', sdk, '--product', 'VPNExternalLease',
            '-Xswiftc', '-warnings-as-errors', '-Xcc', '-Wall', '-Xcc', '-Wextra', '-Xcc', '-Werror']

def compile_once(arguments: list[str], log) -> None:
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
    argparse.ArgumentParser(description=__doc__).parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        print('E_PLATFORM: requires macOS 26+ Apple Silicon; execution=NOT_RUN', file=sys.stderr)
        return 69
    if os.getuid() == 0 or os.geteuid() == 0:
        print('E_BUILD_AS_ROOT: build with your ordinary user account.', file=sys.stderr)
        return 77
    run = None
    lock = None
    try:
        version = subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True, timeout=10).strip()
        sdk_version = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True, timeout=10).strip()
        if int(version.split('.')[0]) < 26 or int(sdk_version.split('.')[0]) < 26:
            raise ValueError('E_PLATFORM')
        sdk = subprocess.check_output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True, timeout=10).strip()
        for directory in (ROOT / '.local', ROOT / '.local/external'):
            if directory.is_symlink(): raise ValueError('E_PATH')
            directory.mkdir(mode=0o700, exist_ok=True)
        lock = os.open(ROOT / '.local/external/build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = Path(tempfile.mkdtemp(prefix='executor.', dir=ROOT / '.local/external'))
        arguments = swift_arguments(ROOT, run, sdk)
        with (run / 'build.log').open('wb') as log:
            compile_once(arguments, log)
        binary_dir = subprocess.check_output(arguments + ['--show-bin-path'], text=True, timeout=60).strip().splitlines()[-1]
        source = Path(binary_dir) / 'VPNExternalLease'
        if source.is_symlink() or not source.is_file(): raise ValueError('E_EXECUTABLE')
        target = run / 'VPNExternalLease'
        shutil.copy2(source, target)
        arch = subprocess.check_output(['/usr/bin/xcrun', 'lipo', '-archs', str(target)], text=True, timeout=30).strip()
        if arch != 'arm64': raise ValueError('E_ARCH')
        # The arm64 linker may already have signed the executable. Replace only
        # this run's newly copied artifact, never the SwiftPM source or an installed tool.
        # Local ad-hoc identity is not authority for a privileged GUI service.
        with (run / 'build.log').open('ab') as log:
            for command in (
                ['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(target)],
                ['/usr/bin/codesign', '--verify', '--strict', str(target)]
            ):
                log.write(('\n$ ' + shlex.join(command) + '\n').encode('utf-8')); log.flush()
                subprocess.run(command, check=True, timeout=30, stdout=log, stderr=subprocess.STDOUT)
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        (run / 'artifact.sha256').write_text(digest + '\n')
        print('schema=external-executor-build-v1\ncompile=PASS\nexecution=NOT_RUN\nnetwork_settings=NOT_APPLIED\nhelper_installation=NOT_REQUESTED')
        print('Executable: ' + str(target))
        print('sha256=' + digest)
        print('Foreground engineering candidate only; see docs/external-execution.md before any real apply.')
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print('E_EXTERNAL_EXECUTOR_BUILD: build failed; executable not run.', file=sys.stderr)
        if run: print('Local build log: ' + str(run / 'build.log'), file=sys.stderr)
        return 2
    finally:
        if lock is not None: os.close(lock)

if __name__ == '__main__':
    os.umask(0o077)
    raise SystemExit(main())
