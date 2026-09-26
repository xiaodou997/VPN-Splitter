# SPDX-License-Identifier: MIT
"""Source/project contracts only. These do not test native signing, XPC or Keychain."""
import importlib.util
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]
S = ROOT / 'Packages/ProviderConfiguration/Sources/ProviderConfiguration'
def read(path): return (ROOT / path).read_text()
def plist(path): return plistlib.loads((ROOT / path).read_bytes())

class AuthenticatedDeliveryContracts(unittest.TestCase):
    def test_real_extension_process_installs_listener_and_provider_consumes(self):
        main = read('apps/macos/PacketTunnel/main.swift')
        provider = read('apps/macos/PacketTunnel/PacketTunnelProvider.swift')
        self.assertIn('ManagedExtensionRuntime.install()', main)
        self.assertIn('runtime.consume(launch, ownerUID: ownerUID)', provider)
        for code in ['code: 1001', 'code: 2001', 'code: 2002', 'code: 2003']:
            self.assertIn(code, provider)
        self.assertNotIn('completionHandler(nil)', provider)
        self.assertNotIn('setTunnelNetworkSettings(', provider)

    def test_platform_authentication_precedes_resume_and_has_no_pid_fallback(self):
        source = (S / 'ManagedAuthenticatedXPC.swift').read_text()
        self.assertLess(source.index('listener.setConnectionCodeSigningRequirement('), source.index('func start() { listener.resume() }'))
        self.assertLess(source.index('connection.setCodeSigningRequirement('), source.rindex('connection.resume()'))
        self.assertEqual(source.count('connection.setCodeSigningRequirement('), 1)
        for required in ['options: .privileged', 'connection.effectiveUserIdentifier', 'SecCodeCheckValidity(', 'SecRequirementCreateWithString(', 'alive.close()']:
            self.assertIn(required, source)
        for forbidden in ['processIdentifier', 'kSecGuestAttributePid', 'value(forKey:', 'SecItemCopyMatching(', 'NSXPCListenerEndpoint']:
            self.assertNotIn(forbidden, source)

    def test_group_and_mach_service_are_consistent_without_shared_keychain_entitlement(self):
        for target in ['App', 'PacketTunnel']:
            info = plist(f'apps/macos/{target}/Info.plist')
            self.assertEqual(info['VPNManagedAppGroup'], '$(VPN_MANAGED_APP_GROUP)')
            self.assertEqual(info['VPNManagedMachService'], '$(VPN_MANAGED_MACH_SERVICE)')
            self.assertEqual(info['VPNManagedTeamIdentifier'], '$(DEVELOPMENT_TEAM)')
            for channel in ['Development', 'DeveloperID']:
                entitlements = plist(f'apps/macos/Config/{target}.{channel}.entitlements')
                self.assertEqual(entitlements['com.apple.security.application-groups'], ['$(VPN_MANAGED_APP_GROUP)'])
                self.assertNotIn('keychain-access-groups', entitlements)
                self.assertNotIn('com.apple.security.get-task-allow', entitlements)
        info = plist('apps/macos/PacketTunnel/Info.plist')
        self.assertEqual(info['NetworkExtension']['NEMachServiceName'], '$(VPN_MANAGED_MACH_SERVICE)')
        base = read('apps/macos/Config/Base.xcconfig')
        self.assertIn('VPN_MANAGED_APP_GROUP = $(TeamIdentifierPrefix)$(VPN_APP_BUNDLE_ID).managed', base)
        self.assertIn('VPN_MANAGED_MACH_SERVICE = $(VPN_MANAGED_APP_GROUP).credentials', base)

    def test_formal_view_is_in_generated_app_and_does_not_auto_refresh_or_start(self):
        spec = importlib.util.spec_from_file_location('gen', ROOT / 'tools/s1/generate-project.py')
        gen = importlib.util.module_from_spec(spec); spec.loader.exec_module(gen)
        self.assertEqual(gen.render(), read('apps/macos/VPN-Splitter.xcodeproj/project.pbxproj'))
        self.assertIn(gen.ident('app.ManagedConfigurationView.swift'), gen.build_project()['objects'])
        view = read('apps/macos/App/ManagedConfigurationView.swift')
        for forbidden in ['.onAppear', '.task', 'LocalDevCredential', 'UserDefaults']:
            self.assertNotIn(forbidden, view)
        save = view.split('    func save() {', 1)[1].split('    func checkDelivery()', 1)[0]
        self.assertNotIn('control.refresh()', save)
        self.assertIn('guard selectionLoaded, saveConsent', save)
        self.assertIn('guard selectionLoaded, deliveryConsent', view)

    def test_real_preferences_and_authenticated_path_order(self):
        source = (S / 'ManagedNativeApp.swift').read_text()
        for required in ['NETunnelProviderManager.loadAllFromPreferences', 'manager.saveToPreferences', 'session.startTunnel(', 'pendingWrite', 'try await read() == old']:
            self.assertIn(required, source)
        start = source.split('public func checkDelivery()', 1)[1]
        order = ['client.hello(', 'transaction.material(', 'client.stage(', 'transaction.validateForStart(', 'store.submit(']
        self.assertEqual([start.index(token) for token in order], sorted(start.index(token) for token in order))
        self.assertNotIn('configuration: material', source)
        self.assertIn('transaction.finishDelivery(grant)', source)

    def test_only_private_keychain_or_explicit_xpc_encodes_secrets(self):
        source = (S / 'ManagedAppKeychain.swift').read_text()
        self.assertIn('entitlements["com.apple.application-identifier"]', source)
        self.assertIn('accessGroup: applicationID', source)
        self.assertNotIn('VPNManagedAppGroup', source)
        for name in ['ManagedNativeApp.swift', 'ManagedDeliveryProtocol.swift', 'ManagedAuthenticatedXPC.swift']:
            source = (S / name).read_text()
            for forbidden in ['write(to:', 'UserDefaults', 'containerURL(forSecurityApplicationGroupIdentifier:', 'sendProviderMessage(']:
                self.assertNotIn(forbidden, source)

    def test_liveness_deadline_and_capacity_are_checked_without_timer_reliance(self):
        broker = (S / 'ManagedDeliveryProtocol.swift').read_text()
        self.assertIn('$0.value.deadline <= now() || !$0.value.isLive()', broker)
        self.assertIn('attempts.count < 256', broker)
        self.assertIn('channels.count < 8', broker)
        self.assertIn('envelope.challenge.ownerUID == ownerUID', broker)
        native = (S / 'ManagedAuthenticatedXPC.swift').read_text()
        self.assertIn('ProcessInfo.processInfo.systemUptime >= deadline', native)
        self.assertIn('connections.count < 8', native)

    def test_legacy_harness_does_not_claim_native_xpc_on_mac(self):
        test = read('tests/provider/test_launch_integration.py')
        self.assertIn('source.replace("#if os(macOS)", "#if VPNSPLITTER_DISABLED_NATIVE_IN_METADATA_TEST")', test)
        self.assertIn('native_xpc=NOT_TESTED', test)
        self.assertNotIn('VPNSPLITTER_DISABLED_NATIVE_IN_METADATA_TEST', read('apps/macos/PacketTunnel/PacketTunnelProvider.swift'))

if __name__ == '__main__': unittest.main()
