// SPDX-License-Identifier: MIT
// Metadata/material DTO TEST DOUBLES only; authentication is not tested here.
import Foundation
public struct ManagedStartRequest: Equatable, Sendable {
    let attemptID: UUID
    var propertyList: [String: String] { ["attempt": attemptID.uuidString] }
    init() { attemptID = UUID() }
    init(propertyList: [String: String]) throws {
        guard let raw = propertyList["attempt"], let id = UUID(uuidString: raw) else { throw ManagedTransferError.invalidMessage }
        attemptID = id
    }
}
struct Handle: Sendable { let ownerUID: UInt32 = 501; let persistentReference = Data([7, 8, 9]) }
struct ManagedDeliveryAuthorization: Sendable { let request = ManagedStartRequest(); let handle = Handle() }
struct CheckedManagedLaunch: Sendable { let request: ManagedStartRequest; let credentialReference: Data }
enum ManagedLaunchContract { static let maximumReferenceBytes = 4096 }
public struct ManagedCredentialMaterial: Sendable {
    let configuration: Data; let policyArchive: Data
    init(configuration: Data, policyArchive: Data) throws { self.configuration = configuration; self.policyArchive = policyArchive }
    func withContents<T>(_ body: (Data, Data) throws -> T) rethrows -> T { try body(configuration, policyArchive) }
}
enum ManagedTransferError: String, Error { case invalidMessage, invalidIdentity, replay, capacity, expired, busy, deliveryMissing, selectionChanged, connectionClosed, unavailable }
