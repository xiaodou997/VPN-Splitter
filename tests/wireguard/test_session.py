"""WG-INT-07: native driver SOURCE against explicit doubles; never a real VPN test."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from test_assembly import ROOT, INTEGRATION, staging_function

SESSION = 'integrations/wireguard/ManagedWireGuardSession.swift'
CORE = 'Packages/ProviderSession/Sources/ProviderSession/ProviderSession.swift'


class SessionIntegrationTests(unittest.TestCase):
    def test_same_native_session_bytes_are_staged(self):
        with tempfile.TemporaryDirectory(prefix='session stage ') as temp:
            target = Path(temp) / 'probe'
            staging_function()(target, ROOT)
            self.assertEqual((target / 'Sources/WGLinkProbe/ManagedWireGuardSession.swift').read_bytes(),
                             (ROOT / SESSION).read_bytes())
            manifest = (target / 'Package.swift').read_text()
            self.assertIn('.product(name: "ProviderSession", package: "ProviderSession")', manifest)
            self.assertIn(str(ROOT / 'Packages/ProviderSession'), manifest)
            self.assertNotIn('CONTROLLER_PATH', manifest)
            self.assertNotIn('.package(url:', manifest)

    def test_missing_session_stops_before_creating_probe(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / INTEGRATION
            source.parent.mkdir(parents=True); source.write_bytes((ROOT / INTEGRATION).read_bytes())
            with self.assertRaisesRegex(ValueError, 'MISSING'): staging_function()(root / 'probe', root)
            self.assertFalse((root / 'probe').exists())

    def test_symlink_session_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root / INTEGRATION
            source.parent.mkdir(parents=True); source.write_bytes((ROOT / INTEGRATION).read_bytes())
            (root / SESSION).symlink_to(ROOT / SESSION)
            with self.assertRaisesRegex(ValueError, 'SYMLINK'): staging_function()(root / 'probe', root)
            self.assertFalse((root / 'probe').exists())

    def test_controller_remains_independent_of_apple_and_secrets(self):
        text = (ROOT / CORE).read_text()
        for forbidden in ['import NetworkExtension', 'import Security', 'import WireGuardKit', 'JSONEncoder',
                          'SecItem', 'Process(', 'setTunnelNetworkSettings(', 'privateKey', 'password']:
            self.assertNotIn(forbidden, text)
        self.assertIn('awaitingSystemTeardown', text)
        self.assertIn('cleanupUnconfirmed', text)
        self.assertIn('stopCompletions.count < 16', text)

    def test_real_call_sites_are_only_in_driver_not_the_probe(self):
        native = (ROOT / SESSION).read_text()
        self.assertIn('assembly.adapter.start(tunnelConfiguration:', native)
        self.assertIn('assembly.adapter.stop', native)
        self.assertIn('delivery.consume(for: identity)', native)
        self.assertIn('live() == identity', native)
        for forbidden in ['getRuntimeConfiguration(', 'JSONEncoder(', 'setTunnelNetworkSettings(',
                          'value(forKey:', 'SecItemCopyMatching(', 'try!', 'fatalError(']:
            self.assertNotIn(forbidden, native)
        probe = (ROOT / 'tools/wireguard/Probe.swift').read_text()
        for forbidden in ['.start(', '.stop(', 'SecItem', 'setTunnelNetworkSettings(']:
            self.assertNotIn(forbidden, probe)
        self.assertIn('checkProviderSessionSignature', probe)

    def test_offline_entry_includes_both_controller_configurations(self):
        text = (ROOT / 'tools/wireguard/test.sh').read_text()
        self.assertEqual(text.count('"$ROOT/Packages/ProviderSession"'), 2)
        self.assertIn('provider_session=PASS', text)
        self.assertIn('native_compile_link=NOT_RUN', text)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift unavailable; driver/doubles harness NOT RUN')
    def test_real_controller_and_driver_typecheck_and_run_against_explicit_native_doubles(self):
        with tempfile.TemporaryDirectory(prefix='session source harness ') as temp:
            root = Path(temp); native = root / 'NativeSession.swift'
            # Only replace module imports: all production declarations/bodies remain unchanged.
            source = (ROOT / SESSION).read_text()
            filtered = ''.join(line for line in source.splitlines(True)
                               if not line.startswith('import ') or line == 'import Foundation\n')
            native.write_text(filtered)
            args = [shutil.which('swiftc'), '-swift-version', '6', '-warnings-as-errors', '-parse-as-library',
                    str(ROOT / CORE), str(native),
                    str(ROOT / 'tests/wireguard/session_native_doubles.swift'),
                    str(ROOT / 'tests/wireguard/session_native_harness.swift'), '-o', str(root / 'harness')]
            built = subprocess.run(args, capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            ran = subprocess.run([str(root / 'harness')], capture_output=True, text=True, timeout=30)
            self.assertEqual(ran.returncode, 0, ran.stderr)
            self.assertIn('scenarios=11 native_apis=TEST_DOUBLES', ran.stdout)
            self.assertNotIn('PRIVATE-TEST', ran.stdout + ran.stderr)
            self.assertNotIn('NEVER-LOG', ran.stdout + ran.stderr)


if __name__ == '__main__':
    unittest.main()
