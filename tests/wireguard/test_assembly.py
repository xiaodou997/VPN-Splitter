"""WG-INT-06: actual staging/manifest checks; no Go, Apple runtime or tunnel execution.

AST isolation runs the exact production create_probe and read_ordinary functions
without importing or replacing the unrelated download/build implementations.
"""
import ast
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INTEGRATION = 'integrations/wireguard/ManagedWireGuardAssembly.swift'


def production_function(path, name, environment):
    tree = ast.parse(path.read_text())
    functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == name]
    if len(functions) != 1:
        raise AssertionError('missing or duplicate production function')
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(path), 'exec'), environment)
    return environment[name]


def staging_function():
    environment = dict(Path=Path, json=json, shutil=shutil)
    production_function(ROOT / 'tools/wireguard/bridge_assets.py', 'read_ordinary', environment)
    return production_function(ROOT / 'tools/wireguard/build.py', 'create_probe', environment)


class AssemblyStagingTests(unittest.TestCase):
    def test_native_source_enters_probe_byte_for_byte(self):
        with tempfile.TemporaryDirectory(prefix='wg assembly staging ') as temp:
            target = Path(temp) / 'probe'
            staging_function()(target, ROOT)
            files = target / 'Sources/WGLinkProbe'
            self.assertEqual((files / 'ManagedWireGuardAssembly.swift').read_bytes(), (ROOT / INTEGRATION).read_bytes())
            self.assertEqual((files / 'main.swift').read_bytes(), (ROOT / 'tools/wireguard/Probe.swift').read_bytes())
            self.assertEqual({p.name for p in files.iterdir()}, {'main.swift', 'ManagedWireGuardAssembly.swift', 'ManagedWireGuardSession.swift'})

    def test_new_import_has_an_explicit_local_package_dependency(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'probe'
            staging_function()(target, ROOT)
            manifest = (target / 'Package.swift').read_text()
            self.assertIn('.product(name: "PolicyCore", package: "PolicyCore")', manifest)
            self.assertIn(str(ROOT / 'Packages/PolicyCore'), manifest)
            self.assertNotIn('.package(url:', manifest)
            self.assertNotIn('POLICY_PATH', manifest)

    def test_missing_source_rejected_before_creating_probe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, 'MISSING'):
                staging_function()(root / 'probe', root)
            self.assertFalse((root / 'probe').exists())

    def test_symlink_source_or_parent_rejected(self):
        for parent in [False, True]:
            with self.subTest(parent=parent), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                if parent:
                    (root / 'integrations').symlink_to(ROOT / 'integrations', target_is_directory=True)
                else:
                    (root / INTEGRATION).parent.mkdir(parents=True)
                    (root / INTEGRATION).symlink_to(ROOT / INTEGRATION)
                with self.assertRaisesRegex(ValueError, 'SYMLINK'):
                    staging_function()(root / 'probe', root)
                self.assertFalse((root / 'probe').exists())

    def test_existing_probe_is_preserved_instead_of_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'probe'
            staging_function()(target, ROOT)
            original = {p.relative_to(target): p.read_bytes() for p in target.rglob('*') if p.is_file()}
            with self.assertRaises(FileExistsError):
                staging_function()(target, ROOT)
            self.assertEqual(original, {p.relative_to(target): p.read_bytes() for p in target.rglob('*') if p.is_file()})

    @unittest.skipUnless(shutil.which('swift'), 'SwiftPM unavailable; manifest evaluation NOT RUN')
    def test_actual_generated_manifest_evaluates_without_engine_downloads(self):
        with tempfile.TemporaryDirectory(prefix='wg assembly manifest ') as temp:
            target = Path(temp) / 'probe'
            staging_function()(target, ROOT)
            result = subprocess.run([shutil.which('swift'), 'package', '--package-path', str(target), 'dump-package'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            description = json.loads(result.stdout)
            self.assertEqual(description['toolsVersion']['_version'], '6.0.0')
            self.assertEqual([p['platformName'] for p in description['platforms']], ['macos'])
            self.assertEqual(len(description['dependencies']), 4)
            self.assertEqual([t['name'] for t in description['targets']], ['WGLinkProbe'])
            self.assertFalse((target / 'libwg-go.a').exists())

    def test_factory_has_no_network_execution_or_secret_serialization_path(self):
        text = (ROOT / INTEGRATION).read_text()
        for forbidden in ['.start(', '.update(', 'setTunnelNetworkSettings(', 'SecItem', 'URLSession',
                          'getaddrinfo', 'getRuntimeConfiguration(', 'privateKey', 'base64Key', 'hexKey', 'JSONEncoder']:
            self.assertNotIn(forbidden, text)
        self.assertIn('PreparedWireGuardPlan.prepare', text)
        self.assertIn('plan.check(source: projected', text)
        self.assertIn('PacketTunnelSettingsFactory.makeForInspection', text)
        self.assertIn('runtimeBinding: binding', text)
        self.assertIn('tunnelDescriptorProvider: descriptor', text)
        self.assertIn('binding.invalidate()', text)
        self.assertGreaterEqual(text.count('gate.check(current: currentRevision())'), 4)

    def test_every_address_family_is_checked_not_filtered(self):
        text = (ROOT / INTEGRATION).read_text()
        self.assertEqual(text.count('is Network.IPv4Address'), 3)
        self.assertIn('case .ipv4 = endpoint.host', text)
        self.assertNotIn('compactMap', text)
        self.assertNotIn('.filter', text)
        self.assertIn('configuration.interface.dnsSearch', text)
        self.assertIn('peer.allowedIPs.map', text)


if __name__ == '__main__':
    unittest.main()
