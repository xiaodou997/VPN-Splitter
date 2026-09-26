// SPDX-License-Identifier: MIT
import Foundation

final class Live: @unchecked Sendable {
    private let lock = NSLock(); private var live = true
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return live }
    func close() { lock.lock(); live = false; lock.unlock() }
}
@MainActor final class Time { var value = 0.0 }
@main struct DeliveryRuntimeHarness {
    @MainActor static func main() throws {
        let material = try ManagedCredentialMaterial(configuration: Data("synthetic".utf8), policyArchive: Data([1]))
        for scenario in 0..<10 {
            let time = Time(); let broker = ManagedDeliveryBroker(now: { time.value })
            let id = UUID(); let alive = Live(); let grant = ManagedDeliveryAuthorization()
            let challenge = try broker.open(connection: id, kernelUID: 501, isLive: { alive.read() })
            let purpose: ManagedDeliveryPurpose = scenario == 0 ? .check : .run
            let envelope = try ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material, purpose: purpose)
            let bytes = try envelope.encodedForAuthenticatedXPC()
            var fields = try ManagedWire.decode(bytes, maximum: ManagedDeliveryEnvelope.maximumBytes)
            if scenario == 8 || scenario == 9 {
                if scenario == 8 { fields["schema"] = "managed-delivery-v1" } else { fields["purpose"] = "anything" }
                let invalid = try ManagedWire.encode(fields, maximum: ManagedDeliveryEnvelope.maximumBytes)
                do { try broker.stage(invalid, connection: id); fatalError("invalid purpose accepted") }
                catch ManagedTransferError.invalidMessage {}
                continue
            }
            try broker.stage(bytes, connection: id)
            let launch = CheckedManagedLaunch(request: grant.request, credentialReference: grant.handle.persistentReference)
            if scenario == 7 {
                time.value = 16
                do { _ = try broker.consume(launch, ownerUID: 501); fatalError("late stage accepted") }
                catch ManagedTransferError.deliveryMissing {}
                continue
            }
            let received = try broker.consume(launch, ownerUID: 501)
            if scenario == 0 { precondition(received.purpose == .check && received.authorization == nil); continue }
            let auth = received.authorization!
            precondition(auth.isCurrent() && broker.hasActiveConnection(id))
            switch scenario {
            case 1: time.value = 100; broker.purge(); precondition(auth.isCurrent() && broker.hasActiveConnection(id))
            case 2: alive.close(); precondition(!auth.isCurrent()) // before broker callback/purge
            case 3: broker.close(id); precondition(!auth.isCurrent())
            case 4: broker.discard(); precondition(!auth.isCurrent())
            case 5:
                precondition(broker.endRun(UUID()) == nil && auth.isCurrent())
                precondition(broker.endRun(grant.request.attemptID) == id && !auth.isCurrent())
            case 6:
                let other = UUID(); let next = ManagedDeliveryAuthorization()
                let ch = try broker.open(connection: other, kernelUID: 501)
                let e = try ManagedDeliveryEnvelope(challenge: ch, grant: next, material: material, purpose: .run)
                do { try broker.stage(e.encodedForAuthenticatedXPC(), connection: other); fatalError("overlap accepted") }
                catch ManagedTransferError.busy {}
                precondition(auth.isCurrent())
            default: fatalError("bad test case")
            }
            precondition(!String(reflecting: auth).contains("synthetic"))
        }
        print("run-delivery=PASS scenarios=10 broker_permission=ACTUAL metadata_material=TEST_DOUBLES native_auth=NOT_TESTED")
    }
}
