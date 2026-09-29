# SPDX-License-Identifier: MIT
"""Offline manifest/entry contracts. No privilege acquisition or live kernel writes."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Packages/ExternalExecution'

class ExecutionEntryTests(unittest.TestCase):
    def test_actual_manifest_is_local_and_keeps_preview_read_only(self):
        package = json.loads(subprocess.check_output(['swift', 'package', '--package-path', str(PACKAGE), 'dump-package'], text=True, timeout=30))
        deps = {Path(x['fileSystem'][0]['path']).resolve() for x in package['dependencies']}
        self.assertEqual(deps, {(ROOT / 'Packages/ExternalCore').resolve(), (ROOT / 'Packages/PolicyCore').resolve(), (ROOT / 'Packages/ExternalControl').resolve()})
        self.assertEqual({t['name'] for t in package['targets']}, {'CExternalRoute', 'ExternalExecution', 'ExternalLease', 'ExternalHelper', 'ExternalExecutionTests'})
        self.assertIn('public var canApply: Bool { false }', (ROOT / 'Packages/ExternalCore/Sources/ExternalCore/ExternalPreview.swift').read_text())
        source = (ROOT / 'Packages/ExternalCore/Package.swift').read_text()
        self.assertNotIn('ExternalExecution', source)
        self.assertNotIn('fixtures', (PACKAGE / 'Package.swift').read_text())

    def test_native_shared_reader_and_new_sources_parse(self):
        sources = list((PACKAGE / 'Sources').rglob('*.swift'))
        sources.append(ROOT / 'Packages/ExternalCore/Sources/ExternalCore/ExternalSystemSnapshot.swift')
        p = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', *map(str, sources)], text=True, capture_output=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        collector = sources[-1].read_text()
        for token in ['SCDynamicStoreCopyMultiple', 'getifaddrs', 'ExternalRouteTable.parseDiagnosing(readRoutes())']:
            self.assertIn(token, collector)
        for token in ['RTM_ADD', 'RTM_DELETE', 'SecItem', '/sbin/route']:
            self.assertNotIn(token, collector)

    def test_explicit_operator_boundary_precedes_writes(self):
        source = (PACKAGE / 'Sources/ExternalLease/ExternalLeaseMain.swift').read_text()
        self.assertIn('getuid() == 0, geteuid() == 0, isatty(STDIN_FILENO) == 1', source)
        self.assertLess(source.index('er_console_confirm()'), source.index('session.start(consent: true)'))
        self.assertIn('guard command == "apply"', source)
        self.assertIn('session.stop()', source)
        for token in ['Process()', 'AuthorizationExecuteWithPrivileges', 'NSAppleScript', 'systemextensionsctl']:
            self.assertNotIn(token, source)
        journal = (PACKAGE / 'Sources/ExternalExecution/ExternalLeaseJournal.swift').read_text()
        self.assertIn('O_EXCL | O_NOFOLLOW | O_CLOEXEC', journal)
        self.assertIn('auditedRoutes == routes', journal)
        self.assertNotIn('RTM_DELETE', journal.split('public func clearAuditedAbsence')[1])
        native = (PACKAGE / 'Sources/ExternalExecution/NativeRouteDriver.swift').read_text()
        self.assertIn('er_add', native); self.assertIn('er_remove', native)

    def test_builder_never_executes_the_result_and_refuses_bad_arguments(self):
        path = ROOT / 'tools/external/executor-build.py'
        spec = importlib.util.spec_from_file_location('executor_builder', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        args = module.swift_arguments(Path('/tmp/repo space'), Path('/tmp/build space'), '/sdk space')
        self.assertEqual(args[args.index('--product') + 1], 'VPNExternalLease')
        self.assertIn('/tmp/repo space/Packages/ExternalExecution', args)
        self.assertIn('-warnings-as-errors', args)
        for token in ["['sudo'", 'SMAppService', '/usr/bin/open', 'subprocess.run([str(target)', '--fetch']:
            self.assertNotIn(token, path.read_text())
        p = subprocess.run([sys.executable, str(path), '--apply'], capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 2)
        if sys.platform != 'darwin':
            p = subprocess.run([sys.executable, str(path)], capture_output=True, timeout=10)
            self.assertEqual(p.returncode, 69)

    def test_safe_dispatch_and_no_network_effects_in_test_command(self):
        with tempfile.TemporaryDirectory(prefix='ex-lease-entry-') as d:
            root = Path(d); shutil.copyfile(ROOT / 'dev.sh', root / 'dev.sh')
            tools = root / 'tools/external'; tools.mkdir(parents=True)
            (tools / 'executor-build.py').write_text('print("build-only")\n')
            (tools / 'execution-test.sh').write_text('echo test-only\n')
            for command, output in [('external-executor-build', 'build-only'), ('external-execution-test', 'test-only')]:
                p = subprocess.run(['/bin/bash', str(root / 'dev.sh'), command], capture_output=True, text=True, timeout=10)
                self.assertEqual(p.returncode, 0, p.stderr); self.assertEqual(p.stdout.strip(), output)
                p = subprocess.run(['/bin/bash', str(root / 'dev.sh'), command, 'apply'], capture_output=True, timeout=10)
                self.assertEqual(p.returncode, 2); self.assertEqual(p.stdout, b'')
        script = (ROOT / 'tools/external/execution-test.sh').read_text()
        self.assertIn('swift test', script); self.assertIn('unittest discover', script)
        self.assertNotIn('VPNExternalLease apply', script)

if __name__ == '__main__': unittest.main()
