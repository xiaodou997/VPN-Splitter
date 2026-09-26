// SPDX-License-Identifier: MIT
// Real Swift pump -> real C ABI -> real Go queues/tun -> FAKE plaintext echo engine.
// Framework, model, admission, lifecycle and engine doubles are explicit.
import Foundation
import Dispatch
import NetworkExtension
import ProviderConfiguration
import PolicyCore
import WireGuardKit

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var flag = true
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func revoke() { lock.lock(); flag = false; lock.unlock() }
}
final class Failures: @unchecked Sendable {
    private let lock = NSLock(); private var observed: [SplitterPacketFlowError] = []
    func add(_ error: SplitterPacketFlowError) { lock.lock(); observed.append(error); lock.unlock() }
    var values: [SplitterPacketFlowError] { lock.lock(); defer { lock.unlock() }; return observed }
}
@main
struct PacketFlowHarness {
    static func main() throws {
        let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
        let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
        let psk = Data(repeating: 3, count: 32).base64EncodedString()
        let config = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.55.0.2/24
        ListenPort = 0
        MTU = 1420
        [Peer]
        PublicKey = \(publicKey)
        PresharedKey = \(psk)
        AllowedIPs = 10.99.0.0/16, 10.88.0.7
        Endpoint = 198.51.100.20:51820
        PersistentKeepalive = off # explicit zero, no secret
        """
        var scenarios = 0
        func scenario(_ name: String, _ body: () throws -> Void) throws {
            try body(); scenarios += 1; print("packet-flow-case=PASS \(name)")
        }
        func wait(_ condition: () -> Bool) {
            let end = ProcessInfo.processInfo.systemUptime + 3
            while !condition() {
                precondition(ProcessInfo.processInfo.systemUptime < end, "fixture deadline exceeded")
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
        func native(_ text: String? = nil) throws -> ManagedWireGuardNativeInput {
            try ManagedWireGuardNativeInput(CheckedManagedWireGuardInput(text ?? config))
        }
        func start(_ provider: NEPacketTunnelProvider, live: Flag = Flag(), failure: Failures = Failures(), configuration: TunnelConfiguration? = nil, mtu: Int = 1420) throws -> SplitterPacketFlowBackend {
            try SplitterPacketFlowBackend.start(provider: provider, configuration: configuration ?? native().makeConfiguration(), mtu: mtu, isCurrent: { live.value }, failure: { failure.add($0) })
        }
        func packet(_ byte: UInt8 = 7) -> Data {
            var p = Data(repeating: byte, count: 64); p[0] = 0x45; p[2] = 0; p[3] = 64; return p
        }
        try scenario("native-fields-and-all-keys") {
            let value = try native(); let c = value.makeConfiguration()
            precondition(c.interface.privateKey.base64Key == privateKey)
            precondition(c.peers[0].publicKey.base64Key == publicKey && c.peers[0].preSharedKey?.base64Key == psk)
            precondition(c.interface.addresses[0].stringRepresentation == "10.55.0.2/24")
            precondition(c.peers[0].allowedIPs.map(\.stringRepresentation) == ["10.99.0.0/16", "10.88.0.7/32"])
            precondition(c.interface.listenPort == 0 && c.interface.mtu == 1420 && c.peers[0].persistentKeepAlive == 0)
            precondition(value.policy == IPv4Policy(73))
        }
        try scenario("bom-crlf-off-normalization") {
            let value = try native("\u{feff}" + config.replacingOccurrences(of: "\n", with: "\r\n"))
            precondition(value.makeConfiguration().peers[0].persistentKeepAlive == 0)
        }
        try scenario("fresh-reference-and-redaction") {
            let value = try native(); let c = value.makeConfiguration(); c.peers.removeAll(); c.interface.addresses.removeAll()
            precondition(value.makeConfiguration().peers.count == 1 && value.makeConfiguration().interface.addresses.count == 1)
            precondition(Mirror(reflecting: value).children.isEmpty && !String(reflecting: value).contains(privateKey))
        }
        try scenario("native-projection-mismatch") {
            var metadata = Metadata(); metadata.mtu = 1400
            do { _ = try ManagedWireGuardNativeInput(CheckedManagedWireGuardInput(config, metadata: metadata)); preconditionFailure() }
            catch { precondition(error as? ManagedWireGuardNativeInputError == .projectionChanged) }
        }
        try scenario("upstream-parser-error-redaction") {
            do { _ = try native(config + "\nSENSITIVE_UNKNOWN_FIELD = SENSITIVE_SECRET"); preconditionFailure() }
            catch { precondition(error as? ManagedWireGuardNativeInputError == .conversion && !String(reflecting: error).contains("SENSITIVE")) }
        }
        try scenario("swift-c-go-tun-roundtrip") {
            let p = NEPacketTunnelProvider(); let errors = Failures(); let b = try start(p, failure: errors)
            wait { p.packetFlow.readIsPending }; p.packetFlow.inject([packet()]); wait { p.packetFlow.packets.count == 1 }
            precondition(p.packetFlow.packets == [packet()]); b.stop(); precondition(errors.values.isEmpty)
        }
        try scenario("stop-unblocks-c-read") {
            let p = NEPacketTunnelProvider(); let b = try start(p)
            wait { p.packetFlow.readIsPending }; b.stop(); b.stop()
        }
        try scenario("stale-read-cannot-touch-new-handle") {
            let old = NEPacketTunnelProvider(); let b = try start(old); wait { old.packetFlow.readIsPending }; b.stop()
            let fresh = NEPacketTunnelProvider(); let next = try start(fresh); wait { fresh.packetFlow.readIsPending }
            old.packetFlow.replayOld(packet(99)); fresh.packetFlow.inject([packet(3)])
            wait { fresh.packetFlow.packets.count == 1 }; next.stop()
            precondition(old.packetFlow.packets.isEmpty && fresh.packetFlow.packets == [packet(3)])
        }
        try scenario("revoked-before-start") {
            let live = Flag(); live.revoke()
            do { _ = try start(NEPacketTunnelProvider(), live: live); preconditionFailure() }
            catch { precondition(error as? SplitterPacketFlowError == .stale) }
        }
        try scenario("revoked-after-start") {
            let p = NEPacketTunnelProvider(); let live = Flag(); let errors = Failures(); let b = try start(p, live: live, failure: errors)
            wait { p.packetFlow.readIsPending }; live.revoke(); p.packetFlow.inject([packet()]); wait { !errors.values.isEmpty }; b.stop()
            precondition(errors.values == [.stale] && p.packetFlow.packets.isEmpty)
        }
        try scenario("ipv6-family-is-not-forwarded") {
            let p = NEPacketTunnelProvider(); let errors = Failures(); let b = try start(p, failure: errors)
            wait { p.packetFlow.readIsPending }; p.packetFlow.inject([packet()], family: 30); wait { !errors.values.isEmpty }; b.stop()
            precondition(errors.values == [.packetBatch] && p.packetFlow.packets.isEmpty)
        }
        try scenario("malformed-ipv4-is-not-forwarded") {
            let p = NEPacketTunnelProvider(); let errors = Failures(); let b = try start(p, failure: errors)
            var data = packet(); data[3] = 63
            wait { p.packetFlow.readIsPending }; p.packetFlow.inject([data]); wait { !errors.values.isEmpty }; b.stop()
            precondition(errors.values == [.packetWrite] && p.packetFlow.packets.isEmpty)
        }
        try scenario("ne-write-failure-is-terminal") {
            let p = NEPacketTunnelProvider(); p.packetFlow.failWrites(); let errors = Failures(); let b = try start(p, failure: errors)
            wait { p.packetFlow.readIsPending }; p.packetFlow.inject([packet()]); wait { !errors.values.isEmpty }; b.stop()
            precondition(errors.values == [.packetWrite])
        }
        try scenario("duplicate-ne-callback-consumed-once") {
            let p = NEPacketTunnelProvider(); let b = try start(p)
            wait { p.packetFlow.readIsPending }; p.packetFlow.inject([packet()], duplicate: true); wait { p.packetFlow.packets.count == 1 && p.packetFlow.readIsPending }; b.stop()
            precondition(p.packetFlow.packets.count == 1)
        }
        try scenario("invalid-mtu-and-scope-blocked") {
            for mtu in [0, 575, 65536, 1400] {
                do { _ = try start(NEPacketTunnelProvider(), mtu: mtu); preconditionFailure() } catch { precondition(error is SplitterPacketFlowError) }
            }
            let c = try native().makeConfiguration(); c.peers.append(c.peers[0])
            do { _ = try start(NEPacketTunnelProvider(), configuration: c); preconditionFailure() }
            catch { precondition(error as? SplitterPacketFlowError == .invalidConfiguration) }
        }
        try scenario("resolution-failure-does-not-start") {
            let c = try native().makeConfiguration(); c.interface.listenPort = 65534
            do { _ = try start(NEPacketTunnelProvider(), configuration: c); preconditionFailure() }
            catch { precondition(error as? SplitterPacketFlowError == .invalidConfiguration) }
        }
        try scenario("concurrent-stop-joins-shutdown") {
            let p = NEPacketTunnelProvider(); let b = try start(p); wait { p.packetFlow.readIsPending }
            DispatchQueue.concurrentPerform(iterations: 8) { _ in b.stop() }
            let next = try start(NEPacketTunnelProvider()); next.stop()
        }
        try scenario("owner-deinit-closes-blocked-worker") {
            let p = NEPacketTunnelProvider(); var owner: SplitterPacketFlowBackend? = try start(p)
            wait { p.packetFlow.readIsPending }; precondition(owner != nil); owner = nil
            let next = try start(NEPacketTunnelProvider()); next.stop()
        }
        try scenario("bounded-batch-backpressure") {
            let p = NEPacketTunnelProvider(); let b = try start(p); wait { p.packetFlow.readIsPending }
            let packets = (0..<128).map { packet(UInt8($0)) }; p.packetFlow.inject(packets)
            wait { p.packetFlow.packets.count == 128 }; b.stop(); precondition(p.packetFlow.packets == packets)
        }
        precondition(scenarios == 19)
        print("packet-flow-harness=PASS scenarios=19 queue_tun_cabi=ACTUAL upstream_parser=ACTUAL framework_models_admission_engine=TEST_DOUBLES network=NOT_APPLIED")
    }
}
