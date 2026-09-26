// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Security
import LocalAuthentication
import Darwin

extension ManagedCredentialVault {
    /// Does not read or write Keychain until prepare/load/revoke is explicitly called.
    /// Expected bundle ID is a role check, NOT caller authentication. Data-protection
    /// Keychain access is enforced by Security using the current process's entitlements.
    /// No access group or file-based/login/System Keychain fallback is added here.
    public static func forContainingApp(expectedBundleIdentifier: String) throws -> ManagedCredentialVault {
        guard !expectedBundleIdentifier.isEmpty, expectedBundleIdentifier.utf8.count <= 200,
              Bundle.main.bundleIdentifier == expectedBundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app",
              getuid() > 0, geteuid() == getuid() else {
            throw ManagedCredentialError(reason: .invalidAppContext)
        }
        let backend = ManagedAppKeychain(service: expectedBundleIdentifier + ".managed-credentials.v1")
        return try ManagedCredentialVault(backend: backend, ownerUID: getuid())
    }
}

/// APP USER CONTEXT ONLY. A root Packet Tunnel system extension is intentionally not
/// given this factory, a shared Keychain entitlement, or an alternate record reader.
struct ManagedAppKeychain: ManagedCredentialBackend {
    let service: String

    // Keep builders separate so macOS tests can inspect real Security keys without
    // invoking any Security operation, login prompt, real item, or network API.
    func query(reference: Data? = nil, account: String? = nil, scoped: Bool = true) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var result: [String: Any] = [
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        if scoped {
            result[kSecClass as String] = kSecClassGenericPassword
            result[kSecAttrService as String] = service
            result[kSecAttrSynchronizable as String] = false
        }
        if let reference { result[kSecValuePersistentRef as String] = reference }
        if let account { result[kSecAttrAccount as String] = account }
        return result
    }
    func addQuery(account: String, value: Data) -> [String: Any] {
        var result = query(account: account)
        result[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        result[kSecValueData as String] = value
        result[kSecReturnPersistentRef as String] = true
        return result
    }
    func readQuery(reference: Data) -> [String: Any] {
        var result = query(reference: reference)
        result[kSecMatchLimit as String] = kSecMatchLimitOne
        result[kSecReturnAttributes as String] = true
        result[kSecReturnData as String] = true
        return result
    }
    func existsQuery(reference: Data) -> [String: Any] {
        var result = query(reference: reference, scoped: false)
        result[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        result[kSecMatchLimit as String] = kSecMatchLimitOne
        result[kSecReturnAttributes as String] = true
        return result
    }
    func add(account: String, value: Data) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemAdd(addQuery(account: account, value: value) as CFDictionary, &result)
        try check(status)
        guard let reference = result as? Data, !reference.isEmpty,
              reference.count <= ManagedLaunchContract.maximumReferenceBytes else {
            throw ManagedCredentialBackendError.writeUnconfirmed
        }
        return Data(reference)
    }
    func read(reference: Data) throws -> ManagedCredentialStoredItem {
        var result: CFTypeRef?
        try check(SecItemCopyMatching(readQuery(reference: reference) as CFDictionary, &result))
        guard let fields = result as? [String: Any],
              fields[kSecAttrService as String] as? String == service,
              fields[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              let account = fields[kSecAttrAccount as String] as? String,
              let value = fields[kSecValueData as String] as? Data,
              value.count <= ManagedCredentialRecord.maximumBytes else {
            throw ManagedCredentialBackendError.invalidResult
        }
        return ManagedCredentialStoredItem(account: account, value: Data(value))
    }
    func delete(reference: Data, account: String) throws {
        let status = SecItemDelete(query(reference: reference, account: account) as CFDictionary)
        guard status != errSecItemNotFound else { return } // Vault still checks exact-ref absence.
        try check(status)
    }
    func exists(reference: Data) throws -> Bool {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(existsQuery(reference: reference) as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        try check(status)
        // A successful but malformed response cannot be treated as confirmed absence.
        guard result != nil else { throw ManagedCredentialBackendError.invalidResult }
        return true
    }
    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw ManagedCredentialBackendError.missing
        case errSecDuplicateItem: throw ManagedCredentialBackendError.duplicate
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecMissingEntitlement:
            throw ManagedCredentialBackendError.denied
        default: throw ManagedCredentialBackendError.unavailable
        }
    }
}
#endif
