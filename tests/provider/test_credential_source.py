# SPDX-License-Identifier: MIT
"""Offline source/build-discovery contracts, not Security API or VPN evidence."""
import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Packages/ProviderConfiguration'
SOURCES = PACKAGE / 'Sources/ProviderConfiguration'

class CredentialSourceTests(unittest.TestCase):
    def test_swiftpm_discovers_native_and_transaction_sources(self):
        result = subprocess.run(['swift', 'package', '--package-path', str(PACKAGE), 'describe', '--type', 'json'],
                                capture_output=True, text=True, check=True, timeout=60)
        package = json.loads(result.stdout)
        target = next(t for t in package['targets'] if t['name'] == 'ProviderConfiguration')
        self.assertIn('ManagedAppKeychain.swift', target['sources'])
        self.assertIn('ManagedCredentialVault.swift', target['sources'])
        self.assertEqual(package['dependencies'], [])

    def test_native_store_has_no_shared_or_fallback_access(self):
        source = (SOURCES / 'ManagedAppKeychain.swift').read_text()
        self.assertIn('#if os(macOS)', source)
        self.assertIn('kSecUseDataProtectionKeychain as String: true', source)
        self.assertIn('context.interactionNotAllowed = true', source)
        self.assertIn('geteuid() == getuid()', source)
        for forbidden in ['kSecAttrAccessGroup', 'SecAccessCreate(', 'SecKeychainOpen(', 'kSecUseKeychain',
                          'kSecMatchSearchList', 'SecItemUpdate(', 'kSecMatchLimitAll', 'LocalDev']:
            self.assertNotIn(forbidden, source)

    def test_vault_does_not_publish_credentials_or_touch_network(self):
        source = (SOURCES / 'ManagedCredentialVault.swift').read_text()
        for forbidden in ['write(to:', 'UserDefaults', 'FileManager', 'NETunnelProvider',
                          'startTunnel(', 'setTunnelNetworkSettings(', 'print(', 'NSLog(']:
            self.assertNotIn(forbidden, source)
        self.assertIn('load(for launch: CheckedManagedLaunch', source)
        self.assertIn('backend.exists(reference: handle.persistentReference)', source)
        self.assertIn('account: handle.account', source)

    def test_native_query_tests_never_execute_security_operations(self):
        source = (PACKAGE / 'Tests/ProviderConfigurationTests/ManagedAppKeychainQueryTests.swift').read_text()
        self.assertIn('#if os(macOS)', source)
        for forbidden in ['SecItemAdd(', 'SecItemCopyMatching(', 'SecItemDelete(']:
            self.assertNotIn(forbidden, source)
        self.assertIn('testAbsenceQueryDoesNotHideChangedAccount', source)

if __name__ == '__main__':
    unittest.main()
