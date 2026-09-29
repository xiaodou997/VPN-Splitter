#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build an in-bundle SMAppService candidate. Never install/register/run or elevate.
Default ad-hoc output is compile evidence only and cannot authenticate to the Helper.
Signing and the finite route trial are separate explicit build options.
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
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP_ID = 'io.github.xiaodou997.VPNSplitter.ExternalControl'
HELPER_ID = 'io.github.xiaodou997.VPNSplitter.ExternalHelper'
SERVICE = HELPER_ID + '.v1'

def launch_plist() -> dict:
    return {'Label': SERVICE, 'BundleProgram': 'Contents/Library/LaunchServices/VPNExternalHelper',
            'MachServices': {SERVICE: True}, 'RunAtLoad': False, 'KeepAlive': False,
            'ProcessType': 'Interactive', 'ExitTimeOut': 180}

def swift_arguments(root: Path, run: Path, sdk: str, helper: bool, trial: bool) -> list[str]:
    arguments = ['/usr/bin/xcrun', 'swift', 'build', '--package-path',
                 str(root / 'Packages' / ('ExternalExecution' if helper else 'ExternalCore')),
                 '--scratch-path', str(run / ('helper-build' if helper else 'app-build')),
                 '--configuration', 'debug', '--triple', 'arm64-apple-macosx26.0', '--sdk', sdk,
                 '--product', 'VPNExternalHelper' if helper else 'VPNExternalPreview',
                 '-Xswiftc', '-warnings-as-errors', '-Xcc', '-Wall', '-Xcc', '-Wextra', '-Xcc', '-Werror']
    if helper and trial:
        arguments += ['-Xswiftc', '-DEXTERNAL_HELPER_ROUTE_TRIAL']
    return arguments

def compile_once(arguments: list[str], log) -> None:
    child = subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        result = child.wait(timeout=600)
    except (subprocess.TimeoutExpired, KeyboardInterrupt):
        try: os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        child.wait(); raise
    if result: raise subprocess.CalledProcessError(result, arguments)

def requirement(identifier: str, team: str) -> str:
    text = f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "{team}"'
    for name in ['get-task-allow', 'cs.disable-library-validation', 'cs.allow-dyld-environment-variables', 'cs.allow-unsigned-executable-memory']:
        text += f' and ! (entitlement["com.apple.security.{name}"] exists)'
    return text

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity'); parser.add_argument('--team-id'); parser.add_argument('--route-trial', action='store_true')
    args = parser.parse_args()
    if bool(args.identity) != bool(args.team_id) or (args.team_id and not re.fullmatch('[A-Z0-9]{10}', args.team_id)):
        parser.error('--identity and a 10-character --team-id must be supplied together')
    if args.identity == '-' or (args.route_trial and not args.identity):
        parser.error('a real signing identity is required for --route-trial; ad-hoc is the no-option default')
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        print('E_PLATFORM: macOS 26+ Apple Silicon required; execution=NOT_RUN', file=sys.stderr); return 69
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
        run = Path(tempfile.mkdtemp(prefix='control.', dir=ROOT / '.local/external'))
        app = run / 'VPN-Splitter-ExternalControl.app'
        destinations = [app / 'Contents/MacOS/VPNExternalPreview', app / 'Contents/Library/LaunchServices/VPNExternalHelper']
        with (run / 'build.log').open('wb') as log:
            for helper, target in zip([False, True], destinations):
                command = swift_arguments(ROOT, run, sdk, helper, args.route_trial)
                compile_once(command, log)
                folder = Path(output(command + ['--show-bin-path']).splitlines()[-1])
                source = folder / target.name
                if source.is_symlink() or not source.is_file(): raise ValueError('artifact')
                target.parent.mkdir(parents=True, mode=0o700); shutil.copy2(source, target)
                if output(['/usr/bin/xcrun', 'lipo', '-archs', str(target)]) != 'arm64': raise ValueError('architecture')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': APP_ID, 'CFBundleExecutable': 'VPNExternalPreview', 'CFBundlePackageType': 'APPL',
                'CFBundleName': 'VPN-Splitter External Control', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '0.1',
                'LSMinimumSystemVersion': '26.0', 'NSPrincipalClass': 'NSApplication', 'NSHighResolutionCapable': True}))
            daemon = app / 'Contents/Library/LaunchDaemons' / (SERVICE + '.plist')
            daemon.parent.mkdir(parents=True, mode=0o700); daemon.write_bytes(plistlib.dumps(launch_plist()))
            for target, identifier in [(destinations[1], HELPER_ID), (app, APP_ID)]:
                command = ['/usr/bin/codesign', '--force', '--sign', args.identity or '-', '--timestamp=none',
                           '--options', 'runtime', '--identifier', identifier, str(target)]
                commands = [command, ['/usr/bin/codesign', '--verify', '--strict', str(target)]]
                if args.identity: commands.append(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement(identifier, args.team_id), str(target)])
                for command in commands:
                    log.write(('\n$ ' + shlex.join(command) + '\n').encode()); log.flush()
                    subprocess.run(command, check=True, timeout=60, stdout=log, stderr=subprocess.STDOUT)
        hashes = '\n'.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p.relative_to(app)) for p in destinations)
        (run / 'artifacts.sha256').write_text(hashes + '\n')
        print('schema=external-helper-build-v1\ncompile=PASS\nexecution=NOT_RUN\nnetwork_settings=NOT_APPLIED\nhelper_installation=NOT_REQUESTED')
        print('signing=' + ('LOCAL_IDENTITY_VERIFIED' if args.identity else 'ADHOC_NOT_AUTHORIZED'))
        print('route_trial=' + ('COMPILED_EXPLICIT_OPT_IN' if args.route_trial else 'DISABLED'))
        print('App: ' + str(app)); print('Local results: ' + str(run))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError):
        print('E_EXTERNAL_HELPER_BUILD: failed; no artifact executed or service registered', file=sys.stderr)
        if run: print('Local build log: ' + str(run / 'build.log'), file=sys.stderr)
        return 2
    finally:
        if lock is not None: os.close(lock)

if __name__ == '__main__':
    os.umask(0o077)
    raise SystemExit(main())
