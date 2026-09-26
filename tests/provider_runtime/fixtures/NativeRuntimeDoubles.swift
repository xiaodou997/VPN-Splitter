// SPDX-License-Identifier: MIT
// TEST DOUBLES: no Apple SDK, routing, Keychain, XPC authentication or WireGuard engine.
import Foundation

final class Trace: @unchecked Sendable {
    static let shared = Trace()
    private let lock = NSLock()
    private var events: [String] = []
    private var apply: (@Sendable (Error?) -> Void)?
    private var clear: (@Sendable (Error?) -> Void)?
    func record(_ event: String) { lock.lock(); events.append(event); lock.unlock() }
    func read() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
    func reset() { lock.lock(); events = []; apply = nil; clear = nil; lock.unlock() }
    func settings(_ value: NEPacketTunnelNetworkSettings?, reply: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); if value == nil { clear = reply; events.append("clear") } else { apply = reply; events.append("apply") }; lock.unlock()
    }
    func complete(apply isApply: Bool, success: Bool = true) {
        lock.lock(); let call = isApply ? apply : clear; lock.unlock()
        call?(success ? nil : NSError(domain: "synthetic", code: 1))
    }
}
class NEPacketTunnelNetworkSettings {}
class NEPacketTunnelProvider: @unchecked Sendable {
    func setTunnelNetworkSettings(_ settings: NEPacketTunnelNetworkSettings?, completionHandler: @escaping @Sendable (Error?) -> Void) {
        Trace.shared.settings(settings, reply: completionHandler)
    }
    func cancelTunnelWithError(_ error: Error?) { Trace.shared.record("cancelNE") }
}
struct IPv4Policy {}
struct PlanContext { init(sessionID: String, backendID: String, generation: UInt64, networkEpoch: UInt64) {} }
struct IPv4ConstraintInput {}
struct WireGuardPlanSource {
    struct Peer { init(endpoint: String?, allowedIPs: [String]) {} }
    init(addresses: [String], dnsServers: [String], searchDomains: [String], mtu: Int?, peers: [Peer]) {}
}
struct ManagedSettingsDraft { let input = 0 }
enum WireGuardDNSSelection { case keepSystemExplicitly }
struct PreparedWireGuardPlan {
    let settings = ManagedSettingsDraft()
    static func prepare(source: WireGuardPlanSource, policy: IPv4Policy, context: PlanContext,
                        underlay: IPv4ConstraintInput, dnsSelection: WireGuardDNSSelection) throws -> Self { Self() }
}
enum PacketTunnelSettingsFactory {
    static func makeForInspection(_ value: ManagedSettingsDraft, current: Int) throws -> NEPacketTunnelNetworkSettings { .init() }
}
struct Range { let stringRepresentation = "10.0.0.2/32" }
struct Interface { let addresses = [Range()] }
struct Peer { let endpoint: Range? = Range(); let allowedIPs = [Range()] }
final class TunnelConfiguration { let interface = Interface(); let peers = [Peer()] }
struct InputMetadata: Sendable { var mtu: Int? }
struct CheckedManagedWireGuardInput: Sendable { var metadata = InputMetadata(mtu: nil) }
final class ManagedWireGuardNativeInput {
    let policy = IPv4Policy()
    init(_ input: CheckedManagedWireGuardInput) throws {}
    func makeConfiguration() -> TunnelConfiguration { .init() }
}
final class SplitterPacketFlowBackend: @unchecked Sendable {
    static func start(provider: NEPacketTunnelProvider, configuration: TunnelConfiguration, mtu: Int,
                      isCurrent: @escaping @Sendable () -> Bool,
                      failure: @escaping @Sendable (Int) -> Void) throws -> SplitterPacketFlowBackend {
        precondition(isCurrent()); Trace.shared.record("engineStart"); return .init()
    }
    func stop() { Trace.shared.record("engineStop") }
}
struct Profile: Sendable {
    let profileID = UUID(); let credentialID = UUID(); let policyRevision = UUID(); let generation: UInt64 = 1
}
struct Request: Sendable { let profile = Profile(); let attemptID = UUID() }
struct ManagedReceivedConfiguration: Sendable {
    let request = Request(); let purpose: ManagedDeliveryPurpose = .run
    let authorization: ManagedRunAuthorization?
}
@MainActor
final class ManagedExtensionRuntime {
    static let shared: ManagedExtensionRuntime? = .init()
    func finishRun(_ attempt: UUID) { Trace.shared.record("finishRun") }
}
struct ManagedUnderlaySnapshot: Sendable {
    func resolvedMTU(_ configured: Int?) throws -> Int {
        if let configured, configured < 576 { throw NSError(domain: "synthetic", code: 1) }
        return configured ?? 1280
    }
    func constraints(context: PlanContext) throws -> IPv4ConstraintInput { .init() }
}
@MainActor
final class ManagedUnderlayMonitor {
    static weak var latest: ManagedUnderlayMonitor?
    var changed: (() -> Void)?
    func start(initial: @escaping (Result<ManagedUnderlaySnapshot, Error>) -> Void, changed: @escaping () -> Void) {
        Self.latest = self; self.changed = changed; initial(.success(.init()))
    }
    func checkNow() throws {}
    func stop() { changed = nil }
}
