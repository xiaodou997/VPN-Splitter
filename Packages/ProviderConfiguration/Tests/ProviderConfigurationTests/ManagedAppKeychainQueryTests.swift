// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Security
import LocalAuthentication
import XCTest
@testable import ProviderConfiguration

/// Native API-key/query checks only. Never call SecItem* or create a real credential.
final class ManagedAppKeychainQueryTests: XCTestCase {
    private let backend = ManagedAppKeychain(service: "test.synthetic.managed-credentials.v1")
    private let reference = Data([7, 11, 13])
    func testAddIsDeviceLocalUnlockedAndNonInteractive() throws {
        let query = backend.addQuery(account: "SYNTHETIC", value: Data([1]))
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(query[kSecReturnPersistentRef as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrService as String] as? String, backend.service)
        XCTAssertTrue(try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext).interactionNotAllowed)
    }
    func testReadUsesExactReferenceAndDedicatedService() {
        let query = backend.readQuery(reference: reference)
        XCTAssertEqual(query[kSecValuePersistentRef as String] as? Data, reference)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, backend.service)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }
    func testDeleteQueryIncludesBothReceiptAndAccountWithoutReturnFlags() {
        let query = backend.query(reference: reference, account: "SYNTHETIC")
        XCTAssertEqual(Set(query.keys), Set([kSecUseDataProtectionKeychain as String, kSecUseAuthenticationContext as String,
            kSecClass as String, kSecAttrService as String, kSecAttrSynchronizable as String,
            kSecValuePersistentRef as String, kSecAttrAccount as String]))
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "SYNTHETIC")
        XCTAssertEqual(query[kSecValuePersistentRef as String] as? Data, reference)
    }
    func testAbsenceQueryDoesNotHideChangedAccountOrRequestSecretData() {
        let query = backend.existsQuery(reference: reference)
        XCTAssertEqual(Set(query.keys), Set([kSecUseDataProtectionKeychain as String, kSecUseAuthenticationContext as String,
            kSecValuePersistentRef as String, kSecMatchLimit as String, kSecReturnAttributes as String, kSecAttrSynchronizable as String]))
        XCTAssertEqual(query[kSecValuePersistentRef as String] as? Data, reference)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? String, kSecAttrSynchronizableAny as String)
    }
    func testEmptyAppIdentityRejectedWithoutKeychainOperation() {
        XCTAssertThrowsError(try ManagedCredentialVault.forContainingApp(expectedBundleIdentifier: "")) { error in
            XCTAssertEqual((error as? ManagedCredentialError)?.reason, .invalidAppContext)
        }
    }
}
#endif
