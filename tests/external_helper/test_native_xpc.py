# SPDX-License-Identifier: MIT
"""Real anonymous macOS NSXPC transport, with identity/registration doubles.
No privileged service, route, journal, signing key, or installed App is accessed.
"""
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Packages/ExternalControl/Sources/ExternalControl'
HARNESS = r'''
@objc public protocol ExternalHelperXPC {
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void)
}
public extension ExternalControlIdentity {
    static func currentTeam(helper: Bool) throws -> String { "ABCDE12345" }
}
final class SMAppService {
    enum Status { case enabled, requiresApproval, notRegistered, notFound }
    var status: Status { .enabled }
    static func daemon(plistName: String) -> SMAppService { SMAppService() }
    static func openSystemSettingsLoginItems() { fatalError("not used") }
    func register() throws { fatalError("not used") }
    func unregister() async throws { fatalError("not used") }
}
private final class Endpoint: NSObject, ExternalHelperXPC, @unchecked Sendable {
    let channel: NSXPCConnection
    let interrupt: Bool
    let instance = UUID()
    init(_ channel: NSXPCConnection, interrupt: Bool) { self.channel = channel; self.interrupt = interrupt }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        if interrupt { channel.invalidate(); return }
        let request = try! ExternalControlRequest.decode(data)
        reply(ExternalControlReply(requestID: request.id, instance: instance, canApply: false,
            result: .init(.idle, code: request.action == .hello ? "none" : "noRecovery")).encoded())
    }
}
private final class Delegate: NSObject, NSXPCListenerDelegate {
    let interrupt: Bool
    init(interrupt: Bool) { self.interrupt = interrupt }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection channel: NSXPCConnection) -> Bool {
        channel.exportedInterface = NSXPCInterface(with: ExternalHelperXPC.self)
        channel.exportedObject = Endpoint(channel, interrupt: interrupt)
        channel.resume(); return true
    }
}
@main struct NativeHarness {
    @MainActor static var endpoint: NSXPCListenerEndpoint?
    @MainActor static func main() async throws {
        let interrupted = CommandLine.arguments[1] == "interrupted"
        let listener = NSXPCListener.anonymous(); let delegate = Delegate(interrupt: interrupted)
        listener.delegate = delegate; listener.resume(); endpoint = listener.endpoint
        let client = ExternalHelperClient()
        do {
            _ = try await client.connect()
            precondition(!interrupted, "unexpected accepted interrupted connection")
            let result = try await client.send(.init(.recoveryAudit, instance: client.instance))
            precondition(result.result.code == "noRecovery")
        } catch {
            // Remote teardown surfaces as interruption or invalidation depending on timing.
            precondition(interrupted && [ExternalControlError.xpcInterrupted, .xpcInvalid].contains(error as? ExternalControlError))
            precondition(!client.isConnected)
        }
        client.close(); listener.invalidate()
        withExtendedLifetime(delegate) {}
        print("native_anonymous_xpc=PASS identity_registration=DOUBLES route_writes=NONE")
    }
}
'''

@unittest.skipUnless(platform.system() == 'Darwin', 'real Foundation XPC requires macOS')
class NativeXPCTests(unittest.TestCase):
    def test_roundtrip_and_error_callback(self):
        client = (SOURCE / 'ExternalHelperClient.swift').read_text().replace('import ServiceManagement', '')
        old = 'NSXPCConnection(machServiceName: ExternalControlIdentity.service, options: .privileged)'
        self.assertEqual(client.count(old), 1)
        client = client.replace(old, 'NSXPCConnection(listenerEndpoint: NativeHarness.endpoint!)')
        client = client.replace('channel.setCodeSigningRequirement(try ExternalControlIdentity.requirement(team: team, helper: true))', '_ = team')
        client = client.replace('channel.effectiveUserIdentifier == 0', 'channel.effectiveUserIdentifier == getuid()')
        source = ((SOURCE / 'ExternalControlIdentity.swift').read_text().split('#if os(macOS)')[0]
                  + (SOURCE / 'ExternalControlWire.swift').read_text() + HARNESS + client)
        with tempfile.TemporaryDirectory(prefix='external-native-xpc-') as directory:
            path = Path(directory); swift = path / 'main.swift'; binary = path / 'native-xpc'
            swift.write_text(source)
            for optimization in ['-Onone', '-O']:
                built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                    '-parse-as-library', optimization, str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=60)
                self.assertEqual(built.returncode, 0, built.stderr)
                for mode in ['roundtrip', 'interrupted']:
                    with self.subTest(optimization=optimization, mode=mode):
                        run = subprocess.run([str(binary), mode], capture_output=True, text=True, timeout=10)
                        self.assertEqual(run.returncode, 0, run.stderr[-3000:])
                        self.assertIn('native_anonymous_xpc=PASS', run.stdout)
