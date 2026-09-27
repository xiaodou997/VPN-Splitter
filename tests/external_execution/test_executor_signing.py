# SPDX-License-Identifier: MIT
"""Exercise the actual builder with simulated Mac tools, not native code signing.

Filesystem copy/log/hash operations are real in a temporary directory. No Swift
compiler, codesign, privileged executable, or network operation is run.
"""
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class ExecutorSigningTests(unittest.TestCase):
    def run_builder(self, *, presigned=True, fail_at=None, architecture='arm64'):
        spec = importlib.util.spec_from_file_location('executor_signing_builder',
            ROOT / 'tools/external/executor-build.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        with tempfile.TemporaryDirectory(prefix='external-signing-') as directory:
            # Resolve macOS temporary-directory aliases and exercise spaces as arguments.
            root = Path(directory).resolve() / 'repository with spaces'
            root.mkdir()
            bin_dir = root / 'synthetic SwiftPM output'
            bin_dir.mkdir()
            source = bin_dir / 'VPNExternalLease'
            original = b'SYNTHETIC EXECUTABLE; NOT MACH-O\n' + (
                b'signature=linker\n' if presigned else b'unsigned\n')
            source.write_bytes(original)
            source.chmod(0o700)
            commands = []
            trace = []
            artifacts = []
            stdout, stderr = io.StringIO(), io.StringIO()

            def compile_double(arguments, log):
                self.assertEqual(arguments[arguments.index('--product') + 1], 'VPNExternalLease')
                trace.append('compile')
                log.write(b'synthetic compiler output\n')

            def output_double(arguments, **kwargs):
                self.assertTrue(kwargs.get('text'))
                if arguments == ['/usr/bin/sw_vers', '-productVersion']:
                    return '26.0\n'
                if arguments == ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-version']:
                    return '26.0\n'
                if arguments == ['/usr/bin/xcrun', '--sdk', 'macosx', '--show-sdk-path']:
                    return '/synthetic SDK with spaces\n'
                if arguments[:3] == ['/usr/bin/xcrun', 'swift', 'build'] and arguments[-1] == '--show-bin-path':
                    self.assertEqual(trace, ['compile'])
                    return str(bin_dir) + '\n'
                if arguments[:3] == ['/usr/bin/xcrun', 'lipo', '-archs']:
                    target = Path(arguments[3])
                    self.assertEqual(target.parent.parent, root / '.local/external')
                    self.assertEqual(target.name, 'VPNExternalLease')
                    self.assertNotEqual(target, source)
                    self.assertEqual(target.read_bytes(), original)
                    artifacts.append(target)
                    trace.append('architecture')
                    return architecture + '\n'
                self.fail('Unexpected external command: ' + repr(arguments))

            def signing_double(arguments, **kwargs):
                # Only codesign on the just-copied artifact is permitted; never run it.
                self.assertEqual(arguments[0], '/usr/bin/codesign')
                self.assertEqual(len(artifacts), 1)
                target = artifacts[0]
                self.assertEqual(arguments[-1], str(target))
                self.assertTrue(kwargs.get('check'))
                self.assertEqual(kwargs.get('timeout'), 30)
                self.assertFalse(kwargs.get('shell', False))
                self.assertNotIn('--deep', arguments)
                self.assertNotIn('--remove-signature', arguments)
                commands.append(list(arguments))
                sign = '--sign' in arguments
                step = 'sign' if sign else 'verify'
                trace.append(step)
                log = kwargs.get('stdout')
                # The old builder lacks log routing; this fixture still reproduces its
                # already-signed error, while separate assertions check the new logging.
                if log is not None:
                    self.assertEqual(Path(log.name), target.parent / 'build.log')
                    self.assertEqual(kwargs.get('stderr'), subprocess.STDOUT)
                message = None
                if sign:
                    self.assertEqual(arguments[arguments.index('--sign') + 1], '-')
                    self.assertIn('--timestamp=none', arguments)
                    if presigned and '--force' not in arguments:
                        message = 'is already signed'
                    elif fail_at in ('sign', 'sign_timeout'):
                        message = 'synthetic signing failure'
                else:
                    self.assertEqual(arguments, ['/usr/bin/codesign', '--verify', '--strict', str(target)])
                    self.assertEqual(trace, ['compile', 'architecture', 'sign', 'verify'])
                    self.assertTrue(target.read_bytes().endswith(b'signature=local-test\n'))
                    if fail_at == 'verify':
                        message = 'synthetic strict verification failure'
                if message:
                    if log is not None:
                        log.write((message + '\n').encode()); log.flush()
                    if fail_at == 'sign_timeout':
                        raise subprocess.TimeoutExpired(arguments, 30)
                    raise subprocess.CalledProcessError(1, arguments, stderr=message)
                if sign:
                    # Simulate a signer mutating only the copy. The published hash must
                    # describe these final bytes, not the compiler's original output.
                    target.write_bytes(original + b'signature=local-test\n')
                if log is not None:
                    log.write(('synthetic ' + step + ' succeeded\n').encode()); log.flush()
                return subprocess.CompletedProcess(arguments, 0)

            with ExitStack() as stack:
                stack.enter_context(patch.object(builder, 'ROOT', root))
                stack.enter_context(patch.object(builder.platform, 'system', return_value='Darwin'))
                stack.enter_context(patch.object(builder.platform, 'machine', return_value='arm64'))
                stack.enter_context(patch.object(builder.os, 'getuid', return_value=501))
                stack.enter_context(patch.object(builder.os, 'geteuid', return_value=501))
                stack.enter_context(patch.object(builder, 'compile_once', side_effect=compile_double))
                stack.enter_context(patch.object(builder.subprocess, 'check_output', side_effect=output_double))
                stack.enter_context(patch.object(builder.subprocess, 'run', side_effect=signing_double))
                stack.enter_context(patch.object(sys, 'argv', ['executor-build.py']))
                stack.enter_context(redirect_stdout(stdout)); stack.enter_context(redirect_stderr(stderr))
                result = builder.main()
            self.assertEqual(source.read_bytes(), original, 'The compiler output must not be re-signed in place.')
            run = artifacts[0].parent
            hash_file = run / 'artifact.sha256'
            return dict(code=result, stdout=stdout.getvalue(), stderr=stderr.getvalue(),
                log=(run / 'build.log').read_text(), commands=commands, trace=trace,
                published_hash=hash_file.read_text().strip() if hash_file.exists() else None,
                final_hash=hashlib.sha256(artifacts[0].read_bytes()).hexdigest())

    def assert_success(self, result):
        self.assertEqual(result['code'], 0, result['stderr'])
        self.assertEqual(result['trace'], ['compile', 'architecture', 'sign', 'verify'])
        self.assertEqual(len(result['commands']), 2)
        self.assertIn('--force', result['commands'][0])
        self.assertEqual(result['published_hash'], result['final_hash'])
        self.assertIn('sha256=' + result['final_hash'], result['stdout'])
        for marker in ['compile=PASS', 'execution=NOT_RUN', 'network_settings=NOT_APPLIED',
                       'helper_installation=NOT_REQUESTED']:
            self.assertIn(marker, result['stdout'])
        for marker in ['synthetic compiler output', '--force --sign -', '--verify --strict',
                       'synthetic sign succeeded', 'synthetic verify succeeded']:
            self.assertIn(marker, result['log'])

    def assert_failure(self, result):
        self.assertEqual(result['code'], 2)
        self.assertNotIn('compile=PASS', result['stdout'])
        self.assertNotIn('Executable:', result['stdout'])
        self.assertNotIn('sha256=', result['stdout'])
        self.assertIsNone(result['published_hash'])
        self.assertIn('E_EXTERNAL_EXECUTOR_BUILD', result['stderr'])

    def test_pre_signed_copy_is_replaced_then_strictly_verified(self):
        self.assert_success(self.run_builder())

    def test_unsigned_copy_also_signs_and_publishes_final_hash(self):
        self.assert_success(self.run_builder(presigned=False))

    def test_signing_failure_is_logged_without_verify_or_success(self):
        result = self.run_builder(fail_at='sign')
        self.assert_failure(result)
        self.assertEqual(result['trace'], ['compile', 'architecture', 'sign'])
        self.assertIn('synthetic signing failure', result['log'])

    def test_strict_verification_failure_is_logged_without_publishing(self):
        result = self.run_builder(fail_at='verify')
        self.assert_failure(result)
        self.assertEqual(result['trace'], ['compile', 'architecture', 'sign', 'verify'])
        self.assertIn('synthetic strict verification failure', result['log'])

    def test_signing_timeout_is_not_ignored_or_retried(self):
        result = self.run_builder(fail_at='sign_timeout')
        self.assert_failure(result)
        self.assertEqual(len(result['commands']), 1)
        self.assertIn('synthetic signing failure', result['log'])

    def test_wrong_architecture_never_reaches_signing(self):
        result = self.run_builder(architecture='x86_64')
        self.assert_failure(result)
        self.assertEqual(result['commands'], [])
        self.assertEqual(result['trace'], ['compile', 'architecture'])


if __name__ == '__main__':
    unittest.main()
