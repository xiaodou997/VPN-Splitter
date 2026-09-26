# SPDX-License-Identifier: MIT
"""Selected actual sources; native NE/logging/delivery are explicit test doubles.
This is NOT a full AppCore/ProviderConfiguration build, OS authentication or a VPN test.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
S = ROOT / 'Packages/ProviderConfiguration/Sources/ProviderConfiguration'

def read(path): return (ROOT / path).read_text()

class MaterialAdmissionTests(unittest.TestCase):
    def test_local_dependencies_are_explicit_and_no_remote_source_added(self):
        result = subprocess.run(['swift', 'package', '--package-path', str(ROOT / 'Packages/ProviderConfiguration'), 'dump-package'], capture_output=True, text=True, check=True, timeout=60)
        package = json.loads(result.stdout)
        local = [d['fileSystem'][0]['identity'] for d in package['dependencies']]
        self.assertEqual(sorted(local), ['appcore', 'policycore'])
        self.assertEqual(package['platforms'][0]['version'], '26.0')
        app = subprocess.run(['swift', 'package', '--package-path', str(ROOT / 'Packages/AppCore'), 'dump-package'], capture_output=True, text=True, check=True, timeout=60)
        self.assertEqual([d['fileSystem'][0]['identity'] for d in json.loads(app.stdout)['dependencies']], ['policycore'])

    def test_formal_save_validates_exact_snapshot_before_any_transaction(self):
        source = (S / 'ManagedNativeApp.swift').read_text().split('public func save(configuration:', 1)[1].split('public func checkDelivery()', 1)[0]
        self.assertLess(source.index('ManagedWireGuardInput.prepare('), source.index('transaction.save('))
        self.assertIn('checked.withValidatedSource', source)
        self.assertIn('ManagedCredentialMaterial(configuration: $0, policyArchive: $1)', source)

    def test_authenticated_loading_then_recheck_precedes_staging(self):
        source = (S / 'ManagedNativeApp.swift').read_text().split('public func checkDelivery()', 1)[1]
        tokens = ['client.hello(', 'transaction.material(', 'ManagedWireGuardInput.prepare(', 'client.stage(', 'transaction.validateForStart(', 'store.submit(']
        self.assertEqual([source.index(t) for t in tokens], sorted(source.index(t) for t in tokens))
        self.assertIn('checked.withValidatedSource', source)
        self.assertIn('client.close()', source)

    def test_provider_revalidates_after_consumption_before_engine_blocker(self):
        source = read('apps/macos/PacketTunnel/PacketTunnelProvider.swift')
        start = source.split('let received = try runtime.consume', 1)[1]
        self.assertLess(start.index('ManagedWireGuardInput.prepare('), start.index('code: 2001'))
        self.assertIn('code: 2004', start)
        for forbidden in ['completionHandler(nil)', 'setTunnelNetworkSettings(', 'WireGuardAdapter(', 'readPackets(']:
            self.assertNotIn(forbidden, source)

    def test_ui_uses_same_encoder_and_safe_reader_and_clears_failed_selection(self):
        source = read('apps/macos/App/ManagedConfigurationView.swift')
        self.assertIn('ManagedWireGuardInput.readConfigurationFile(url)', source)
        self.assertIn('ManagedWireGuardInput.encodeIncludePolicy(rules)', source)
        self.assertIn('configuration = nil; fileSelected = false; saveConsent = false', source)
        self.assertIn('error as? ManagedWireGuardInputError', source)
        for forbidden in ['.onAppear', '.task', 'FileHandle(forReadingFrom:', 'resourceValues(forKeys:']:
            self.assertNotIn(forbidden, source)

    def test_real_provider_branch_with_actual_importer_and_policy(self):
        swiftc = shutil.which('swiftc')
        self.assertIsNotNone(swiftc)
        with tempfile.TemporaryDirectory(prefix='vpn-material-provider-') as directory:
            build = Path(directory)
            suffix = 'dylib' if sys.platform == 'darwin' else 'so'
            def run(args, env=None):
                result = subprocess.run(args, cwd=build, capture_output=True, text=True, env=env, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result
            def library(name, files, deps=()):
                run([swiftc, '-swift-version', '6', '-warnings-as-errors', '-emit-library', '-emit-module',
                     '-module-name', name, '-I', str(build), '-L', str(build), *['-l' + d for d in deps],
                     *map(str, files), '-o', str(build / ('lib' + name + '.' + suffix))])
            # Entire PolicyCore/importer, complete material and planning declarations.
            # Exclude unrelated workspace/vault/UI declarations at unique source boundaries.
            core = ROOT / 'Packages/PolicyCore/Sources/PolicyCore'
            library('PolicyCore', [core / n for n in ['IPv4.swift', 'Policy.swift', 'Compiler.swift', 'Constraints.swift']])
            app = ROOT / 'Packages/AppCore/Sources/AppCore'
            for name, marker in [('Credentials.swift', '/// Only this internal envelope'), ('WireGuardPlanning.swift', '/// Confirmation creates a NEW profile')]:
                source = (app / name).read_text()
                (build / name).write_text(source.split(marker, 1)[0])
            library('AppCore', [app / 'WireGuardImport.swift', build / 'Credentials.swift', build / 'WireGuardPlanning.swift'], ['PolicyCore'])
            library('ProviderConfiguration', [S / 'ManagedLaunch.swift', S / 'ManagedWireGuardInput.swift'], ['AppCore', 'PolicyCore'])
            (build / 'NetworkExtension.swift').write_text('''// TEST DOUBLE: no native framework behavior.
import Foundation
public enum NEProviderStopReason { case userInitiated }
open class NEVPNProtocol { public init() {} }
open class NETunnelProviderProtocol: NEVPNProtocol {
 public var providerBundleIdentifier: String?
 public var providerConfiguration: [String: Any]?
 public var passwordReference: Data?
 public var username: String?
}
open class NEPacketTunnelProvider {
 public var protocolConfiguration: NEVPNProtocol = NETunnelProviderProtocol()
 public init() {}
 open func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {}
 open func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {}
}
''')
            (build / 'os.swift').write_text('''// TEST DOUBLE: no Apple logging/privacy behavior.
public struct Logger: Sendable {
 public init(subsystem: String, category: String) {}
 public func notice(_ message: Message) {}
}
public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
 public init(stringLiteral value: String) {}
 public init(stringInterpolation: StringInterpolation) {}
 public struct StringInterpolation: StringInterpolationProtocol {
  public enum Privacy { case `public` }
  public init(literalCapacity: Int, interpolationCount: Int) {}
  public mutating func appendLiteral(_ literal: String) {}
  public mutating func appendInterpolation(_ value: String, privacy: Privacy) {}
 }
}
''')
            for name in ['NetworkExtension', 'os']: library(name, [build / (name + '.swift')])
            source = read('apps/macos/PacketTunnel/PacketTunnelProvider.swift')
            self.assertEqual(source.count('#if os(macOS)'), 5)
            self.assertEqual(source.count('Bundle.main.bundleIdentifier'), 1)
            # Enable the ACTUAL macOS admission/stop bodies in this explicit test copy.
            # Production source never contains these test flags or injected IDs.
            source = source.replace('#if os(macOS)', '#if MATERIAL_ADMISSION_TEST')
            source = source.replace('Bundle.main.bundleIdentifier', 'Optional("test.vpnsplitter.provider")')
            (build / 'PacketTunnelProvider.swift').write_text(source)
            executable = build / 'material-provider-harness'
            run([swiftc, '-swift-version', '6', '-warnings-as-errors', '-D', 'MATERIAL_ADMISSION_TEST', '-parse-as-library',
                 '-I', str(build), '-L', str(build), '-lNetworkExtension', '-los', '-lPolicyCore', '-lAppCore', '-lProviderConfiguration',
                 str(build / 'PacketTunnelProvider.swift'), str(ROOT / 'tests/provider/fixtures/MaterialAdmissionHarness.swift'), '-o', str(executable)])
            env = dict(os.environ)
            env['DYLD_LIBRARY_PATH' if sys.platform == 'darwin' else 'LD_LIBRARY_PATH'] = str(build)
            result = run([str(executable)], env=env)
            self.assertIn('material-provider-harness=PASS scenarios=10 parser_policy=ACTUAL', result.stdout)
            self.assertIn('native_auth=NOT_TESTED', result.stdout)
            print(result.stdout.strip())

if __name__ == '__main__': unittest.main()
