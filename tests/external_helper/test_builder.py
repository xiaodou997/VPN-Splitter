# SPDX-License-Identifier: MIT
"""Actual builder orchestration/files; compiler, lipo and codesign are explicit doubles.
No installed application, launch daemon, authorization prompt or network is touched.
"""
import ast
from contextlib import ExitStack, redirect_stdout, redirect_stderr
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[2]
FILE = ROOT / 'tools/external/helper-build.py'

def builder():
    spec = importlib.util.spec_from_file_location('external_helper_builder', FILE)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

class HelperBuildTests(unittest.TestCase):
    def test_build_plan_is_bundled_and_trial_is_explicit(self):
        b = builder(); root = Path('/synthetic repo'); run = Path('/synthetic run')
        for helper in [False, True]:
            for trial in [False, True]:
                args = b.swift_arguments(root, run, '/synthetic sdk', helper, trial)
                self.assertEqual('-DEXTERNAL_HELPER_ROUTE_TRIAL' in args, helper and trial)
                self.assertIn('-warnings-as-errors', args); self.assertNotIn('run', args)
        p = b.launch_plist()
        self.assertEqual(p['MachServices'], {b.SERVICE: True}); self.assertFalse(p['KeepAlive'])
        self.assertFalse(p['RunAtLoad']); self.assertNotIn('Program', p)
        self.assertEqual(p['BundleProgram'], 'Contents/Library/LaunchServices/VPNExternalHelper')
        ast.parse(FILE.read_text(), feature_version=(3, 9))

    def run_builder(self, signed=False, fail=None):
        b = builder()
        with tempfile.TemporaryDirectory(prefix='external-helper-build-test-') as directory:
            root = Path(directory); commands = []
            def compile_once(args, log):
                product = args[args.index('--product') + 1]
                folder = root / 'synthetic-bin' / product; folder.mkdir(parents=True)
                (folder / product).write_bytes(('SYNTHETIC_NOT_MACHO:' + product).encode())
                commands.append(args); log.write(b'compiler-double\n')
            def output(args, **kwargs):
                if args[0] == '/usr/bin/sw_vers': return '26.0\n'
                if '--show-sdk-version' in args: return '26.0\n'
                if '--show-sdk-path' in args: return '/synthetic sdk\n'
                if '--show-bin-path' in args:
                    return str(root / 'synthetic-bin' / args[args.index('--product') + 1]) + '\n'
                if 'lipo' in args: return 'arm64\n'
                raise AssertionError('unexpected tool: ' + str(args))
            def codesign(args, **kwargs):
                self.assertEqual(args[0], '/usr/bin/codesign')
                commands.append(args); kwargs['stdout'].write(b'codesign-double\n')
                if fail and fail in args: raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0)
            stdout = io.StringIO(); stderr = io.StringIO()
            argv = ['helper-build.py'] + (['--identity', 'Synthetic Identity', '--team-id', 'ABCDE12345', '--route-trial'] if signed else [])
            with ExitStack() as stack:
                stack.enter_context(patch.object(b, 'ROOT', root)); stack.enter_context(patch.object(sys, 'argv', argv))
                stack.enter_context(patch.object(b.platform, 'system', return_value='Darwin'))
                stack.enter_context(patch.object(b.platform, 'machine', return_value='arm64'))
                stack.enter_context(patch.object(b.os, 'getuid', return_value=501)); stack.enter_context(patch.object(b.os, 'geteuid', return_value=501))
                stack.enter_context(patch.object(b, 'compile_once', side_effect=compile_once))
                stack.enter_context(patch.object(b.subprocess, 'check_output', side_effect=output))
                stack.enter_context(patch.object(b.subprocess, 'run', side_effect=codesign))
                stack.enter_context(redirect_stdout(stdout)); stack.enter_context(redirect_stderr(stderr))
                code = b.main()
            self.assertEqual(len([c for c in commands if 'swift' in c]), 2)
            artifacts = list(root.glob('.local/external/control.*/artifacts.sha256'))
            if fail:
                self.assertEqual(code, 2); self.assertNotIn('compile=PASS', stdout.getvalue()); self.assertEqual(artifacts, [])
                self.assertIn('failed', stderr.getvalue())
            else:
                self.assertEqual(code, 0, stderr.getvalue()); self.assertEqual(len(artifacts), 1)
                self.assertIn('helper_installation=NOT_REQUESTED', stdout.getvalue())
                self.assertIn('execution=NOT_RUN', stdout.getvalue())
                app = artifacts[0].parent / 'VPN-Splitter-ExternalControl.app'
                self.assertEqual(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier'], b.APP_ID)
                p = app / 'Contents/Library/LaunchDaemons' / (b.SERVICE + '.plist')
                self.assertEqual(plistlib.loads(p.read_bytes()), b.launch_plist())
                if signed:
                    requirements = [c for c in commands if '-R' in c]
                    self.assertEqual(len(requirements), 2)
                    self.assertTrue(all('ABCDE12345' in c[c.index('-R') + 1] for c in requirements))
                else:
                    self.assertIn('route_trial=DISABLED', stdout.getvalue())
                    self.assertIn('signing=ADHOC_NOT_AUTHORIZED', stdout.getvalue())
            self.assertFalse(any('/usr/bin/open' in c or 'sudo' in c or 'launchctl' in c for c in commands))
            self.assertTrue((root / '.local/external/build.lock').exists())

    def test_default_build_does_not_authorize_or_run(self): self.run_builder()
    def test_signed_trial_checks_both_identities_without_installing(self): self.run_builder(signed=True)
    def test_sign_failure_never_publishes_pass(self): self.run_builder(fail='--sign')
    def test_verify_failure_never_publishes_pass(self): self.run_builder(signed=True, fail='--verify')
    def test_root_and_invalid_options_fail_before_tools(self):
        b = builder()
        for argv, root in [(['x', '--route-trial'], False), (['x', '--identity', '-'], False), (['x', '--apply'], False), (['x'], True)]:
            with patch.object(sys, 'argv', argv), patch.object(b.platform, 'system', return_value='Darwin'), \
                 patch.object(b.platform, 'machine', return_value='arm64'), patch.object(b.os, 'getuid', return_value=0 if root else 501), \
                 patch.object(b.os, 'geteuid', return_value=0 if root else 501), patch.object(b.subprocess, 'check_output') as tools, redirect_stderr(io.StringIO()):
                if root: self.assertEqual(b.main(), 77)
                else:
                    with self.assertRaises(SystemExit): b.main()
                tools.assert_not_called()
if __name__ == '__main__': unittest.main()
