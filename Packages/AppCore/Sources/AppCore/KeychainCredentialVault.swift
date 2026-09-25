// SPDX-License-Identifier: MIT
import Foundation
#if os(macOS)
import Security
#endif

/// LocalDev only: file-based macOS Keychain, no access-group sharing or iCloud sync.
/// Invoke on a worker, following an explicit user action; never on app launch.
public struct KeychainCredentialVault: CredentialVault {
    public static let service = "com.vpnsplitter.localdev.wireguard.v1"
    public init() {}

    public func create(_ material: WGCredentialMaterial, reference: CredentialReference) throws {
        #if os(macOS)
        let record = try KeychainRecord(reference: reference, material: material)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference.id.uuidString,
            kSecAttrLabel as String: "VPN-Splitter LocalDev WireGuard credential",
            kSecUseDataProtectionKeychain as String: false,
            kSecValueData as String: try record.encoded()
        ]
        try check(SecItemAdd(attributes as CFDictionary, nil))
        // Compare ALL fields (including key bytes), not only existence or a status code.
        guard try read(reference).record == record else { throw CredentialError.mismatch }
        #else
        throw CredentialError.unavailable
        #endif
    }

    public func verify(reference: CredentialReference, metadata: WGMetadata) throws {
        #if os(macOS)
        let item = try read(reference)
        try item.record.check(reference: reference, metadata: metadata)
        #else
        throw CredentialError.unavailable
        #endif
    }

    public func copyUpdatingParameters(from source: CredentialReference, to destination: CredentialReference,
                                       expected: WGMetadata, updated: WGMetadata) throws {
        guard source.profileID == destination.profileID, source.id != destination.id else { throw CredentialError.ownership }
        try WGParameterDraft.checkPreserved(expected, updated: updated)
        #if os(macOS)
        let record = try read(source).record
        try record.check(reference: source, metadata: expected)
        // create performs a full byte-for-byte envelope readback before returning.
        try create(record.updatingParameters(updated), reference: destination)
        #else
        throw CredentialError.unavailable
        #endif
    }

    public func removeOwned(reference: CredentialReference) throws {
        #if os(macOS)
        let item: Item
        do { item = try read(reference) }
        catch CredentialError.missing { return }
        // Read/ownership errors never trigger deletion or a broad fallback query.
        try item.record.check(reference: reference)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference.id.uuidString,
            kSecValuePersistentRef as String: item.persistentReference
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
        #else
        throw CredentialError.unavailable
        #endif
    }

    #if os(macOS)
    private struct Item {
        let record: KeychainRecord
        let persistentReference: Data
    }
    private func read(_ reference: CredentialReference) throws -> Item {
        // A fresh dictionary per operation. Service + random account, never enumerate.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference.id.uuidString,
            kSecUseDataProtectionKeychain as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let values = result as? [String: Any],
              let data = values[kSecValueData as String] as? Data,
              let persistent = values[kSecValuePersistentRef as String] as? Data, !persistent.isEmpty else {
            throw CredentialError.invalidRecord
        }
        let record = try KeychainRecord.decode(data)
        try record.check(reference: reference)
        return Item(record: record, persistentReference: persistent)
    }
    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled: throw CredentialError.cancelled
        case errSecAuthFailed, errSecInteractionNotAllowed: throw CredentialError.accessDenied
        case errSecDuplicateItem: throw CredentialError.duplicate
        case errSecItemNotFound: throw CredentialError.missing
        case errSecNotAvailable: throw CredentialError.unavailable
        default: throw CredentialError.operation
        }
    }
    #endif
}
