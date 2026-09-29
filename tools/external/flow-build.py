#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Compile the FLOW-01 transparent-proxy probe candidate. Never install, start or sign it."""
from __future__ import annotations
import fcntl, os, platform, signal, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def swift_arguments(root: Path, run: Path, sdk: str) -> list[str]:
    return ['/usr/bin/xcrun', 'swift', 'build', '--package-path', str(root / 'Packages/ExternalFlow'),
            '--scratch-path', str(run / 'swift-build'), '--configuration', 'debug',
            '--triple', 'arm64-apple-macosx26.0', '--sdk', sdk, '--product', 'ExternalFlowProvider',
            '-Xswiftc', '-warnings-as-errors']

def compile_once(arguments: list[str], log) -> None:
    child = subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        result = child.wait(timeout=600)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait(); raise
    if result: raise subprocess.CalledProcessError(result, arguments)

def main() -> int:
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        print('E_PLATFORM: FLOW-01 compile probe requires macOS 26+ Apple Silicon; execution=NOT_RUN', file=sys.stderr)
        return 69
    if os.getuid() == 0 or os.geteuid() == 0:
        print('E_BUILD_AS_ROOT: ordinary user required', file=sys.stderr); return 77
    run = None; lock = None
    try:
        def output(command): return subprocess.check_output(command, text=True, timeout=30).strip()
        if int(output(['/usr/bin/sw_vers', '-productVersion']).split('.')[0]) < 26: raise ValueError('OS')
        if int(output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version']).split('.')[0]) < 26: raise ValueError('SDK')
        sdk = output(['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path'])
        for folder in (ROOT / '.local', ROOT / '.local/external'):
            if folder.is_symlink(): raise ValueError('path')
            folder.mkdir(mode=0o700, exist_ok=True)
        lock = os.open(ROOT / '.local/external/build.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run = Path(tempfile.mkdtemp(prefix='flow.', dir=ROOT / '.local/external'))
        args = swift_arguments(ROOT, run, sdk)
        with (run / 'build.log').open('wb') as log: compile_once(args, log)
        print('schema=external-flow-build-v1')
        print('compile=PASS')
        print('execution=NOT_RUN')
        print('network_settings=NOT_APPLIED')
        print('provider_bundle=NOT_CREATED')
        print('extension_activation=NOT_REQUESTED')
        print('flow_copying=NOT_IMPLEMENTED')
        print('Local results: ' + str(run))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print('E_EXTERNAL_FLOW_BUILD: compile failed; no provider was installed or started', file=sys.stderr)
        if run: print('Local build log: ' + str(run / 'build.log'), file=sys.stderr)
        return 2
    finally:
        if lock is not None: os.close(lock)

if __name__ == '__main__':
    os.umask(0o077)
    raise SystemExit(main())
