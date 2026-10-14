# SPDX-License-Identifier: MIT
import ast, json, subprocess, sys, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'Packages/ExternalFlow'

class ExternalFlowContracts(unittest.TestCase):
    def provider_sources(self):
        directory = PACKAGE / 'Sources/ExternalFlowProvider'
        return ''.join(p.read_text() for p in sorted(directory.glob('*.swift')))

    def test_manifest_is_local_and_probe_only(self):
        package = json.loads(subprocess.check_output(
            ['swift', 'package', '--package-path', str(PACKAGE), 'dump-package'], text=True, timeout=30))
        deps = {Path(x['fileSystem'][0]['path']).resolve() for x in package['dependencies']}
        self.assertEqual(deps, {(ROOT / 'Packages/ExternalCore').resolve(), (ROOT / 'Packages/PolicyCore').resolve(),
                                (ROOT / 'Packages/ExternalFlowWire').resolve()})
        self.assertEqual({t['name'] for t in package['targets']},
                         {'ExternalFlowCore', 'ExternalFlowProvider', 'ExternalFlowCoreTests'})
        source = self.provider_sources()
        for token in ['NETransparentProxyProvider', 'includedNetworkRules', 'sourceAppSigningIdentifier',
                      'remoteHostname', 'return false', 'probe-report-v1']:
            self.assertIn(token, source)

    def test_flow02_tcp_relay_is_bounded_and_fail_closed(self):
        provider = self.provider_sources()
        core = (PACKAGE / 'Sources/ExternalFlowCore/ExternalFlowRelayCore.swift').read_text()
        wire = (ROOT / 'Packages/ExternalFlowWire/Sources/ExternalFlowWire/ExternalFlowRulesWire.swift').read_text()
        # The TCP-only DIRECT data plane exists and binds the physical interface.
        for token in ['NWConnection(', '.open(withLocalFlowEndpoint:', 'requiredInterface',
                      'ExternalFlowRelay(', 'NWPathMonitor']:
            self.assertIn(token, provider)
        # Still TCP-only: no UDP flow handler, no UDP intercept rule.
        self.assertNotIn('handleNewUDPFlow', provider)
        self.assertNotIn('protocol: .UDP', provider)
        # No payload persistence or logging anywhere in the data plane.
        for token in ['FileHandle', 'print(', 'NSLog', 'os_log', 'write(to:', 'payload']:
            self.assertNotIn(token, provider)
        # Bounds: concurrency limit, chunk size, idle timeout.
        for token in ['maxConcurrent: 64', '65_536', 'idleTimeout: 75']:
            self.assertIn(token, core)
        for token in ['maxConcurrent', 'limitReached', 'cancel()']:
            self.assertIn(token, core)
        # Rules channel is structured, bounded and versioned.
        for token in ['external-flow-rules-v1', 'maxRules = 64', 'maxTargetBytes = 512', 'validated()']:
            self.assertIn(token, wire)

    def test_builder_never_installs_or_executes(self):
        path = ROOT / 'tools/external/flow-build.py'
        project = ROOT / 'tools/external/flow_project.py'
        ast.parse(path.read_text()); ast.parse(project.read_text())
        source = path.read_text() + project.read_text()
        for token in ['systemextensionsctl', 'SMAppService', '/usr/bin/open', 'sudo', 'launchctl',
                      'OSSystemExtensionManager.shared.submitRequest']:
            self.assertNotIn(token, source)
        self.assertIn('/usr/bin/codesign', source)
        self.assertIn('LOCAL_DEVELOPER_ID_VERIFIED', source)
        self.assertIn('app-proxy-provider-systemextension', project.read_text())
        self.assertIn('wrapper.system-extension', (ROOT / 'tools/s1/generate-project.py').read_text())
        self.assertIn('com.apple.networkextension.app-proxy', project.read_text())
        self.assertIn('ExternalFlowProvider.ExternalTransparentProbeProvider', project.read_text())
        self.assertIn('CODE_SIGNING_ALLOWED=NO', path.read_text())
        if sys.platform != 'darwin':
            p = subprocess.run([sys.executable, str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(p.returncode, 69)
            self.assertIn('execution=NOT_RUN', p.stderr)

    def test_signing_arguments_are_explicit_and_complete(self):
        import importlib.util
        path = ROOT / 'tools/external/flow-build.py'
        spec = importlib.util.spec_from_file_location('flow_build', path)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with self.assertRaises(SystemExit):
            module.parse_args(['--identity', 'Developer ID Application'])
        with self.assertRaises(SystemExit):
            module.parse_args(['--sign', '--identity', 'Developer ID Application',
                               '--team-id', 'ABCDE12345'])
        args = module.parse_args([
            '--sign', '--identity', 'Developer ID Application: Example (ABCDE12345)',
            '--team-id', 'ABCDE12345', '--app-profile', 'Flow Probe App',
            '--extension-profile', 'Flow Probe Extension'
        ])
        self.assertTrue(args.sign)
        self.assertEqual(args.team_id, 'ABCDE12345')
        with self.assertRaises(SystemExit):
            module.parse_args([
                '--sign', '--identity', 'Developer ID Application', '--team-id', 'bad',
                '--app-profile', 'A', '--extension-profile', 'B'
            ])

    def test_generated_systemextension_shape(self):
        import importlib.util, tempfile, plistlib
        spec = importlib.util.spec_from_file_location('flow_project', ROOT / 'tools/external/flow_project.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix='flow-project-') as directory:
            project = module.generate(ROOT, Path(directory))
            self.assertTrue((project / 'project.pbxproj').is_file())
            folder = project.parent
            info = plistlib.loads((folder / 'extension-Info.plist').read_bytes())
            self.assertTrue(info['NSSystemExtensionUsageDescription'].strip())
            # OSSystemExtensionRequest .replace only swaps binaries when the
            # bundle version advances; a fixed version silently keeps the old
            # extension (observed 2026-10-14: FLOW-02 binary never installed).
            self.assertNotEqual(info['CFBundleVersion'], '1')
            self.assertRegex(info['CFBundleVersion'], r'^\d{8}\.\d{4}$')
            self.assertEqual(info['NetworkExtension']['NEProviderClasses']['com.apple.networkextension.app-proxy'],
                             'ExternalFlowProvider.ExternalTransparentProbeProvider')
            ent = plistlib.loads((folder / 'extension.entitlements').read_bytes())
            self.assertIn('app-proxy-provider-systemextension', ent['com.apple.developer.networking.networkextension'])
            text = (project / 'project.pbxproj').read_text()
            self.assertIn('VPN-Splitter-FlowProbe', text)
            self.assertIn('FlowProbeExtension', text)
            self.assertIn('wrapper.system-extension', text)

    def test_flow_probe_control_is_explicit_and_not_automatic(self):
        controller = (ROOT / 'integrations/external-flow/FlowProbeController.swift').read_text()
        app = (ROOT / 'integrations/external-flow/FlowProbeApp.swift').read_text()
        project = (ROOT / 'tools/external/flow_project.py').read_text()
        for token in ['OSSystemExtensionRequest.activationRequest', 'NETransparentProxyManager.loadAllFromPreferences',
                      'saveToPreferences()', 'startVPNTunnel()', 'stopVPNTunnel()']:
            self.assertIn(token, controller)
        for token in ['activateExtension()', 'saveProbeConfiguration()', 'startProbe()', 'stopProbe()',
                      'reloadRules()']:
            self.assertIn(token, app)
        self.assertNotIn('.task { control.', app)
        self.assertNotIn('.onAppear', app)
        self.assertIn('FlowProbeController.swift', project)
        self.assertIn('app-proxy-provider-systemextension', project)

    def test_flow01d_report_bridge_is_counts_only_and_explicit(self):
        controller = (ROOT / 'integrations/external-flow/FlowProbeController.swift').read_text()
        app = (ROOT / 'integrations/external-flow/FlowProbeApp.swift').read_text()
        provider = self.provider_sources()
        bridge = (ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalFlowBridgeModel.swift').read_text()
        wire = (ROOT / 'Packages/ExternalFlowWire/Sources/ExternalFlowWire/ExternalFlowProbeWire.swift').read_text()
        for token in ['sendProviderMessage', 'probe-report-v1', 'ExternalFlowProbeSnapshotStore.applicationStore',
                      'publishSnapshot()']:
            self.assertIn(token, controller + app + provider)
        for token in ['configurationCount', 'connectionStatus', 'providerReport',
                      'withSourceSigningIdentifier', 'withRemoteHostname',
                      'rulesLoaded', 'relayStarted', 'relayActive', 'relayCompleted',
                      'relayFailed', 'relayCancelled', 'relayRefusedInterface', 'relayRefusedLimit']:
            self.assertIn(token, wire)
        for forbidden in ['hostname: String', 'signingIdentifier: String', 'ipAddress', 'remotePort', 'payload']:
            self.assertNotIn(forbidden, wire)
        self.assertIn('store.load()', bridge)
        self.assertNotIn('startVPNTunnel', bridge)
        self.assertNotIn('saveToPreferences', bridge)

    def test_flow02_rules_channel_is_explicit_and_user_local(self):
        controller = (ROOT / 'integrations/external-flow/FlowProbeController.swift').read_text()
        bridge = (ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalFlowBridgeModel.swift').read_text()
        store = (ROOT / 'Packages/ExternalFlowWire/Sources/ExternalFlowWire/ExternalFlowRulesBridgeStore.swift').read_text()
        # Main app exports rules only via an explicit action into the user-local bridge.
        for token in ['exportRules', 'ExternalFlowRulesBridgeStore.applicationStore', 'rulesStore.save']:
            self.assertIn(token, bridge)
        self.assertNotIn('startVPNTunnel', bridge)
        self.assertNotIn('saveToPreferences', bridge)
        # Probe app copies rules into providerConfiguration only on explicit reload.
        for token in ['reloadRules', 'ExternalFlowRulesBridgeStore.applicationStore',
                      'VPNSplitterFlowRules', 'saveToPreferences()']:
            self.assertIn(token, controller)
        # Bridge file handling stays hardened: no following symlinks, 0600, bounded.
        for token in ['O_NOFOLLOW', '0o600', 'maximumBytes', 'renameat', 'rules.json']:
            self.assertIn(token, store)
        for forbidden in ['startVPNTunnel', 'NETransparentProxyManager', 'payload']:
            self.assertNotIn(forbidden, store)

    def test_provider_source_parses_for_mac(self):
        directory = PACKAGE / 'Sources/ExternalFlowProvider'
        for source in sorted(directory.glob('*.swift')):
            p = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0', str(source)],
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(p.returncode, 0, str(source) + p.stdout + p.stderr)

if __name__ == '__main__':
    unittest.main()
