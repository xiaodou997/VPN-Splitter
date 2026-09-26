// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import AppCore
import PolicyCore
@testable import ProviderConfiguration
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ManagedWireGuardInputTests: XCTestCase {
    private let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
    private let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
    private let psk = Data(repeating: 3, count: 32).base64EncodedString()
    private func source(address: String = "10.250.0.2/32", endpoint: String = "198.51.100.9:51820",
                        allowed: String = "10.20.0.0/16", extra: String = "") -> Data {
        Data("""
        [Interface]
        PrivateKey = \(privateKey)
        Address = \(address)
        \(extra)
        [Peer]
        PublicKey = \(publicKey)
        PresharedKey = \(psk)
        Endpoint = \(endpoint)
        AllowedIPs = \(allowed)
        PersistentKeepalive = 25
        """.utf8)
    }
    private func prepare(_ config: Data? = nil, rules: String = "10.20.1.0/24") throws -> CheckedManagedWireGuardInput {
        try ManagedWireGuardInput.prepare(configuration: config ?? source(),
            policyArchive: ManagedWireGuardInput.encodeIncludePolicy(rules))
    }
    private func plist(_ changes: [String: Any] = [:], format: PropertyListSerialization.PropertyListFormat = .binary) throws -> Data {
        var fields: [String: Any] = ["schema": ManagedWireGuardInput.policySchema, "default": "DIRECT", "vpnCIDRs": ["10.20.1.0/24"]]
        fields.merge(changes) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: fields, format: format, options: 0)
    }
    private func reject(_ code: ManagedWireGuardInputError, file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ManagedWireGuardInputError, code, file: file, line: line)
        }
    }

    func testValidInputBuildsActualPolicyAndPreservesProtocolBytes() throws {
        let config = source(extra: "ListenPort = 0\nMTU = 1420")
        let archive = try ManagedWireGuardInput.encodeIncludePolicy("10.20.1.7/24\n10.20.1.128/25")
        let result = try ManagedWireGuardInput.prepare(configuration: config, policyArchive: archive)
        XCTAssertEqual(result.metadata.addresses[0].text, "10.250.0.2/32")
        XCTAssertEqual(result.metadata.peers[0].allowedIPs.map(\.text), ["10.20.0.0/16"])
        XCTAssertEqual(result.metadata.peers[0].persistentKeepalive, 25)
        XCTAssertTrue(result.metadata.peers[0].hadPresharedKey)
        XCTAssertEqual(result.metadata.listenPort, 0); XCTAssertEqual(result.metadata.mtu, 1420)
        XCTAssertEqual(result.policy.defaultAction, .direct); XCTAssertEqual(result.policy.rules.count, 2)
        XCTAssertEqual(result.vpnRouteCount, 1)
        result.withValidatedSource { data, policy in
            XCTAssertEqual(data, config); XCTAssertEqual(policy, archive)
        }
    }
    func testCompiledRulesRetainFirstMatchAndDirectDefault() throws {
        let checked = try prepare(rules: "10.20.1.0/24\n10.20.1.128/25")
        let context = PlanContext(sessionID: "test", backendID: "wireguard", generation: 1, networkEpoch: 1)
        let plan = try WireGuardPlanning.compile(checked.policy, metadata: checked.metadata, context: context)
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.20.1.140")).policyDecision.origin, .rule("managed-vpn-1"))
        XCTAssertEqual(plan.decision(for: try IPv4Address("8.8.8.8")).action, .direct)
        XCTAssertEqual(plan.decision(for: try IPv4Address("198.51.100.9")).action, .direct)
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.250.0.2")).action, .direct)
        XCTAssertTrue(plan.limitations.contains(.suppliedTopologyOnly))
    }
    func testProtocolAllowedIPsCanRemainGlobalWithoutGlobalSystemRouting() throws {
        let result = try prepare(source(allowed: "0.0.0.0/0"))
        XCTAssertEqual(result.metadata.peers[0].allowedIPs[0].text, "0.0.0.0/0")
        XCTAssertEqual(result.vpnRouteCount, 1)
    }
    func testCoverageByAdjacentAllowedIPPrefixesIsAccepted() throws {
        _ = try prepare(source(allowed: "10.20.1.0/25, 10.20.1.128/25"))
    }
    func testPartialAndCompletelyMissingProtocolCoverageAreRejected() {
        for range in ["10.20.1.0/25", "10.21.0.0/16"] {
            reject(.outsideAllowedIPs) { _ = try prepare(source(allowed: range)) }
        }
    }
    func testEndpointAndLocalAddressConflictsAreNotSilentlyCarvedOut() {
        reject(.infrastructureConflict) { _ = try prepare(source(allowed: "0.0.0.0/0"), rules: "198.51.100.0/24") }
        reject(.infrastructureConflict) { _ = try prepare(source(allowed: "0.0.0.0/0"), rules: "10.250.0.0/24") }
    }
    func testReservedTargetsAndDefaultRouteAreRejectedAsConflicts() {
        for rule in ["0.0.0.0/0", "127.0.0.1/32", "169.254.1.2/32", "224.0.0.1/32", "255.255.255.255/32", "0.0.0.1/32"] {
            reject(.infrastructureConflict) { _ = try prepare(source(allowed: "0.0.0.0/0"), rules: rule) }
        }
    }
    func testAllScriptHooksAreRejectedBeforeAnyResult() {
        for name in ["PreUp", "PostUp", "PreDown", "PostDown", "pOsTuP"] {
            reject(.script) { _ = try prepare(source(extra: "\(name) = SYNTHETIC-SECRET")) }
        }
    }
    func testUnknownFieldsAndOpenVPNTextAreRejected() {
        for name in ["Table", "SaveConfig", "FwMark", "FutureFeature"] {
            reject(.unsupportedDirective) { _ = try prepare(source(extra: "\(name) = SYNTHETIC-SECRET")) }
        }
        reject(.configuration) { _ = try prepare(Data("client\ndev tun\nremote example.invalid\n".utf8)) }
    }
    func testBadPrivatePublicAndPresharedKeysAreRejected() {
        let text = String(decoding: source(), as: UTF8.self)
        for value in [privateKey, publicKey, psk] {
            for bad in ["invalid", Data(repeating: 0, count: 32).base64EncodedString(), Data(repeating: 1, count: 31).base64EncodedString()] {
                reject(.key) { _ = try prepare(Data(text.replacingOccurrences(of: value, with: bad).utf8)) }
            }
        }
    }
    func testDuplicateAndMissingRequiredFieldsAreRejected() {
        reject(.configuration) { _ = try prepare(source(extra: "PrivateKey = \(privateKey)")) }
        let text = String(decoding: source(), as: UTF8.self)
        reject(.configuration) { _ = try prepare(Data(text.replacingOccurrences(of: "PrivateKey = \(privateKey)", with: "").utf8)) }
        reject(.configuration) { _ = try prepare(Data(text.replacingOccurrences(of: "PublicKey = \(publicKey)", with: "").utf8)) }
    }
    func testMultiplePeersAreNotDropped() {
        var config = source()
        config.append(Data("\n[Peer]\nPublicKey = \(Data(repeating: 4, count: 32).base64EncodedString())\nAllowedIPs = 10.21.0.0/16\nEndpoint = 203.0.113.1:51820\n".utf8))
        reject(.singlePeer) { _ = try prepare(config) }
    }
    func testIPv6InAnyNetworkFieldIsRejected() {
        let configs = [source(address: "10.250.0.2/32, fd00::2/128"), source(endpoint: "[2001:db8::1]:51820"),
                       source(allowed: "10.20.0.0/16, ::/0"), source(extra: "DNS = 2001:db8::53")]
        for config in configs { reject(.ipv6) { _ = try prepare(config) } }
    }
    func testDNSAddressesAndSearchDomainsRequireFutureExplicitPlan() {
        for value in ["10.20.0.53", "corp.example", "10.20.0.53, corp.example"] {
            reject(.dnsNotSupported) { _ = try prepare(source(extra: "DNS = \(value)")) }
        }
    }
    func testEndpointMustBePresentNumericAndUnicast() {
        for value in ["vpn.example:51820", "127.0.0.1:51820", "0.0.0.0:51820", "224.0.0.1:51820", "169.254.1.2:51820"] {
            reject(.endpoint) { _ = try prepare(source(endpoint: value)) }
        }
        let missing = String(decoding: source(), as: UTF8.self).replacingOccurrences(of: "Endpoint = 198.51.100.9:51820", with: "")
        reject(.endpoint) { _ = try prepare(Data(missing.utf8)) }
        reject(.configuration) { _ = try prepare(source(endpoint: "198.51.100.9:0")) }
    }
    func testInterfaceAddressIsNotNormalizedIntoNetworkOrSilentlyDeduplicated() throws {
        let value = try prepare(source(address: "10.250.0.2/24"))
        XCTAssertEqual(value.metadata.addresses[0].text, "10.250.0.2/24")
        for address in ["127.0.0.2/32", "0.0.0.0/32", "224.0.0.2/32", "10.250.0.2/0",
                        "10.250.0.2/32, 10.250.0.2/24", "198.51.100.9/32"] {
            reject(.interfaceAddress) { _ = try prepare(source(address: address)) }
        }
        let missing = String(decoding: source(), as: UTF8.self).replacingOccurrences(of: "Address = 10.250.0.2/32", with: "")
        reject(.interfaceAddress) { _ = try prepare(Data(missing.utf8)) }
    }
    func testEmptyAllowedIPsAreRejected() {
        reject(.allowedIPs) { _ = try prepare(source(allowed: "")) }
    }
    func testNumericOptionsRetainImporterLimits() {
        for extra in ["MTU = 575", "MTU = 65536", "ListenPort = -1", "ListenPort = 65536"] {
            reject(.configuration) { _ = try prepare(source(extra: extra)) }
        }
        let text = String(decoding: source(), as: UTF8.self).replacingOccurrences(of: "PersistentKeepalive = 25", with: "PersistentKeepalive = 65536")
        reject(.configuration) { _ = try prepare(Data(text.utf8)) }
    }
    func testBOMCRLFCaseAndCommentsUseExistingParser() throws {
        let text = "\u{feff}" + String(decoding: source(), as: UTF8.self)
            .replacingOccurrences(of: "[Interface]", with: "[iNtErFaCe]")
            .replacingOccurrences(of: "PrivateKey =", with: "privatekey\t=")
            .replacingOccurrences(of: "\n", with: "\r\n") + "\r\n# PostUp = comment only\r\n"
        let data = Data(text.utf8); let value = try prepare(data)
        value.withValidatedSource { actual, _ in XCTAssertEqual(actual, data) }
    }
    func testControlCharactersAndInvalidUTF8AreRejected() {
        reject(.configuration) { _ = try prepare(Data([0xff, 0xfe])) }
        var config = source(); config.append(0)
        reject(.configuration) { _ = try prepare(config) }
    }
    func testPolicyRejectsExtraKeysVersionsModesAndCoercions() throws {
        let changes: [[String: Any]] = [["schema": "future-v2"], ["default": "VPN"], ["default": "REJECT"],
            ["default": true], ["vpnCIDRs": [true]], ["vpnCIDRs": "10.20.1.0/24"], ["vpnCIDRs": []],
            ["PrivateKey": "SYNTHETIC-SECRET"], ["domain": "corp.example"], ["validated": true]]
        for change in changes {
            reject(.policy) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: plist(change)) }
        }
    }
    func testPolicyRejectsMissingFieldsXMLAndNoncanonicalCIDRs() throws {
        for missing in ["schema", "default", "vpnCIDRs"] {
            var fields: [String: Any] = ["schema": ManagedWireGuardInput.policySchema, "default": "DIRECT", "vpnCIDRs": ["10.20.1.0/24"]]
            fields.removeValue(forKey: missing)
            let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
            reject(.policy) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: data) }
        }
        reject(.policy) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: plist(format: .xml)) }
        for text in ["10.20.1.7/24", "10.20.1.0/024", "::/0", "10.20.1.1", "10.020.1.0/24"] {
            reject(.policy) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: plist(["vpnCIDRs": [text]])) }
        }
    }
    func testRuleOrderDuplicatesAndCanonicalizationArePreserved() throws {
        let result = try prepare(rules: " 10.20.1.7/24 \n\n10.20.1.0/24\n10.20.2.0/24")
        XCTAssertEqual(result.policy.rules.map(\.id), ["managed-vpn-1", "managed-vpn-2", "managed-vpn-3"])
        XCTAssertEqual(result.policy.rules[0].match, .ipv4(try IPv4CIDR("10.20.1.0/24")))
        XCTAssertEqual(result.policy.rules.count, 3)
    }
    func testEmptyOversizedAndTooManyRulesAreRejected() throws {
        for text in ["", " \n\t", String(repeating: "1", count: 65_537), Array(repeating: "10.20.1.0/24", count: 257).joined(separator: "\n")] {
            reject(.policyLimit) { _ = try ManagedWireGuardInput.encodeIncludePolicy(text) }
        }
        _ = try prepare(rules: Array(repeating: "10.20.1.0/24", count: 256).joined(separator: "\n"))
        reject(.policy) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: plist(["vpnCIDRs": Array(repeating: "10.20.1.0/24", count: 257)])) }
    }
    func testPayloadLimitsAndMalformedArchiveAreRejected() throws {
        let valid = try plist()
        for invalid in [Data(), Data(repeating: 32, count: 65_537)] {
            reject(.resourceLimit) { _ = try ManagedWireGuardInput.prepare(configuration: invalid, policyArchive: valid) }
            reject(.resourceLimit) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: invalid) }
        }
        reject(.policy) { _ = try ManagedWireGuardInput.prepare(configuration: source(), policyArchive: Data([1,2,3])) }
    }
    func testOriginalImporterLineAndPrefixLimitsStillApply() {
        reject(.resourceLimit) { _ = try prepare(source(extra: "#" + String(repeating: "x", count: 4096))) }
        var config = source(); config.append(Data(String(repeating: "\n", count: 4096).utf8))
        reject(.resourceLimit) { _ = try prepare(config) }
    }
    func testDescriptionsReflectionAndErrorsDoNotExposeSecrets() throws {
        let value = try prepare()
        for text in [String(describing: value), String(reflecting: value)] {
            for key in [privateKey, publicKey, psk, "10.250.0.2", "10.20.1.0"] { XCTAssertFalse(text.contains(key)) }
        }
        XCTAssertEqual(Mirror(reflecting: value).children.count, 0)
        do { _ = try prepare(source(extra: "PostUp = SYNTHETIC-SECRET")) }
        catch {
            XCTAssertFalse(String(describing: error).contains("SYNTHETIC-SECRET"))
            XCTAssertFalse((error as? ManagedWireGuardInputError)?.message.contains("SYNTHETIC-SECRET") ?? true)
        }
    }
    func testMutableFoundationInputsCannotChangeCheckedSnapshot() throws {
        let configuration = NSMutableData(data: source())
        let policy = NSMutableData(data: try plist())
        let expectedSource = Data(referencing: configuration), expectedPolicy = Data(referencing: policy)
        let checked = try ManagedWireGuardInput.prepare(configuration: expectedSource, policyArchive: expectedPolicy)
        let sourceCopy = source(), policyCopy = try plist()
        configuration.setData(Data([0])); policy.setData(Data([0]))
        checked.withValidatedSource { source, archive in
            XCTAssertEqual(source, sourceCopy); XCTAssertEqual(archive, policyCopy)
        }
    }
    func testSameMetadataDifferentKeysKeepsExactNewSource() throws {
        let first = try prepare()
        let alternate = Data(String(decoding: source(), as: UTF8.self).replacingOccurrences(of: privateKey, with: Data(repeating: 7, count: 32).base64EncodedString()).utf8)
        let second = try prepare(alternate)
        XCTAssertEqual(first.metadata, second.metadata)
        second.withValidatedSource { actual, _ in XCTAssertEqual(actual, alternate) }
    }
    func testRegularFileReaderDoesNotModifyOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.conf")
        let bytes = source(); try bytes.write(to: path)
        XCTAssertEqual(try ManagedWireGuardInput.readConfigurationFile(path), bytes)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
    }
    func testReaderRejectsSymlinkDirectoryFIFOAndOversize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("valid.conf"); try source().write(to: file)
        let link = directory.appendingPathComponent("link.conf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let subdir = directory.appendingPathComponent("dir.conf")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)
        let fifo = directory.appendingPathComponent("fifo.conf")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o600) }, 0)
        let large = directory.appendingPathComponent("large.conf"); try Data(repeating: 65, count: 65_537).write(to: large)
        let empty = directory.appendingPathComponent("empty.conf"); try Data().write(to: empty)
        for url in [link, subdir, fifo, large, empty, directory.appendingPathComponent("missing.conf"), URL(string: "https://example.invalid/test.conf")!] {
            reject(.file) { _ = try ManagedWireGuardInput.readConfigurationFile(url) }
        }
    }
}
