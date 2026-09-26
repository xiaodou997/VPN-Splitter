# SPDX-License-Identifier: MIT
"""Actual S1 generator + runtime overlay, with synthetic plist inputs; not xcodebuild."""
import ast
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
def load(name, path):
    s = importlib.util.spec_from_file_location(name, path); m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m
RUNTIME = load('runtime_project', ROOT / 'tools/provider/runtime_project.py')
GEN = load('s1', ROOT / 'tools/s1/generate-project.py')

class RuntimeProjectTests(unittest.TestCase):
    def test_real_generator_overlay_preserves_base_and_links_actual_provider(self):
        original = GEN.build_project()
        with tempfile.TemporaryDirectory(prefix='vpn-runtime-project-') as d:
            root = Path(d) / 'repository with space'; root.mkdir()
            run = Path(d) / 'run'; run.mkdir()
            for target in ['App', 'PacketTunnel']:
                path = root / 'apps/macos' / target; path.mkdir(parents=True)
                (path / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)'}))
            for filename in RUNTIME.SOURCES:
                path = root / 'integrations/wireguard' / filename; path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / 'integrations/wireguard' / filename, path)
            project = RUNTIME.generate(root, run, GEN)
            generated = json.loads((project.parent / 'project-objects.json').read_text()); objects = generated['objects']
            self.assertEqual(GEN.build_project(), original)
            products = [objects[x]['productName'] for x in objects[GEN.ident('tunnel.target')]['packageProductDependencies']]
            self.assertEqual(set(products), {'PolicyCore', 'ProviderConfiguration', 'ProviderSession', 'ManagedSettings', 'ManagedSettingsApple', 'WireGuardKit'})
            build = objects[GEN.ident('tunnel.Release')]['buildSettings']
            self.assertIn('VPNSPLITTER_PACKET_FLOW_RUNTIME', build['SWIFT_ACTIVE_COMPILATION_CONDITIONS'])
            self.assertIn(str(run / 'lib/libwg-go.a'), build['OTHER_LDFLAGS'])
            self.assertTrue(plistlib.loads(Path(build['INFOPLIST_FILE']).read_bytes())['VPNPacketFlowRuntime'])
            self.assertEqual(len([x for x in objects.values() if x['isa'] == 'PBXNativeTarget']), 2)
            self.assertFalse(any(x['isa'] == 'XCRemoteSwiftPackageReference' for x in objects.values()))
            refs = [objects[x['fileRef']]['path'] for x in objects.values() if x['isa'] == 'PBXBuildFile' and 'fileRef' in x]
            for filename in RUNTIME.SOURCES: self.assertIn(str(root / 'integrations/wireguard' / filename), refs)
            self.assertNotIn('packet_flow/fixtures', (project / 'project.pbxproj').read_text())
    def test_explicit_commands_are_routed_without_install_or_run(self):
        with tempfile.TemporaryDirectory(prefix='vpn-runtime-dispatch-') as d:
            root = Path(d); shutil.copyfile(ROOT / 'dev.sh', root / 'dev.sh')
            folder = root / 'tools/provider'; folder.mkdir(parents=True)
            (folder / 'build-runtime.py').write_text('import sys\nprint("build " + " ".join(sys.argv[1:]))\n')
            (folder / 'runtime-test.sh').write_text('echo runtime-test\n')
            for args, expected in [(['provider-build'], 'build'), (['provider-build', '--fetch', '--sign'], 'build --fetch --sign'), (['provider-runtime-test'], 'runtime-test')]:
                p = subprocess.run(['/bin/bash', str(root / 'dev.sh'), *args], capture_output=True, text=True, timeout=10)
                self.assertEqual(p.returncode, 0, p.stderr); self.assertEqual(p.stdout.strip(), expected)
        source = (ROOT / 'tools/provider/build-runtime.py').read_text(); ast.parse(source)
        for bad in ['systemextensionsctl', '/usr/bin/open', 'startVPNTunnel(', 'sudo ', '-allowProvisioningUpdates']:
            self.assertNotIn(bad, source)
        self.assertIn('CODE_SIGNING_ALLOWED=NO', source)
        self.assertIn('require_packet_flow_symbols(symbols)', source)
    def test_provider_and_legacy_check_have_distinct_paths(self):
        provider = (ROOT / 'apps/macos/PacketTunnel/PacketTunnelProvider.swift').read_text()
        self.assertIn('if received.purpose == .run', provider)
        self.assertIn('ManagedPacketFlowSession.make(provider: self', provider)
        self.assertIn('session.start', provider); self.assertIn('session.stop', provider)
        self.assertEqual(provider.count('#if os(macOS)'), 5)
        host = (ROOT / 'integrations/wireguard/ManagedPacketFlowSession.swift').read_text()
        for token in ['ProviderSessionController(', 'PreparedWireGuardPlan.prepare(', 'SplitterPacketFlowBackend.start(', 'setTunnelNetworkSettings(nil)', 'monitor.checkNow()']:
            self.assertIn(token, host)
        self.assertNotIn('observeSystemTeardown(', host)
        self.assertNotIn('generateNetworkSettings(', host)
    def test_all_new_native_sources_parse_with_runtime_condition(self):
        sources = ['apps/macos/PacketTunnel/PacketTunnelProvider.swift', 'apps/macos/App/ManagedConfigurationView.swift',
            'integrations/wireguard/ManagedUnderlayMonitor.swift', 'integrations/wireguard/ManagedPacketFlowSession.swift',
            'Packages/ProviderConfiguration/Sources/ProviderConfiguration/ManagedNativeApp.swift',
            'Packages/ProviderConfiguration/Sources/ProviderConfiguration/ManagedAuthenticatedXPC.swift']
        p = subprocess.run(['swiftc', '-frontend', '-parse', '-target', 'arm64-apple-macos26.0',
            '-D', 'VPNSPLITTER_PACKET_FLOW_RUNTIME', *[str(ROOT / s) for s in sources]], capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

if __name__ == '__main__': unittest.main()
