"""Read-only environment diagnostics with injected tool responses; not a Mac build."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools/dev'))
import doctor
LOCK = json.loads(doctor.LOCK_PATH.read_text())


class Tools:
    def __init__(self, failures=(), go='go1.27.1'):
        self.calls = []
        self.failures = failures
        self.go = go
    def run(self, args, timeout=15):
        self.calls.append(args)
        name = ' '.join(args)
        if any(x in name for x in self.failures):
            raise doctor.BuildError('PRIVATE ERROR MUST NOT APPEAR')
        if '-productVersion' in args: return '26.0'
        if '--show-sdk-version' in args: return '26.0'
        if 'xcodebuild' in args[0]: return 'Xcode 26.0\nBuild version synthetic'
        if 'swift' in args: return 'Apple Swift version 6.2'
        if args[-1] == 'clang': return '/selected Xcode/bin/clang'
        if args[-1] == 'GOVERSION': return self.go
        if args[0].endswith('/git'): return 'git version 2.45.0'
        raise AssertionError('Unexpected non-readonly command: ' + name)


def lookup(name): return '/test tools/' + name


class DoctorTests(unittest.TestCase):
    def inspect(self, tools, lookup=lookup):
        with patch.object(doctor.platform, 'system', return_value='Darwin'), \
             patch.object(doctor.platform, 'machine', return_value='arm64'), \
             patch.object(doctor.shutil, 'which', side_effect=lookup):
            return doctor.inspect(tools, LOCK)
    def report(self, checks, target):
        output = io.StringIO()
        with redirect_stdout(output): code = doctor.report(checks, target)
        return code, output.getvalue()

    def test_ready_environment_does_not_mean_compiled(self):
        tools = Tools(); checks = self.inspect(tools)
        code, text = self.report(checks, 'engine')
        self.assertEqual(code, 0)
        self.assertIn('engine_environment=PASS', text)
        self.assertIn('compile_link=NOT_RUN', text)
        self.assertTrue(all(c.ok for c in checks))

    def test_go_missing_does_not_block_app(self):
        checks = self.inspect(Tools(), lambda name: None if name == 'go' else lookup(name))
        self.assertEqual(self.report(checks, 'app')[0], 0)
        code, text = self.report(checks, 'engine')
        self.assertEqual(code, 2)
        self.assertIn('app_environment=PASS', text)
        self.assertIn('engine_environment=BLOCKED', text)
        self.assertNotIn('下一步：/bin/bash dev.sh engine --fetch', text)

    def test_wrong_go_version_is_optional_for_app_but_not_engine(self):
        checks = self.inspect(Tools(go='go1.23.2'))
        self.assertEqual(self.report(checks, 'app')[0], 0)
        self.assertEqual(self.report(checks, 'engine')[0], 2)

    def test_collects_multiple_failures_without_raw_errors(self):
        tools = Tools(failures=['xcodebuild', '--show-sdk-version', 'GOVERSION'])
        code, text = self.report(self.inspect(tools), 'engine')
        self.assertEqual(code, 2)
        self.assertIn('[MISSING] xcode', text)
        self.assertIn('[MISSING] sdk', text)
        self.assertIn('[MISSING] go', text)
        self.assertNotIn('PRIVATE', text)
        self.assertTrue(any('clang' in x for x in tools.calls))

    def test_malformed_go_output_not_echoed(self):
        _, text = self.report(self.inspect(Tools(go='PRIVATE\nERROR')), 'engine')
        self.assertNotIn('PRIVATE', text)
        self.assertIn('无法识别', text)

    def test_linux_skips_apple_commands(self):
        tools = Tools()
        with patch.object(doctor.platform, 'system', return_value='Linux'), \
             patch.object(doctor.shutil, 'which', side_effect=lookup):
            checks = doctor.inspect(tools, LOCK)
        self.assertFalse(any(x[0].startswith('/usr/bin/') for x in tools.calls))
        self.assertEqual(self.report(checks, 'app')[0], 2)

    def test_version_parsing_rejects_malformed_or_old(self):
        for value in ['25.9', '', 'PRIVATE', '26beta', '26\nPRIVATE']:
            self.assertFalse(doctor.version_at_least(value, 26))
        for value in ['26', '26.0', '26.1.2', '27.0']:
            self.assertTrue(doctor.version_at_least(value, 26))

    def test_go_env_stays_local_and_online_services_disabled(self):
        environment = doctor.clean_environment()
        self.assertEqual(environment['GOTOOLCHAIN'], 'local')
        self.assertEqual(environment['GOPROXY'], 'off')
        self.assertEqual(environment['GOENV'], 'off')


class EntrypointTests(unittest.TestCase):
    def invoke(self, args, doctor_failure=False, python_failure=False, missing_python=False):
        with tempfile.TemporaryDirectory(prefix='dev workflow ') as temp:
            root = Path(temp) / 'repo with spaces'; root.mkdir()
            shutil.copyfile(ROOT / 'dev.sh', root / 'dev.sh')
            trace = Path(temp) / 'trace'
            bins = Path(temp) / 'bin'; bins.mkdir()
            python = bins / 'python3'
            python.write_text('''#!/bin/bash
printf 'python|%s\n' "$*" >> "$TRACE"
if [[ ${1:-} == -c && $PYTHON_FAILURE == 1 ]]; then exit 1; fi
if [[ ${1:-} == *doctor.py && $DOCTOR_FAILURE == 1 ]]; then exit 23; fi
''')
            python.chmod(0o700)
            for name in ['tools/localdev/build.sh', 'tools/localdev/test.sh',
                         'tools/wireguard/build.sh', 'tools/wireguard/test.sh']:
                file = root / name; file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text('#!/bin/bash\nprintf "%s|%s\n" "${0##*/}" "$*" >> "$TRACE"\n')
            if missing_python:
                python.unlink()
                (bins / 'dirname').symlink_to('/usr/bin/dirname')
            path = str(bins) if missing_python else str(bins) + ':/usr/bin:/bin'
            env = dict(os.environ, PATH=path, TRACE=str(trace),
                       DOCTOR_FAILURE=str(int(doctor_failure)), PYTHON_FAILURE=str(int(python_failure)))
            result = subprocess.run(['/bin/bash', str(root / 'dev.sh')] + args,
                                    env=env, capture_output=True, text=True)
            return result, trace.read_text().splitlines() if trace.exists() else [], root

    def test_default_is_readonly_doctor_not_build_or_download(self):
        result, trace, _ = self.invoke([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(trace[-1].endswith('tools/dev/doctor.py app'))
        self.assertFalse(any('build.sh' in x for x in trace))

    def test_run_has_no_python_or_go_prerequisite(self):
        result, trace, _ = self.invoke(['run'], python_failure=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, ['build.sh|run'])

    def test_engine_fetch_is_forwarded_only_after_successful_doctor(self):
        result, trace, _ = self.invoke(['engine', '--fetch'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('doctor.py engine', trace[-2])
        self.assertEqual(trace[-1], 'build.sh|build --fetch')

    def test_offline_engine_does_not_add_fetch(self):
        result, trace, _ = self.invoke(['engine'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace[-1], 'build.sh|build')
        self.assertFalse(any('--fetch' in x for x in trace))

    def test_failed_doctor_stops_engine(self):
        result, trace, _ = self.invoke(['engine', '--fetch'], doctor_failure=True)
        self.assertEqual(result.returncode, 23)
        self.assertFalse(any(x.startswith('build.sh|') for x in trace))

    def test_old_python_gets_actionable_error_before_doctor(self):
        result, trace, _ = self.invoke(['doctor'], python_failure=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('E_PYTHON', result.stderr)
        self.assertFalse(any('doctor.py' in x for x in trace))

    def test_missing_python_is_reported_by_shell(self):
        result, trace, _ = self.invoke(['doctor', 'engine'], missing_python=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('E_PYTHON', result.stderr)
        self.assertEqual(trace, [])

    def test_invalid_modes_flags_and_extra_args_cannot_start_work(self):
        for args in [['doctor', '--fetch'], ['doctor', 'engine', 'extra'], ['run', '--fetch'],
                     ['engine', '--unknown'], ['test', 'extra'], ['unknown']]:
            result, trace, _ = self.invoke(args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(trace, [])

    def test_help_does_not_require_any_language_tools(self):
        result, trace, _ = self.invoke(['--help'], python_failure=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(trace, [])
        self.assertIn('不需要 Go', result.stdout)


if __name__ == '__main__':
    unittest.main()
