// SPDX-License-Identifier: MIT
// TEST DOUBLES ONLY. No Mach service, Security API, Keychain, NE or network I/O.
// The connection intentionally has NO Sendable conformance. Do not weaken it to
// make the listener's actor-crossing regression compile.
import Foundation

private protocol NSXPCListenerDelegate: AnyObject {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool
}
private final class NSXPCListener {
    weak var delegate: (any NSXPCListenerDelegate)?
    private(set) var requirement: String?
    init(machServiceName: String) {}
    func setConnectionCodeSigningRequirement(_ value: String) { requirement = value }
    func resume() { precondition(requirement != nil) }
}
private final class NSXPCInterface {
    init(with type: Any.Type) {}
}
private final class NSXPCConnection {
    var effectiveUserIdentifier: UInt32 = 501
    var exportedInterface: NSXPCInterface?
    var exportedObject: AnyObject?
    var invalidationHandler: (@Sendable () -> Void)?
    // Match the nonisolated callback boundary; this is not a MainActor closure.
    var interruptionHandler: (() -> Void)?
    private(set) var invalidations = 0
    func resume() {}
    func invalidate() {
        invalidations += 1
        // Synchronous callback deliberately tests that the registry lock is released.
        invalidationHandler?()
    }
}
private protocol ManagedCredentialXPC {}
private struct ManagedPeerRequirement: Sendable {
    func requirement(provider: Bool) -> String { "SYNTHETIC-PEER-REQUIREMENT" }
}
private struct ManagedNativeIdentity: Sendable {
    let service = "test.synthetic.credentials"
    let peers = ManagedPeerRequirement()
}
@MainActor
private final class ManagedDeliveryBroker {
    var active = Set<UUID>()
    var closed = Set<UUID>()
    var expiryChecks = Set<UUID>()
    func hasActiveConnection(_ id: UUID) -> Bool { expiryChecks.insert(id); return active.contains(id) }
    func close(_ id: UUID) { closed.insert(id); active.remove(id) }
}
private final class ManagedXPCExport: NSObject, ManagedCredentialXPC {
    let id: UUID
    let alive: ManagedXPCLiveness
    init(id: UUID, uid: UInt32, broker: ManagedDeliveryBroker, alive: ManagedXPCLiveness) {
        self.id = id; self.alive = alive
    }
}
