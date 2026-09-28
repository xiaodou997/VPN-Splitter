# SPDX-License-Identifier: MIT
"""Real preview builder orchestration; macOS tools are explicit doubles. Never opens an app."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

class ProfileBuildTests(unittest.TestCase):
    def execute_builder(self, fail=None, mode='build', root_user=False):
        spec = importlib.util.spec_from_file_location('profile_preview_build',ROOT/'tools/external/build.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='profile-build-test-') as temp:
            root = Path(temp); binary = root/'binary'; binary.mkdir()
            original = binary/'VPNExternalPreview'; original.write_bytes(b'synthetic pre-signed executable')
            calls = []
            def check_output(command,**kwargs):
                if command[0] == '/usr/bin/sw_vers' or '--show-sdk-version' in command: return '26.0\n'
                if '--show-sdk-path' in command: return '/synthetic SDK\n'
                if '--show-bin-path' in command: return str(binary)+'\n'
                self.fail('unexpected command')
            def run(command,**kwargs):
                calls.append(command)
                if command[0] == '/usr/bin/codesign':
                    is_sign = '--sign' in command
                    if is_sign: self.assertIn('--force',command)
                    else: self.assertIn('--strict',command)
                    self.assertTrue(kwargs['check'])
                    kwargs['stdout'].write(b'synthetic signing diagnostic\n'); kwargs['stdout'].flush()
                    if (fail == 'sign' and is_sign) or (fail == 'verify' and not is_sign):
                        raise subprocess.CalledProcessError(1,command)
                else:
                    self.assertEqual(command[0],'/usr/bin/open')
                return subprocess.CompletedProcess(command,0)
            out = io.StringIO()
            with patch.object(module,'ROOT',root), patch.object(module.platform,'system',return_value='Darwin'), \
                 patch.object(module.platform,'machine',return_value='arm64'), patch.object(module.os,'getuid',return_value=0 if root_user else 501), \
                 patch.object(module.os,'geteuid',return_value=0 if root_user else 501), patch.object(sys,'argv',['builder',mode]), \
                 patch.object(module.subprocess,'check_output',side_effect=check_output), patch.object(module.subprocess,'run',side_effect=run), \
                 patch.object(module,'compile_once',side_effect=lambda args,log: log.write(b'synthetic compiler\n')), \
                 contextlib.redirect_stdout(out),contextlib.redirect_stderr(out):
                result = module.main()
            self.assertEqual(original.read_bytes(),b'synthetic pre-signed executable')
            logs = list(root.glob('.local/external/build.*/build.log'))
            text = logs[0].read_text() if logs else ''
            return result,out.getvalue(),calls,text

    def test_forced_sign_and_strict_verify_precede_optional_open(self):
        for mode in ['build','run']:
            with self.subTest(mode=mode):
                code,out,calls,log = self.execute_builder(mode=mode)
                self.assertEqual(code,0); self.assertIn('compile=PASS',out)
                self.assertEqual([c[0] for c in calls],['/usr/bin/codesign']*2+(['/usr/bin/open'] if mode=='run' else []))
                self.assertIn('synthetic compiler',log); self.assertIn('--force',log); self.assertIn('--verify --strict',log)

    def test_sign_or_verify_failure_never_publishes_or_opens(self):
        for failure in ['sign','verify']:
            with self.subTest(failure=failure):
                code,out,calls,log = self.execute_builder(fail=failure,mode='run')
                self.assertEqual(code,2); self.assertNotIn('compile=PASS',out)
                self.assertNotIn('/usr/bin/open',[c[0] for c in calls])
                self.assertIn('synthetic signing diagnostic',log)
                self.assertEqual(len(calls),1 if failure=='sign' else 2)

    def test_root_build_is_rejected_before_tools(self):
        code,out,calls,log = self.execute_builder(root_user=True)
        self.assertEqual(code,77); self.assertIn('E_BUILD_AS_ROOT',out)
        self.assertEqual(calls,[]); self.assertEqual(log,'')

if __name__ == '__main__': unittest.main()
