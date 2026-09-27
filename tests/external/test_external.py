# SPDX-License-Identifier: MIT
"""Offline source/entry tests. Native observation and SwiftUI are NOT executed."""
import ast
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Packages/ExternalCore'

class ExternalContracts(unittest.TestCase):
    def test_package_uses_existing_policycore_without_remote_dependencies(self):
        package = json.loads(subprocess.check_output(['swift', 'package', '--package-path', str(PACKAGE), 'dump-package'], text=True, timeout=30))
        self.assertEqual(len(package['dependencies']), 1)
        dependency = package['dependencies'][0]['fileSystem'][0]
        self.assertEqual(Path(dependency['path']).resolve(), (ROOT / 'Packages/PolicyCore').resolve())
        self.assertEqual({t['name'] for t in package['targets']}, {'ExternalCore', 'ExternalPreview', 'ExternalCoreTests'})
        source = (PACKAGE / 'Sources/ExternalCore/ExternalPreview.swift').read_text()
        self.assertIn('IPv4PolicyCompiler.compile(', source)
        self.assertIn('defaultAction: .vpn', source)
        self.assertIn('public var canApply: Bool { false }', source)

    def test_native_reader_has_only_fixed_read_only_network_command(self):
        source = (PACKAGE / 'Sources/ExternalCore/ExternalSystemSnapshot.swift').read_text()
        wrapper = (PACKAGE / 'Sources/ExternalPreview/ExternalSystemReader.swift').read_text()
        self.assertIn('ExternalSystemSnapshotReader().capture()', wrapper)
        self.assertNotIn('ExternalExecution', wrapper)
        self.assertEqual(source.count('process.executableURL ='), 1)
        self.assertIn('"/usr/sbin/netstat"', source)
        self.assertIn('process.arguments = ["-rn", "-f", "inet"]', source)
        for token in ['SCDynamicStoreCopyMultiple(', 'SCNetworkInterfaceCopyAll()', 'getifaddrs(', 'O_NONBLOCK', 'changedDuringRead']:
            self.assertIn(token, source)
        for token in ['SCDynamicStoreSet', 'SCPreferencesCommit', 'SecItem', 'startVPNTunnel', 'NETunnelProviderManager', 'URLSession', 'NWConnection', '/sbin/route', '/bin/sh', 'sudo', 'write(to:', 'UserDefaults']:
            self.assertNotIn(token, source)
        self.assertGreaterEqual(source.count('readRoutes()'), 3)  # declaration + two observations

    def test_no_automatic_capture_no_secret_persistence_and_stale_ui_is_cleared(self):
        source = (PACKAGE / 'Sources/ExternalPreview/ExternalPreviewApp.swift').read_text()
        for token in ['.onAppear', '.task', 'UserDefaults', '@AppStorage', 'write(to:', 'NSPasteboard']:
            self.assertNotIn(token, source)
        for token in ['guard token == id, !Task.isCancelled', 'preview = nil; observation = nil',
                      'guard token == id, observation != nil', 'self.preview = nil; self.observation = nil', 'didSet']:
            self.assertIn(token, source)
        self.assertIn('model.detect(previewRules: true)', source)
        self.assertIn('model.detect(previewRules: false)', source)

    def test_all_native_sources_parse_for_mac(self):
        sources = sorted((PACKAGE / 'Sources/ExternalPreview').glob('*.swift'))
        sources.append(PACKAGE / 'Sources/ExternalCore/ExternalSystemSnapshot.swift')
        result = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', *map(str, sources)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_build_plan_is_separate_local_preview(self):
        path = ROOT / 'tools/external/build.py'
        ast.parse(path.read_text())
        spec = importlib.util.spec_from_file_location('external_build', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        args = module.swift_arguments(Path('/tmp/repo with spaces'), Path('/tmp/new run'), '/synthetic sdk')
        self.assertEqual(args[args.index('--product') + 1], 'VPNExternalPreview')
        self.assertIn('/tmp/repo with spaces/Packages/ExternalCore', args)
        self.assertNotIn('run', args)
        for token in ['systemextensionsctl', 'provision', 'entitlements', 'startVPNTunnel', 'security find-identity', 'sudo ']:
            self.assertNotIn(token, path.read_text())
        if sys.platform != 'darwin':
            p = subprocess.run([sys.executable, str(path), 'build'], capture_output=True, timeout=10)
            self.assertEqual(p.returncode, 69)

    def test_dispatch_rejects_extra_arguments_and_preserves_existing_modes(self):
        with tempfile.TemporaryDirectory(prefix='external-dispatch-') as directory:
            root = Path(directory); shutil.copyfile(ROOT / 'dev.sh', root / 'dev.sh')
            folder = root / 'tools/external'; folder.mkdir(parents=True)
            (folder / 'build.py').write_text('import sys\nprint("external " + " ".join(sys.argv[1:]))\n')
            (folder / 'test.sh').write_text('echo external-test\n')
            for relative in ['localdev/build.sh', 'provider/build-runtime.py']:
                p = root / 'tools' / relative; p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('print("provider")\n' if relative.endswith('.py') else 'echo localdev\n')
            for mode, expected in [('external-run', 'external run'), ('external-build', 'external build'), ('external-test', 'external-test'), ('run', 'localdev'), ('provider-build', 'provider')]:
                p = subprocess.run(['/bin/bash', str(root / 'dev.sh'), mode], capture_output=True, text=True, timeout=10)
                self.assertEqual(p.returncode, 0, p.stderr); self.assertEqual(p.stdout.strip(), expected)
            for mode in ['external-run', 'external-build', 'external-test']:
                p = subprocess.run(['/bin/bash', str(root / 'dev.sh'), mode, '--sign'], capture_output=True, text=True, timeout=10)
                self.assertEqual(p.returncode, 2); self.assertEqual(p.stdout, '')

if __name__ == '__main__': unittest.main()
