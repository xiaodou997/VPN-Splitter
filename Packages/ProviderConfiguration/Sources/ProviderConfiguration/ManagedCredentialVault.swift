// SPDX-License-Identifier: MIT
import Foundation

/// Bounded secret material for the containing App's private Keychain only.
/// This is NOT a validated WireGuard configuration, a compiled policy, or an IPC format.
/// The existing parsers/compiler must still validate both archives before execution.
public struct ManagedCredentialMaterial: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public static let maximumConfigurationBytes = 65_536
    public static let maximumPolicyBytes = 65_536
    private let configuration: Data
    private let policyArchive: Data

    public init(configuration: Data, policyArchive: Data) throws {
        guard !configuration.isEmpty, configuration.count <= Self.maximumConfigurationBytes,
              String(data: configuration, encoding: .utf8) != nil,
              !policyArchive.isEmpty, policyArchive.count <= Self.maximumPolicyBytes else {
            throw ManagedCredentialError(reason: .invalidMaterial)
        }
        self.configuration = configuration.withUnsafeBytes { Data($0) }
        self.policyArchive = policyArchive.withUnsafeBytes { Data($0) }
    }

    /// The caller can retain copies. Neither scoped access nor deinit promises zeroization.
    public func withContents<T>(_ body: (Data, Data) throws -> T) rethrows -> T {
        try body(configuration, policyArchive)
    }
    public var description: String { "ManagedCredentialMaterial(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Persistable *reference* metadata, not a permission grant. Restore it only from the
/// App's selected record. Loading an old handle does not prove it is the current profile.
public struct ManagedCredentialHandle: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let profile: ManagedProfileDescriptor
    public let ownerUID: UInt32
    public let persistentReference: Data

    public init(profile: ManagedProfileDescriptor, ownerUID: UInt32, persistentReference: Data) throws {
        guard ownerUID > 0, !persistentReference.isEmpty,
              persistentReference.count <= ManagedLaunchContract.maximumReferenceBytes else {
            throw ManagedCredentialError(reason: .invalidHandle)
        }
        self.profile = profile; self.ownerUID = ownerUID
        self.persistentReference = persistentReference.withUnsafeBytes { Data($0) }
    }
    var account: String { Self.account(profile: profile, ownerUID: ownerUID) }
    static func account(profile: ManagedProfileDescriptor, ownerUID: UInt32) -> String {
        "v1:\(ownerUID):\(profile.profileID.uuidString):\(profile.credentialID.uuidString):\(profile.policyRevision.uuidString):\(profile.generation)"
    }
    public var description: String { "ManagedCredentialHandle(<redacted>; app-local-reference)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// An in-memory receipt issued after a successful add, or after revoke verified the
/// existing record. It permits exact-item cleanup even if read-back found a corrupt
/// newly added payload. Not Codable; durable
/// crash/orphan reconciliation is a separate, still-required App transaction feature.
public struct ManagedCredentialCleanupTicket: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    fileprivate let handle: ManagedCredentialHandle
    fileprivate init(_ handle: ManagedCredentialHandle) { self.handle = handle }
    public var description: String { "ManagedCredentialCleanupTicket(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public struct ManagedCredentialError: Error, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public enum Reason: String, Sendable {
        case invalidMaterial, invalidHandle, wrongOwner, invalidRecord, notFound
        case denied, duplicate, unavailable, writeUnconfirmed, verificationFailed, cancelled
        case cleanupUnconfirmed, invalidAppContext
    }
    public enum Cleanup: String, Sendable { case notNeeded, confirmedAbsent, unconfirmed }
    public let reason: Reason
    public let cleanup: Cleanup
    public let cleanupTicket: ManagedCredentialCleanupTicket?
    init(reason: Reason, cleanup: Cleanup = .notNeeded, ticket: ManagedCredentialCleanupTicket? = nil) {
        self.reason = reason; self.cleanup = cleanup; cleanupTicket = ticket
    }
    public var description: String { "ManagedCredentialError(\(reason.rawValue); cleanup=\(cleanup.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Internal injection boundary, not a public alternate/fallback credential source.
// Implementations must scope add/read/delete to their one dedicated service; delete
// additionally matches the exact reference AND account. exists checks the reference
// without an account/service filter, so a changed item cannot masquerade as erased.
enum ManagedCredentialBackendError: Error { case missing, denied, duplicate, unavailable, invalidResult, writeUnconfirmed }
struct ManagedCredentialStoredItem { let account: String; let value: Data }
protocol ManagedCredentialBackend: Sendable {
    func add(account: String, value: Data) throws -> Data
    func read(reference: Data) throws -> ManagedCredentialStoredItem
    func delete(reference: Data, account: String) throws
    func exists(reference: Data) throws -> Bool
}

struct ManagedCredentialRecord: Equatable {
    static let maximumBytes = 140_000
    let profile: ManagedProfileDescriptor
    let ownerUID: UInt32
    let material: ManagedCredentialMaterial

    func encodeForKeychain() throws -> Data {
        let data = try material.withContents { configuration, policy in
            try PropertyListSerialization.data(fromPropertyList: [
                "schema": "managed-app-credential-v1", "owner": String(ownerUID),
                "profile": profile.propertyList, "configuration": configuration, "policy": policy
            ], format: .binary, options: 0)
        }
        guard data.count <= Self.maximumBytes else { throw ManagedCredentialError(reason: .invalidMaterial) }
        return data
    }
    init(profile: ManagedProfileDescriptor, ownerUID: UInt32, material: ManagedCredentialMaterial) {
        self.profile = profile; self.ownerUID = ownerUID; self.material = material
    }
    init(keychainData: Data) throws {
        do {
            guard !keychainData.isEmpty, keychainData.count <= Self.maximumBytes,
                  let fields = try PropertyListSerialization.propertyList(from: keychainData, options: [], format: nil) as? [String: Any],
                  Set(fields.keys) == ["schema", "owner", "profile", "configuration", "policy"],
                  fields["schema"] as? String == "managed-app-credential-v1",
                  let owner = fields["owner"] as? String, owner.utf8.count <= 10,
                  let uid = UInt32(owner), uid > 0, String(uid) == owner,
                  let profile = fields["profile"] as? [String: String],
                  let configuration = fields["configuration"] as? Data,
                  let policy = fields["policy"] as? Data else {
                throw ManagedCredentialError(reason: .invalidRecord)
            }
            self.init(profile: try ManagedProfileDescriptor(propertyList: profile), ownerUID: uid,
                      material: try ManagedCredentialMaterial(configuration: configuration, policyArchive: policy))
        } catch { throw ManagedCredentialError(reason: .invalidRecord) }
    }
}

/// App-local immutable records. Native Keychain work runs on this actor, not MainActor.
/// There is no replace/update, broad search, automatic retry, or delete-old operation.
/// Preparing a record does not publish a VPN profile and does not authorize a Provider.
public actor ManagedCredentialVault: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated public var description: String { "ManagedCredentialVault(<redacted>; app-local-only)" }
    nonisolated public var debugDescription: String { description }
    nonisolated public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
    private let backend: any ManagedCredentialBackend
    private let ownerUID: UInt32
    init(backend: any ManagedCredentialBackend, ownerUID: UInt32) throws {
        guard ownerUID > 0 else { throw ManagedCredentialError(reason: .invalidAppContext) }
        self.backend = backend; self.ownerUID = ownerUID
    }

    public func prepare(profile: ManagedProfileDescriptor, material: ManagedCredentialMaterial) throws -> ManagedCredentialHandle {
        try checkCancellation()
        let record = ManagedCredentialRecord(profile: profile, ownerUID: ownerUID, material: material)
        let bytes: Data
        do { bytes = try record.encodeForKeychain() }
        catch { throw ManagedCredentialError(reason: .invalidMaterial) }
        let account = ManagedCredentialHandle.account(profile: profile, ownerUID: ownerUID)
        let reference: Data
        do { reference = try backend.add(account: account, value: bytes) }
        catch { throw mapped(error) }
        // Without a usable receipt an indeterminate write cannot be safely swept away.
        guard let handle = try? ManagedCredentialHandle(profile: profile, ownerUID: ownerUID, persistentReference: reference) else {
            throw ManagedCredentialError(reason: .writeUnconfirmed, cleanup: .unconfirmed)
        }
        do {
            try checkCancellation()
            guard try readRecord(handle) == record else { throw ManagedCredentialError(reason: .verificationFailed) }
            try checkCancellation()
            return handle
        } catch {
            let failure = mapped(error)
            let ticket = ManagedCredentialCleanupTicket(handle)
            do { try removeReceipt(handle) }
            catch {
                throw ManagedCredentialError(reason: failure.reason, cleanup: .unconfirmed, ticket: ticket)
            }
            throw ManagedCredentialError(reason: failure.reason, cleanup: .confirmedAbsent)
        }
    }

    /// Checks the full selected binding and Keychain account. It does not assert that
    /// an arbitrary caller-supplied binding is the latest committed App selection.
    public func load(_ handle: ManagedCredentialHandle) throws -> ManagedCredentialMaterial {
        try checkCancellation()
        do {
            let value = try readRecord(handle).material
            try checkCancellation()
            return value
        } catch { throw mapped(error) }
    }

    /// App-side bridge from WG-INT-08A metadata to an actual Keychain read. The reference
    /// remains local to the App; never assume the system extension can resolve it.
    public func load(for launch: CheckedManagedLaunch, selected handle: ManagedCredentialHandle) throws -> ManagedCredentialMaterial {
        guard launch.request.profile == handle.profile,
              launch.credentialReference == handle.persistentReference else {
            throw ManagedCredentialError(reason: .invalidHandle)
        }
        return try load(handle)
    }

    public func revoke(_ handle: ManagedCredentialHandle) throws {
        try checkOwner(handle)
        // Revocation is explicit cleanup: honor it even when the surrounding task was
        // cancelled. Never report absence on a denied, corrupt or wrong-owner read.
        do { _ = try readRecord(handle) }
        catch ManagedCredentialBackendError.missing {
            do {
                guard try !backend.exists(reference: handle.persistentReference) else {
                    throw ManagedCredentialError(reason: .cleanupUnconfirmed, cleanup: .unconfirmed)
                }
                return
            } catch { throw ManagedCredentialError(reason: .cleanupUnconfirmed, cleanup: .unconfirmed) }
        } catch { throw mapped(error) }
        do { try removeReceipt(handle) }
        catch { throw ManagedCredentialError(reason: .cleanupUnconfirmed, cleanup: .unconfirmed,
                                              ticket: ManagedCredentialCleanupTicket(handle)) }
    }

    public func retryCleanup(_ ticket: ManagedCredentialCleanupTicket) throws {
        try checkOwner(ticket.handle)
        do { try removeReceipt(ticket.handle) }
        catch { throw ManagedCredentialError(reason: .cleanupUnconfirmed, cleanup: .unconfirmed, ticket: ticket) }
    }

    private func readRecord(_ handle: ManagedCredentialHandle) throws -> ManagedCredentialRecord {
        try checkOwner(handle)
        let item = try backend.read(reference: handle.persistentReference)
        guard item.account == handle.account else { throw ManagedCredentialError(reason: .wrongOwner) }
        let record = try ManagedCredentialRecord(keychainData: item.value)
        guard record.ownerUID == handle.ownerUID, record.profile == handle.profile else {
            throw ManagedCredentialError(reason: .invalidRecord)
        }
        return record
    }
    private func removeReceipt(_ handle: ManagedCredentialHandle) throws {
        try checkOwner(handle)
        do { try backend.delete(reference: handle.persistentReference, account: handle.account) }
        catch ManagedCredentialBackendError.missing { /* Absence still needs a separate read. */ }
        guard try !backend.exists(reference: handle.persistentReference) else {
            throw ManagedCredentialError(reason: .cleanupUnconfirmed, cleanup: .unconfirmed)
        }
    }
    private func checkOwner(_ handle: ManagedCredentialHandle) throws {
        guard handle.ownerUID == ownerUID else { throw ManagedCredentialError(reason: .wrongOwner) }
    }
    private func checkCancellation() throws {
        guard !Task.isCancelled else { throw ManagedCredentialError(reason: .cancelled) }
    }
    private func mapped(_ error: Error) -> ManagedCredentialError {
        if let known = error as? ManagedCredentialError { return known }
        let reason: ManagedCredentialError.Reason
        switch error as? ManagedCredentialBackendError {
        case .missing: reason = .notFound
        case .denied: reason = .denied
        case .duplicate: reason = .duplicate
        case .invalidResult: reason = .invalidRecord
        case .writeUnconfirmed: return ManagedCredentialError(reason: .writeUnconfirmed, cleanup: .unconfirmed)
        default: reason = .unavailable
        }
        return ManagedCredentialError(reason: reason)
    }
}
