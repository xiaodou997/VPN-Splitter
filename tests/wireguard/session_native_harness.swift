// SPDX-License-Identifier: MIT
// Executes actual ManagedWireGuardSession/controller against explicitly fake native APIs.
import Foundation

private final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var identity: ProviderSessionIdentity?
    init(_ identity: ProviderSessionIdentity) { self.identity = identity }
    func get() -> ProviderSessionIdentity? { lock.lock(); defer { lock.unlock() }; return identity }
    func clear() { lock.lock(); identity = nil; lock.unlock() }
}
@main
struct NativeSessionHarness {
    @MainActor static func settle() async { for _ in 0..<50 { await Task.yield() } }
    static func identity() -> ProviderSessionIdentity {
        .init(provider: UUID(), session: UUID(), profile: UUID(), credential: UUID(),
              ownershipNonce: UUID(), generation: 1, networkEpoch: 1)
    }
    @MainActor static func main() async throws {
        let id = identity(); let current = Current(id); let provider = NEPacketTunnelProvider()
        func make() throws -> ManagedWireGuardSession {
            ManagedWireGuardSession(provider: provider, identity: id, policy: .init(), underlay: .init(),
                dnsSelection: .keepSystem, currentIdentity: current.get,
                descriptor: { preconditionFailure("A fixture must never acquire a real descriptor") },
                timeouts: try .init(), event: { _ in })
        }
        func delivery(_ forID: ProviderSessionIdentity) -> WireGuardConfigurationDelivery {
            .init(verifiedFor: forID, configuration: TunnelConfiguration(name: "PRIVATE-TEST-NAME",
                interface: .init(marker: "PRIVATE-TEST-KEY"), peers: [.init(marker: "PRIVATE-TEST-PEER")]))
        }
        func failed(_ value: Result<Void, ProviderSessionFailure>?, _ expected: ProviderSessionFailure) -> Bool {
            if case .failure(let actual) = value { return actual == expected }; return false
        }
        // 1. Native start/stop call sites operate through the production controller.
        let first = try make(); var result: Result<Void, ProviderSessionFailure>?
        let source = TunnelConfiguration(name: "PRIVATE-TEST-NAME", interface: .init(marker: "PRIVATE-TEST-KEY"), peers: [])
        let oneUse = WireGuardConfigurationDelivery(verifiedFor: id, configuration: source)
        source.interface.marker = "MUTATED-AFTER-DELIVERY"
        first.start(credentials: { _, ready in ready(.success(oneUse)) }, completion: { result = $0 })
        await settle(); precondition(first.controller.phase == .running)
        let firstAssembly = ManagedWireGuardAssembly.made.last!
        precondition(firstAssembly.adapter.starts == 1 && firstAssembly.adapter.marker == "PRIVATE-TEST-KEY")
        first.controller.stop { result = $0 }; await settle()
        precondition(firstAssembly.adapter.stops == 1 && firstAssembly.binding.invalidated)
        precondition(first.controller.phase == .awaitingSystemTeardown)
        // 2. Consumed delivery cannot supply a second session, even with matching metadata.
        let second = try make()
        second.start(credentials: { _, cb in cb(.success(oneUse)) }, completion: { result = $0 })
        await settle(); precondition(failed(result, .configurationRejected))
        // 3. Wrong full identity is rejected before an adapter is made.
        let before = ManagedWireGuardAssembly.made.count; let wrong = try make()
        wrong.start(credentials: { _, cb in cb(.success(delivery(identity()))) }, completion: { result = $0 })
        await settle(); precondition(failed(result, .configurationRejected))
        precondition(ManagedWireGuardAssembly.made.count == before)
        // 4. Cancelled credential loading never prepares or starts a backend.
        let cancelled = try make()
        var finish: (@MainActor (Result<WireGuardConfigurationDelivery, ProviderSessionFailure>) -> Void)?
        cancelled.start(credentials: { _, cb in finish = cb }, completion: { result = $0 })
        cancelled.controller.stop { _ in }; finish?(.success(delivery(id))); await settle()
        precondition(ManagedWireGuardAssembly.made.count == before)
        // 5. Loader errors retain only the typed code.
        let denied = try make()
        denied.start(credentials: { _, cb in cb(.failure(.credentialUnavailable)) }, completion: { result = $0 })
        await settle(); precondition(failed(result, .credentialUnavailable))
        // 6. Plan/assembly errors are redacted, not converted into successful starts.
        ManagedWireGuardAssembly.failPreparation = true
        let rejected = try make()
        rejected.start(credentials: { _, cb in cb(.success(delivery(id))) }, completion: { result = $0 })
        await settle(); precondition(failed(result, .configurationRejected))
        ManagedWireGuardAssembly.failPreparation = false
        // 7. Duplicate source callback cannot create/close a second active adapter.
        let duplicate = try make(); let duplicateDelivery = delivery(id)
        duplicate.start(credentials: { _, cb in
            cb(.success(duplicateDelivery)); cb(.success(duplicateDelivery)); cb(.success(delivery(id)))
        }, completion: { result = $0 })
        await settle(); precondition(ManagedWireGuardAssembly.made.count == before + 1)
        let duplicateAssembly = ManagedWireGuardAssembly.made.last!
        precondition(duplicateAssembly.adapter.starts == 1)
        // 8. Stop errors remain unconfirmed; no fake clean-stop translation.
        duplicateAssembly.adapter.stopFails = true
        duplicate.controller.stop { result = $0 }; await settle()
        precondition(failed(result, .cleanupUnconfirmed))
        // 9. Cancel while native start is pending: start must settle before stop runs.
        ManagedWireGuardAssembly.deferStart = true
        let pending = try make()
        pending.start(credentials: { _, cb in cb(.success(delivery(id))) }, completion: { result = $0 })
        await settle(); let pendingAssembly = ManagedWireGuardAssembly.made.last!
        pending.controller.stop { _ in }
        precondition(pendingAssembly.adapter.stops == 0)
        pendingAssembly.adapter.startCompletion?(nil); await settle()
        precondition(pendingAssembly.adapter.stops == 1 && failed(result, .cancelled))
        // 10. The live closure is not a frozen revision; revoked identity becomes nil.
        current.clear(); precondition(firstAssembly.current() == nil)
        // 11. Descriptions, reflection and delivery discard do not expose secret fields.
        let discarded = delivery(id)
        precondition(!String(describing: discarded).contains("PRIVATE-TEST"))
        precondition(Mirror(reflecting: discarded).children.isEmpty)
        discarded.discard(); current.clear()
        print("session-integration-harness=PASS scenarios=11 native_apis=TEST_DOUBLES network_settings=NOT_APPLIED")
    }
}
