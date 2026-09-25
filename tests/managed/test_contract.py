"""Offline source and test-entrypoint checks, not native routing observations."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "Packages/ManagedSettings"
SCRIPT = ROOT / "tools/managed/test.sh"
REFERENCE = ROOT / "third-party/wireguard-apple"


class SettingsContracts(unittest.TestCase):
    def test_apple_lane_is_a_real_separate_macos_test_target(self):
        package = (PACKAGE / "Package.swift").read_text()
        self.assertIn('#if os(macOS)', package)
        self.assertIn('.testTarget(name: "ManagedSettingsAppleTests"', package)
        self.assertIn('.linkedFramework("NetworkExtension")', package)
        self.assertIn('.package(path: "../PolicyCore")', package)
        self.assertNotIn('.package(url:', package)
        native = (PACKAGE / "Tests/ManagedSettingsAppleTests/PacketTunnelSettingsFactoryTests.swift").read_text()
        self.assertEqual(native.count('@Test func '), 4)
        self.assertIn('PacketTunnelSettingsFactory.makeForInspection', native)
        self.assertNotIn('setTunnelNetworkSettings', native)

    def test_native_factory_allocates_but_never_installs(self):
        native = (PACKAGE / 'Sources/ManagedSettingsApple/PacketTunnelSettingsFactory.swift').read_text()
        self.assertLess(native.index('try draft.check'), native.index('let result = NEPacketTunnelNetworkSettings'))
        self.assertIn('draft.includedRoutes.map', native)
        self.assertIn('draft.excludedRoutes.map', native)
        self.assertNotIn('allowedIPs', native)
        self.assertIn('result.ipv6Settings = nil', native)
        self.assertIn('dns.matchDomainsNoSearch = true', native)
        for path in (PACKAGE / 'Sources').rglob('*.swift'):
            for forbidden in ['setTunnelNetworkSettings(', 'NETunnelProviderManager', 'NEVPNManager',
                              'SecItem', 'URLSession', 'Process()', 'print(', 'Logger(', 'wgTurnOn', 'wgSetConfig']:
                self.assertNotIn(forbidden, path.read_text(), str(path))

    def test_pure_lane_has_no_apple_or_protocol_library_import(self):
        for path in (PACKAGE / 'Sources/ManagedSettings').glob('*.swift'):
            imports = re.findall(r'^import (\w+)', path.read_text(), flags=re.M)
            self.assertEqual(imports, ['PolicyCore'])
        source = (PACKAGE / 'Sources/ManagedSettings/SettingsDraft.swift').read_text()
        self.assertIn('plan.input.wireGuardPeers == input.protocolPeers', source)
        self.assertIn('input == current', source)
        self.assertIn('direct.count <= maxRoutes - included.count', source)
        self.assertNotIn('public init(', source)
        self.assertNotIn('Codable', source)

    def test_reference_is_exact_not_a_floating_or_active_dependency(self):
        manifest = json.loads((REFERENCE / 'reference.json').read_text())
        self.assertEqual(manifest['status'], 'REFERENCE_AUDIT_ONLY_NOT_A_BUILD_DEPENDENCY')
        self.assertRegex(manifest['revision'], r'^[0-9a-f]{40}$')
        self.assertEqual(len(manifest['source_blobs']), 5)
        for sha in manifest['source_blobs'].values():
            self.assertRegex(sha, r'^[0-9a-f]{40}$')
        data = (REFERENCE / 'COPYING.reference').read_bytes()
        sha = hashlib.sha1(f'blob {len(data)}\0'.encode() + data).hexdigest()
        self.assertEqual(sha, manifest['source_blobs']['COPYING'])
        self.assertIn('handle_setNetworkSettings_timeout_without_proceeding_as_success', manifest['open_gates'])
        self.assertIn('check_wgSetConfig_return_value_and_reconcile_partial_update', manifest['open_gates'])

    def test_script_has_no_network_signing_or_user_data_operations(self):
        text = SCRIPT.read_text()
        for forbidden in ['sudo ', 'curl ', 'git clone', 'security ', 'codesign ', 'xcodebuild ', 'rm ',
                          'open ', 'route add', 'route delete', 'networksetup', 'Application Support']:
            self.assertNotIn(forbidden, text)
        subprocess.run(['/bin/bash', '-n', str(SCRIPT)], check=True, capture_output=True)

    def run_script(self, failure=''):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'repo with spaces'
            entry = root / 'tools/managed/test.sh'
            entry.parent.mkdir(parents=True)
            entry.write_bytes(SCRIPT.read_bytes())
            bindir = Path(temporary) / 'bin'; bindir.mkdir()
            trace = Path(temporary) / 'trace'
            for name in ['swift', 'python3']:
                stub = bindir / name
                stub.write_text('#!/bin/bash\n'
                                'echo "${0##*/}|$*" >> "$TRACE"\n'
                                'case "${0##*/}:$*" in\n'
                                ' swift:*"-c release"*) [[ "$FAILURE" != release ]] || exit 22 ;;\n'
                                ' swift:*) [[ "$FAILURE" != debug ]] || exit 21 ;;\n'
                                ' python3:*) [[ "$FAILURE" != contracts ]] || exit 23 ;;\n'
                                'esac\nexit 0\n')
                stub.chmod(0o700)
            env = dict(os.environ, PATH=f'{bindir}:/usr/bin:/bin', TRACE=str(trace), FAILURE=failure)
            result = subprocess.run(['/bin/bash', str(entry)], capture_output=True, text=True, env=env)
            return result, trace.read_text().splitlines(), root

    def test_success_sequence_and_scope(self):
        result, trace, root = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace, [
            f'swift|test --package-path {root}/Packages/ManagedSettings -Xswiftc -warnings-as-errors',
            f'swift|test --package-path {root}/Packages/ManagedSettings -c release -Xswiftc -warnings-as-errors',
            f'python3|-m unittest discover -s {root}/tests/managed -v',
        ])
        self.assertIn('wireguard_engine=NOT_LINKED', result.stdout)
        self.assertIn('network_settings=NOT_APPLIED', result.stdout)
        if os.uname().sysname != 'Darwin': self.assertIn('native_settings_objects=NOT_RUN', result.stdout)

    def test_failures_stop_without_reporting_pass(self):
        for failure, code, calls in [('debug', 21, 1), ('release', 22, 2), ('contracts', 23, 3)]:
            with self.subTest(failure=failure):
                result, trace, _ = self.run_script(failure)
                self.assertEqual(result.returncode, code)
                self.assertEqual(len(trace), calls)
                self.assertNotIn('core=PASS', result.stdout)
                self.assertNotIn('native_settings_objects=PASS', result.stdout)


if __name__ == '__main__':
    unittest.main()
