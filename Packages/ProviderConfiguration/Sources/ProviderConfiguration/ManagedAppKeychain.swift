// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Security
import LocalAuthentication
import Darwin

extension ManagedCredentialVault {
    /// Does not read or write Keychain until prepare/load/revoke is explicitly called.
    /// The factory pins items to the containing App's OWN signed application identifier,
    /// never the new Mach-service App Group. No login/System Keychain fallback exists.
    public static func forContainingApp(expectedBundleIdentifier: String) throws -> ManagedCredentialVault {
        guard !expectedBundleIdentifier.isEmpty, expectedBundleIdentifier.utf8.count <= 200,
              Bundle.main.bundleIdentifier == expectedBundleIdentifier,
              Bundle.main.bundleURL.pathExtension == "app",
              getuid() > 0, geteuid() == getuid() else {
            throw ManagedCredentialError(reason: .invalidAppContext)
        }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let applicationID = entitlements["com.apple.application-identifier"] as? String,
              applicationID.hasSuffix("." + expectedBundleIdentifier), applicationID.utf8.count <= 240,
              applicationID != expectedBundleIdentifier else {
            throw ManagedCredentialError(reason: .invalidAppContext)
        }
        let backend = ManagedAppKeychain(service: expectedBundleIdentifier + ".managed-credentials.v1", accessGroup: applicationID)
        return try ManagedCredentialVault(backend: backend, ownerUID: getuid())
    }
}

/// APP USER CONTEXT ONLY. The access group is the signed containing App identifier,
/// not a group shared with the root system extension. No extension-side reader.
struct ManagedAppKeychain: ManagedCredentialBackend {
    let service: String
    let accessGroup: String

    // Query builders let macOS tests inspect Security keys WITHOUT real item access.
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
            result[kSecAttrAccessGroup as String] = accessGroup
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
              fields[kSecAttrAccessGroup as String] as? String == accessGroup,
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
