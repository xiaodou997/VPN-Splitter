# SPDX-License-Identifier: MIT
"""Compile actual native client methods. Foundation XPC/Security/SMAppService are
explicit API doubles, on every host; this is not real authentication or Apple SDK evidence.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Packages/ExternalControl/Sources/ExternalControl'
FAKES = r'''
public protocol ExternalHelperXPC { func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) }
public extension ExternalControlIdentity { static func currentTeam(helper: Bool) throws -> String { "ABCDE12345" } }
final class MockState: @unchecked Sendable {
    static let shared = MockState()
    let lock = NSLock()
    var instance = UUID(), ticket = UUID()
    var mode = 0, sent = 0, opened = 0, unregistered = 0
    var root: UInt32 = 0
    var active = false
    var requirement = ""
    func noteSend() -> Int { lock.lock(); defer { lock.unlock() }; sent += 1; return mode }
    func getSent() -> Int { lock.lock(); defer { lock.unlock() }; return sent }
}
final class NSXPCInterface { init(with type: Any.Type) {} }
final class MockProxy: ExternalHelperXPC {
    let fail: @Sendable (any Error) -> Void
    init(_ fail: @escaping @Sendable (any Error) -> Void) { self.fail = fail }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        let state = MockState.shared
        let mode = state.noteSend()
        if mode == 2 { return }
        if mode == 4 { fail(NSError(domain: "synthetic", code: 1)); return }
        let request = try! ExternalControlRequest.decode(data)
        var result = ExternalControlResult(state.active ? .active : .idle)
        if request.action == .prepare { result = .init(.prepared) }
        if request.action == .stop { result = .init(.closed) }
        if request.action == .quiesce { result = .init(.closed, code: "quiesced") }
        var response = ExternalControlReply(requestID: mode == 1 ? UUID() : request.id,
            instance: state.instance, canApply: true, result: result)
        if request.action == .prepare { response.ticket = state.ticket }
        reply(response.encoded())
        if mode == 3 { reply(response.encoded()) }
    }
}
final class NSXPCConnection: @unchecked Sendable {
    enum Options { case privileged }
    var remoteObjectInterface: NSXPCInterface?
    var interruptionHandler: (@Sendable () -> Void)?
    var invalidationHandler: (@Sendable () -> Void)?
    var effectiveUserIdentifier: UInt32 { MockState.shared.root }
    init(machServiceName: String, options: Options) {
        precondition(machServiceName == ExternalControlIdentity.service)
        MockState.shared.opened += 1
    }
    func setCodeSigningRequirement(_ value: String) { MockState.shared.requirement = value }
    func resume() {}
    func invalidate() { invalidationHandler?() }
    func remoteObjectProxyWithErrorHandler(_ handler: @escaping @Sendable (any Error) -> Void) -> Any { if MockState.shared.mode == 5 { return NSObject() }; return MockProxy(handler) }
}
final class SMAppService {
    enum Status { case enabled, requiresApproval, notRegistered, notFound }
    var status: Status { MockState.shared.mode == 6 ? .requiresApproval : .enabled }
    static func daemon(plistName: String) -> SMAppService {
        precondition(plistName == ExternalControlIdentity.plist); return SMAppService()
    }
    static func openSystemSettingsLoginItems() { fatalError("no real UI in this test") }
    func register() throws { fatalError("registration not invoked in transport tests") }
    func unregister() async throws { MockState.shared.unregistered += 1 }
}
'''
HARNESS = r'''
@main @MainActor struct Harness {
    static func check(_ ok: Bool) { precondition(ok, "client contract failed") }
    static func wait(_ check: () -> Bool) async throws {
        for _ in 0..<1000 { if check() { return }; try await Task.sleep(for: .milliseconds(1)) }
        fatalError("fixture did not reach request")
    }
    static func main() async throws {
        let state = MockState.shared
        let client = ExternalHelperClient()
        switch CommandLine.arguments[1] {
        case "missing-channel":
            do { _ = try await client.send(.init(.hello)); fatalError("accepted missing channel") }
            catch { check((error as? ExternalControlError) == .channelMissing && state.sent == 0) }
        case "service-disabled":
            state.mode = 6
            do { _ = try await client.connect(); fatalError("accepted disabled service") }
            catch { check((error as? ExternalControlError) == .serviceNotEnabled && state.opened == 0) }
        case "proxy-unavailable":
            state.mode = 5
            do { _ = try await client.connect(); fatalError("accepted wrong proxy") }
            catch { check((error as? ExternalControlError) == .proxyUnavailable && !client.isConnected && state.sent == 0) }
        case "roundtrip":
            let hello = try await client.connect()
            check(state.sent == 1 && client.instance == hello.instance)
            check(state.requirement.contains(ExternalControlIdentity.helper) && state.requirement.contains("ABCDE12345"))
            let prepared = try await client.send(.init(.prepare, instance: client.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7"))
            check(prepared.result.state == .prepared && prepared.ticket != nil)
            client.close(); check(!client.isConnected)
        case "nonroot":
            state.root = 501
            do { _ = try await client.connect(); fatalError("accepted nonroot") }
            catch { check(!client.isConnected && state.sent == 1) }
        case "badreply":
            _ = try await client.connect(); state.mode = 1
            do { _ = try await client.send(.init(.status, instance: client.instance)); fatalError("accepted wrong response ID") }
            catch { check(!client.isConnected) }
        case "duplicate":
            _ = try await client.connect(); state.mode = 3
            _ = try await client.send(.init(.status, instance: client.instance))
            await Task.yield(); check(client.isConnected); client.close()
        case "pending-close":
            _ = try await client.connect(); state.mode = 2
            let work = Task { @MainActor in
                do { _ = try await client.send(.init(.status, instance: client.instance)); return false }
                catch { return true }
            }
            try await wait { state.getSent() == 2 }
            do { _ = try await client.send(.init(.status, instance: client.instance)); fatalError("accepted concurrent request") }
            catch { check((error as? ExternalControlError) == .requestInFlight && state.getSent() == 2) }
            client.close(); check(await work.value); check(!client.isConnected)
            state.mode = 0
            _ = try await client.connect(); await Task.yield(); check(client.isConnected)
            client.close()
        case "errorhandler":
            _ = try await client.connect(); state.mode = 4
            do { _ = try await client.send(.init(.status, instance: client.instance)); fatalError("proxy error ignored") }
            catch { check(!client.isConnected) }
        case "unregister":
            try await client.unregisterAfterCleanStatus()
            check(state.sent == 3 && state.unregistered == 1 && !client.isConnected)
        case "active-unregister":
            _ = try await client.connect(); state.active = true
            do { try await client.unregisterAfterCleanStatus(); fatalError("active unregistered") }
            catch { check(state.unregistered == 0) }
            client.close()
        default: fatalError("unknown fixture")
        }
        print("native-client=PASS apple_xpc_signing_service=TEST_DOUBLES network=NOT_READ")
    }
}
'''
class NativeClientTests(unittest.TestCase):
    def run_mode(self, optimization):
        client = (SOURCE / 'ExternalHelperClient.swift').read_text()
        self.assertEqual(client.count('#if os(macOS)'), 1)
        client = client.replace('#if os(macOS)', '').replace('#endif', '')
        client = client.replace('import ServiceManagement', '').replace('import Darwin', '')
        identity = (SOURCE / 'ExternalControlIdentity.swift').read_text().split('#if os(macOS)')[0]
        wire = (SOURCE / 'ExternalControlWire.swift').read_text()
        with tempfile.TemporaryDirectory(prefix='external-client-') as directory:
            root = Path(directory); source = root / 'Harness.swift'; exe = root / 'test-client'
            source.write_text(wire + identity + FAKES + client + HARNESS)
            compile = subprocess.run(['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                optimization, '-parse-as-library', str(source), '-o', str(exe)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compile.returncode, 0, compile.stdout + compile.stderr)
            for scenario in ['missing-channel', 'service-disabled', 'proxy-unavailable', 'roundtrip', 'nonroot', 'badreply', 'duplicate', 'pending-close', 'errorhandler', 'unregister', 'active-unregister']:
                with self.subTest(scenario=scenario):
                    run = subprocess.run([str(exe), scenario], capture_output=True, text=True, timeout=10)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn('native-client=PASS', run.stdout)
    def test_actual_client_debug(self): self.run_mode('-Onone')
    def test_actual_client_optimized(self): self.run_mode('-O')
if __name__ == '__main__': unittest.main()
