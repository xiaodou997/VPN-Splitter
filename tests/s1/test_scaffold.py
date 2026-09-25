# SPDX-License-Identifier: MIT
"""Offline contract checks, not an Xcode build or a signing/extension acceptance test."""
import datetime
import importlib.util
import pathlib
import plistlib
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET

ROOT=pathlib.Path(__file__).resolve().parents[2]
def load(name,file):
    spec=importlib.util.spec_from_file_location(name,ROOT/file)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
GEN=load('generator','tools/s1/generate-project.py')
VERIFY=load('verify','tools/s1/verify-bundle.py')

def read(p): return (ROOT/p).read_text()
def plist(p): return plistlib.loads((ROOT/p).read_bytes())

class ProjectTests(unittest.TestCase):
    def test_generator_matches_checked_in_project(self):
        self.assertEqual(GEN.render(),read('apps/macos/VPN-Splitter.xcodeproj/project.pbxproj'))
    def test_references_are_valid(self):
        p=GEN.build_project();o=p['objects']
        single={'fileRef','productRef','baseConfigurationReference','buildConfigurationList','containerPortal','remoteGlobalIDString','target','targetProxy','productReference','mainGroup','productRefGroup','package'}
        many={'children','files','buildConfigurations','buildPhases','dependencies','packageProductDependencies','packageReferences','targets'}
        for obj in o.values():
            for key,value in obj.items():
                if key in single: self.assertIn(value,o,key)
                if key in many:
                    for item in value: self.assertIn(item,o,key)
    def test_exactly_app_and_system_extension(self):
        types=[o['productType'] for o in GEN.build_project()['objects'].values() if o['isa']=='PBXNativeTarget']
        self.assertCountEqual(types,['com.apple.product-type.application','com.apple.product-type.system-extension'])
    def test_embedding_dependency(self):
        o=GEN.build_project()['objects'];e=o[GEN.ident('embed')]
        self.assertEqual(e['dstSubfolderSpec'],'16')
        self.assertEqual(e['dstPath'],'$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions')
        self.assertEqual(o[GEN.ident('target.dep')]['target'],GEN.ident('tunnel.target'))
    def test_local_package_only(self):
        o=GEN.build_project()['objects'];self.assertEqual(o[GEN.ident('package')]['relativePath'],'../../Packages/PolicyCore')
        self.assertFalse(any(x['isa']=='XCRemoteSwiftPackageReference' for x in o.values()))
    def test_no_container_relative_provider_framework(self):
        o=GEN.build_project()['objects']
        for n in ('Debug','Release','DeveloperID'):
            self.assertEqual(o[GEN.ident('tunnel.'+n)]['buildSettings']['LD_RUNPATH_SEARCH_PATHS'],['$(inherited)','@executable_path/../Frameworks'])
    def test_three_configs(self):
        for role in ('app','tunnel','project'):
            o=GEN.build_project()['objects'];configs=o[GEN.ident(role+'.configs')]['buildConfigurations']
            self.assertEqual([o[k]['name'] for k in configs],['Debug','Release','DeveloperID'])
    def test_provider_registration(self):
        p=plist('apps/macos/PacketTunnel/Info.plist')
        self.assertNotIn('NSExtension',p)
        self.assertEqual(p['CFBundlePackageType'],'SYSX')
        self.assertEqual(p['NetworkExtension']['NEProviderClasses']['com.apple.networkextension.packet-tunnel'],'$(PRODUCT_MODULE_NAME).PacketTunnelProvider')
    def test_usage_descriptions(self):
        for n in ('App','PacketTunnel'):
            self.assertTrue(plist(f'apps/macos/{n}/Info.plist')['NSSystemExtensionUsageDescription'])
    def test_channel_entitlements(self):
        for n,ne in [('Development','packet-tunnel-provider'),('DeveloperID','packet-tunnel-provider-systemextension')]:
            for target in ('App','PacketTunnel'):
                p=plist(f'apps/macos/Config/{target}.{n}.entitlements')
                self.assertEqual(p['com.apple.developer.networking.networkextension'],[ne])
                self.assertNotIn('com.apple.security.get-task-allow',p)
                self.assertNotIn('com.apple.security.application-groups',p)
    def test_least_privilege_entitlements(self):
        for n in ('Development','DeveloperID'):
            a=plist(f'apps/macos/Config/App.{n}.entitlements');t=plist(f'apps/macos/Config/PacketTunnel.{n}.entitlements')
            self.assertTrue(a['com.apple.developer.system-extension.install'])
            self.assertTrue(t['com.apple.security.app-sandbox'])
            self.assertNotIn('com.apple.developer.system-extension.install',t)
    def test_no_network_data_plane(self):
        p=read('apps/macos/PacketTunnel/PacketTunnelProvider.swift')
        for invocation in ('setTunnelNetworkSettings(', 'readPackets(', 'writePackets(', 'NWConnection(', 'URLSession.'):
            self.assertNotIn(invocation,p)
        self.assertIn('code: 1001',p);self.assertIn('S1_PROVIDER_REACHED',p)
        self.assertIn('UUID(uuidString: raw)',p)
    def test_no_automatic_profile_or_activation(self):
        app=read('apps/macos/App/VPNSplitterApp.swift');controller=read('apps/macos/App/SpikeController.swift')
        self.assertNotIn('.onAppear',app);self.assertNotIn('.task',app)
        self.assertIn('m.isOnDemandEnabled = false',controller)
        self.assertIn('matches.count <= 1',controller)
        self.assertIn('throw SpikeError.foreignProfile',controller)
    def test_entrypoint_and_shared_scheme(self):
        self.assertIn('NEProvider.startSystemExtensionMode()',read('apps/macos/PacketTunnel/main.swift'))
        self.assertIn('dispatchMain()',read('apps/macos/PacketTunnel/main.swift'))
        tree=ET.parse(ROOT/'apps/macos/VPN-Splitter.xcodeproj/xcshareddata/xcschemes/VPN-Splitter.xcscheme')
        ref=tree.find('.//BuildableReference');self.assertEqual(ref.attrib['BlueprintIdentifier'],GEN.ident('app.target'))
    def test_shell_syntax(self):
        subprocess.run(['/bin/bash','-n',str(ROOT/'tools/s1/build.sh')],check=True)
    @unittest.skipIf(sys.platform=='darwin','negative environment test is for Linux')
    def test_non_mac_build_rejected(self):
        p=subprocess.run(['/bin/bash',str(ROOT/'tools/s1/build.sh'),'unsigned'],capture_output=True)
        self.assertEqual(p.returncode,69)
    def test_build_never_installs(self):
        s=read('tools/s1/build.sh')
        self.assertNotIn('sudo ',s.replace('# Build only. Never installs/activates an extension, saves a VPN profile, or invokes sudo.',''))
        self.assertNotIn('/usr/bin/open ',s)
        self.assertNotIn('systemextensionsctl ',s)
        self.assertIn('CODE_SIGNING_ALLOWED=NO',s)
        self.assertIn('verify-bundle.py',s)

class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.now=datetime.datetime(2026,9,25,tzinfo=datetime.timezone.utc)
        self.p={'TeamIdentifier':['ABCDEFGHIJ'],'ApplicationIdentifierPrefix':['ABCDEFGHIJ'],
                'ExpirationDate':datetime.datetime(2027,1,1),
                'Entitlements':{'com.apple.application-identifier':'ABCDEFGHIJ.test.app',
                    'com.apple.developer.networking.networkextension':['packet-tunnel-provider']}}
    def check(self): return VERIFY.profile_check(self.p,'test.app','ABCDEFGHIJ','packet-tunnel-provider',self.now)
    def test_valid_profile(self): self.assertTrue(self.check())
    def test_legacy_prefix_is_distinct_from_team(self):
        self.p['ApplicationIdentifierPrefix']=['LEGACY1234'];self.p['Entitlements']['com.apple.application-identifier']='LEGACY1234.test.app';self.check()
    def test_expired_profile_rejected(self):
        self.p['ExpirationDate']=datetime.datetime(2020,1,1)
        with self.assertRaises(VERIFY.VerificationError): self.check()
    def test_wrong_team(self):
        self.p['TeamIdentifier']=['WRONGTEAM1']
        with self.assertRaises(VERIFY.VerificationError): self.check()
    def test_wrong_id(self):
        self.p['Entitlements']['com.apple.application-identifier']='ABCDEFGHIJ.other'
        with self.assertRaises(VERIFY.VerificationError): self.check()
    def test_wildcard_not_silently_accepted(self):
        self.p['Entitlements']['com.apple.application-identifier']='ABCDEFGHIJ.*'
        with self.assertRaises(VERIFY.VerificationError): self.check()
    def test_wrong_entitlement_channel(self):
        self.p['Entitlements']['com.apple.developer.networking.networkextension']=['packet-tunnel-provider-systemextension']
        with self.assertRaises(VERIFY.VerificationError): self.check()
    def test_expiry_missing(self):
        del self.p['ExpirationDate']
        with self.assertRaises(VERIFY.VerificationError): self.check()

if __name__=='__main__': unittest.main()
