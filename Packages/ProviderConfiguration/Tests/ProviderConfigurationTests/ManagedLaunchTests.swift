// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ProviderConfiguration

final class ManagedLaunchTests: XCTestCase {
    private let provider = "io.github.xiaodou997.VPNSplitter.PacketTunnel"
    private let reference = Data([7, 11, 13]) // Synthetic opaque reference, not a Keychain item.
    private func profile(_ generation: UInt64 = 1) throws -> ManagedProfileDescriptor {
        try ManagedProfileDescriptor(
            profileID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            credentialID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            policyRevision: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
            generation: generation)
    }
    private func check(saved: ManagedProfileDescriptor? = nil, requested: ManagedProfileDescriptor? = nil,
                       reference: Data? = Data([7, 11, 13])) throws -> CheckedManagedLaunch {
        let saved = try saved ?? profile()
        return try ManagedLaunchContract.check(
            providerBundleIdentifier: provider, expectedProviderBundleIdentifier: provider,
            providerConfiguration: ManagedLaunchContract.providerConfiguration(for: saved),
            passwordReference: reference,
            options: ManagedLaunchContract.startOptions(for: ManagedStartRequest(profile: requested ?? saved)))
    }
    private func reject(_ expected: ManagedLaunchError, _ body: () throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? ManagedLaunchError, expected, file: file, line: line)
        }
    }

    func testProfileRoundTrip() throws {
        let value = try profile()
        XCTAssertEqual(try ManagedProfileDescriptor(propertyList: value.propertyList), value)
    }
    func testStartRequestRoundTrip() throws {
        let request = ManagedStartRequest(profile: try profile())
        XCTAssertEqual(try ManagedStartRequest(propertyList: request.propertyList), request)
    }
    func testValidFoundationBoundaryPreservesSnapshot() throws {
        let checked = try check()
        XCTAssertEqual(checked.request.profile, try profile())
        XCTAssertEqual(checked.credentialReference, reference)
    }
    func testPositiveGenerationOnly() {
        reject(.invalidMetadata) { _ = try profile(0) }
    }
    func testFullUInt64IsLosslessString() throws {
        let value = try profile(.max)
        XCTAssertEqual(value.propertyList["generation"], "18446744073709551615")
        XCTAssertEqual(try ManagedProfileDescriptor(propertyList: value.propertyList), value)
    }
    func testNonCanonicalAndOverflowGenerationsRejected() throws {
        for invalid in ["", "0", "01", "+1", "-1", "1.0", "1e0", " 1", "1\n",
                        "18446744073709551616", String(repeating: "9", count: 10000)] {
            var data = try profile().propertyList
            data["generation"] = invalid
            reject(.invalidMetadata) { _ = try ManagedProfileDescriptor(propertyList: data) }
        }
    }
    func testEveryRequiredProfileFieldIsRequired() throws {
        let original = try profile().propertyList
        for field in original.keys {
            var data = original
            data.removeValue(forKey: field)
            reject(.invalidMetadata) { _ = try ManagedProfileDescriptor(propertyList: data) }
        }
    }
    func testSecretAndUnknownFieldsRejected() throws {
        for field in ["PrivateKey", "rawConfiguration", "password", "futureFeature"] {
            var data = try profile().propertyList
            data[field] = "SYNTHETIC-DO-NOT-LOG"
            reject(.invalidMetadata) { _ = try ManagedProfileDescriptor(propertyList: data) }
        }
    }
    func testUnknownVersionAndUnsupportedScopeRejected() throws {
        for (field, value) in [("version", "2"), ("version", "01"), ("scope", "openvpn"),
                               ("scope", "wireguard-ipv6"), ("scope", "wireguard-bypass")] {
            var data = try profile().propertyList
            data[field] = value
            reject(.invalidMetadata) { _ = try ManagedProfileDescriptor(propertyList: data) }
        }
    }
    func testIDsHaveOneCanonicalWireForm() throws {
        for field in ["profile", "credential", "policyRevision"] {
            for invalid in ["", "bad", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                            "{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}", String(repeating: "A", count: 10000)] {
                var data = try profile().propertyList
                data[field] = invalid
                reject(.invalidMetadata) { _ = try ManagedProfileDescriptor(propertyList: data) }
            }
        }
    }
    func testRequestRequiresAttempt() throws {
        reject(.invalidMetadata) { _ = try ManagedStartRequest(propertyList: profile().propertyList) }
    }
    func testRequestRejectsMalformedAttemptAndExtras() throws {
        var request = ManagedStartRequest(profile: try profile()).propertyList
        request["attempt"] = "bogus"
        reject(.invalidMetadata) { _ = try ManagedStartRequest(propertyList: request) }
        request["attempt"] = UUID().uuidString
        request["rawConfig"] = "SYNTHETIC-DO-NOT-LOG"
        reject(.invalidMetadata) { _ = try ManagedStartRequest(propertyList: request) }
    }
    func testEveryIdentityComponentMustMatchSavedProfile() throws {
        let value = try profile()
        let mismatches = [
            try ManagedProfileDescriptor(profileID: UUID(), credentialID: value.credentialID,
                policyRevision: value.policyRevision, generation: value.generation),
            try ManagedProfileDescriptor(profileID: value.profileID, credentialID: UUID(),
                policyRevision: value.policyRevision, generation: value.generation),
            try ManagedProfileDescriptor(profileID: value.profileID, credentialID: value.credentialID,
                policyRevision: UUID(), generation: value.generation), try profile(2)
        ]
        for mismatch in mismatches {
            reject(.staleProfile) { _ = try check(saved: value, requested: mismatch) }
        }
    }
    func testReferenceRequiredAndBounded() throws {
        for data in [nil, Data(), Data(repeating: 0, count: 4097)] {
            reject(.missingCredentialReference) { _ = try check(reference: data) }
        }
        XCTAssertEqual(try check(reference: Data(repeating: 0, count: 4096)).credentialReference.count, 4096)
    }
    func testAppChecksExpectedReference() throws {
        let checked = try check()
        try ManagedLaunchContract.checkExpectedReference(reference, launch: checked)
        for invalid in [Data(), Data([7, 11, 17])] {
            reject(.credentialReferenceChanged) {
                try ManagedLaunchContract.checkExpectedReference(invalid, launch: checked)
            }
        }
    }
    func testWrongMissingAndEmptyProviderRejected() throws {
        for actual in [nil, "other.provider", ""] {
            reject(.wrongProvider) {
                _ = try ManagedLaunchContract.check(providerBundleIdentifier: actual,
                    expectedProviderBundleIdentifier: provider, providerConfiguration: nil,
                    passwordReference: nil, options: nil)
            }
        }
        reject(.wrongProvider) {
            _ = try ManagedLaunchContract.check(providerBundleIdentifier: "",
                expectedProviderBundleIdentifier: "", providerConfiguration: nil,
                passwordReference: nil, options: nil)
        }
    }
    func testNilAndEmptyContainersRejected() throws {
        let configuration = ManagedLaunchContract.providerConfiguration(for: try profile())
        let options = ManagedLaunchContract.startOptions(for: ManagedStartRequest(profile: try profile()))
        for invalid in [nil, [:]] as [[String: Any]?] {
            reject(.invalidContainer) {
                _ = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                    expectedProviderBundleIdentifier: provider, providerConfiguration: invalid,
                    passwordReference: reference, options: options)
            }
        }
        for invalid in [nil, [:]] as [[String: NSObject]?] {
            reject(.invalidContainer) {
                _ = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                    expectedProviderBundleIdentifier: provider, providerConfiguration: configuration,
                    passwordReference: reference, options: invalid)
            }
        }
    }
    func testUnrecognizedOuterKeysAndSmokeMixingRejected() throws {
        var configuration = ManagedLaunchContract.providerConfiguration(for: try profile())
        let valid = ManagedLaunchContract.startOptions(for: ManagedStartRequest(profile: try profile()))
        configuration["rawConfig"] = "SYNTHETIC-DO-NOT-LOG"
        reject(.invalidContainer) {
            _ = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                expectedProviderBundleIdentifier: provider, providerConfiguration: configuration,
                passwordReference: reference, options: valid)
        }
        configuration = ManagedLaunchContract.providerConfiguration(for: try profile())
        var mixed = valid
        mixed["S1SmokeTest"] = NSNumber(value: true)
        reject(.invalidContainer) {
            _ = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                expectedProviderBundleIdentifier: provider, providerConfiguration: configuration,
                passwordReference: reference, options: mixed)
        }
    }
    func testFoundationDoesNotCoerceNumericGeneration() throws {
        let configuration = ManagedLaunchContract.providerConfiguration(for: try profile())
        for value: Any in [NSNumber(value: 1), NSNumber(value: true), NSNumber(value: 1.0), Data([1])] {
            var fields: [String: Any] = ManagedStartRequest(profile: try profile()).propertyList
            fields["generation"] = value
            reject(.invalidContainer) {
                _ = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                    expectedProviderBundleIdentifier: provider, providerConfiguration: configuration,
                    passwordReference: reference,
                    options: [ManagedLaunchContract.startKey: fields as NSDictionary])
            }
        }
    }
    func testUnexpectedContainerTypesRejected() throws {
        for invalid in [NSString(string: "config"), NSData(data: reference), NSArray(), NSNumber(value: true)] {
            reject(.invalidContainer) {
                _ = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                    expectedProviderBundleIdentifier: provider,
                    providerConfiguration: ManagedLaunchContract.providerConfiguration(for: profile()),
                    passwordReference: reference, options: [ManagedLaunchContract.startKey: invalid])
            }
        }
    }
    func testPropertyListRoundTripUsesRealFoundationSerialization() throws {
        let saved = try profile()
        let request = ManagedStartRequest(profile: saved)
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: ManagedLaunchContract.providerConfiguration(for: saved), format: .binary, options: 0)
        let decoded = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        let optionsData = try PropertyListSerialization.data(
            fromPropertyList: ManagedLaunchContract.startOptions(for: request), format: .binary, options: 0)
        let options = try XCTUnwrap(PropertyListSerialization.propertyList(from: optionsData, format: nil) as? [String: NSObject])
        let checked = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
            expectedProviderBundleIdentifier: provider, providerConfiguration: decoded,
            passwordReference: reference, options: options)
        XCTAssertEqual(checked.request, request)
    }
    func testMutableFoundationInputDoesNotMutateCheckedSnapshot() throws {
        let request = ManagedStartRequest(profile: try profile())
        let dictionary = NSMutableDictionary(dictionary: request.propertyList)
        let checked = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
            expectedProviderBundleIdentifier: provider,
            providerConfiguration: ManagedLaunchContract.providerConfiguration(for: profile()),
            passwordReference: reference, options: [ManagedLaunchContract.startKey: dictionary])
        dictionary["profile"] = UUID().uuidString
        XCTAssertEqual(checked.request, request)
    }
    func testDebugAndReflectionRedactReference() throws {
        let checked = try check(reference: Data("SYNTHETIC-REFERENCE-SENTINEL".utf8))
        XCTAssertFalse(String(describing: checked).contains("SENTINEL"))
        XCTAssertFalse(String(reflecting: checked).contains("SENTINEL"))
        XCTAssertEqual(Mirror(reflecting: checked).children.count, 0)
    }
    func testMetadataCheckMakesNoReplayClaim() throws {
        // Repeated equality checks are valid; runtime replay/revocation enforcement
        // belongs to the still-missing authorized credential/session source.
        let request = ManagedStartRequest(profile: try profile())
        for _ in 0..<2 {
            let result = try ManagedLaunchContract.check(providerBundleIdentifier: provider,
                expectedProviderBundleIdentifier: provider,
                providerConfiguration: ManagedLaunchContract.providerConfiguration(for: request.profile),
                passwordReference: reference, options: ManagedLaunchContract.startOptions(for: request))
            XCTAssertEqual(result.request.attemptID, request.attemptID)
        }
    }
}
