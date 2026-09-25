// SPDX-License-Identifier: MIT
import Foundation
import Testing
import PolicyCore
@testable import AppCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let privateKey = Data(repeating: 17, count: 32).base64EncodedString()
private let publicKey = Data(repeating: 34, count: 32).base64EncodedString()
private let psk = Data(repeating: 51, count: 32).base64EncodedString()

private func config(_ extra: String = "") -> String {
    """
    [Interface]
    PrivateKey = \(privateKey)
    Address = 10.255.0.2/32
    DNS = 10.9.0.53
    ListenPort = 0
    MTU = 1420
    [Peer]
    PublicKey = \(publicKey)
    PresharedKey = \(psk)
    Endpoint = 192.0.2.10:51820
    AllowedIPs = 10.9.0.0/16
    PersistentKeepalive = 25
    \(extra)
    """
}
private func parse(_ text: String) throws -> WGMetadata { try WireGuardImport.parse(Data(text.utf8)) }
private func imported(_ metadata: WGMetadata? = nil, rules: [DraftRule] = []) throws -> ProfileDraft {
    var profile = ProfileDraft(rules: rules); profile.wireGuard = try metadata ?? parse(config()); return profile
}
private func expectImportError(_ text: String, _ code: WGImportError.Code, field: WGField? = nil) {
    do { _ = try parse(text); Issue.record("Expected an import error") }
    catch let error as WGImportError {
        #expect(error.code == code)
        if let field { #expect(error.field == field) }
        #expect(!error.message.contains(privateKey)); #expect(!error.message.contains(psk))
    } catch { Issue.record("Unexpected error type") }
}
private func temp(_ body: (URL) throws -> Void) throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("wg-import-tests-\(UUID())")
    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: path) }
    try body(path)
}

@Test func wgParsesIPv4MetadataWithoutCredentials() throws {
    let metadata = try parse(config())
    #expect(metadata.addresses.map(\.text) == ["10.255.0.2/32"])
    #expect(metadata.dnsServers == ["10.9.0.53"])
    #expect(metadata.listenPort == 0); #expect(metadata.mtu == 1420)
    #expect(metadata.peers[0].endpoint?.display == "192.0.2.10:51820")
    #expect(metadata.peers[0].persistentKeepalive == 25)
    #expect(metadata.peers[0].hadPresharedKey)
    #expect(metadata.compatibilityIssues.isEmpty)
    let data = try JSONEncoder().encode(metadata)
    let json = String(decoding: data, as: UTF8.self)
    for value in [privateKey, publicKey, psk, "[Interface]", "[Peer]"] { #expect(!json.contains(value)) }
    #expect(!metadata.summary.contains(privateKey))
    #expect(!String(reflecting: metadata).contains(psk))
    #expect(try JSONDecoder().decode(WGMetadata.self, from: data) == metadata)
}

@Test func wgKeepsHostBitsAndProtocolRangesSeparate() throws {
    let metadata = try parse(config().replacingOccurrences(of: "10.255.0.2/32", with: "10.255.0.2/24")
        .replacingOccurrences(of: "10.9.0.0/16", with: "10.9.3.7/16"))
    #expect(metadata.addresses[0].text == "10.255.0.2/24")
    #expect(metadata.addresses[0].address == "10.255.0.2")
    #expect(metadata.peers[0].allowedIPs[0].text == "10.9.3.7/16")
    #expect(metadata.peers[0].allowedIPs[0].ipv4CIDR?.description == "10.9.0.0/16")
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let before = try encoder.encode(metadata)
    _ = try PolicyPreview.compile(imported(metadata, rules: [DraftRule(value: "10.9.4.5")]))
    #expect(try encoder.encode(metadata) == before)
}

@Test func wgAcceptsBOMCRLFCommentsAndRepeatedLists() throws {
    let text = config("AllowedIPs = 198.51.100.7")
        .replacingOccurrences(of: "DNS = 10.9.0.53", with: "DNS = 10.9.0.53 # local comment\nDNS = internal.example\nAddress = 10.255.0.3")
    let metadata = try parse("\u{feff}" + text.replacingOccurrences(of: "\n", with: "\r\n"))
    #expect(metadata.addresses.count == 2)
    #expect(metadata.peers[0].allowedIPs.count == 2)
    #expect(metadata.searchDomains == ["internal.example"])
    #expect(metadata.compatibilityIssues.allSatisfy { !$0.blocksPlanning })
}

@Test func wgKeywordsAreCaseInsensitive() throws {
    let text = config().replacingOccurrences(of: "[Interface]", with: "[interface]").replacingOccurrences(of: "PrivateKey", with: "privatekey")
    #expect(try parse(text).addresses.count == 1)
}

@Test(arguments: ["Table = off", "SaveConfig = true", "FwMark = 1", "Unknown = PRIVATE-SENTINEL"])
func wgRejectsUnsupportedDirectives(_ directive: String) {
    expectImportError(config().replacingOccurrences(of: "[Peer]", with: directive + "\n[Peer]"), .unsupported)
}

@Test(arguments: ["PreUp", "PostUp", "PreDown", "PostDown"])
func wgRejectsHooksWithoutExecutingOrEchoing(_ hook: String) {
    let text = config().replacingOccurrences(of: "[Peer]", with: "\(hook) = PRIVATE-SCRIPT-SENTINEL\n[Peer]")
    do { _ = try parse(text); Issue.record("Hook accepted") }
    catch let error as WGImportError {
        #expect(error.code == .script); #expect(error.line != nil)
        #expect(!error.message.contains("PRIVATE-SCRIPT-SENTINEL"))
    } catch { Issue.record("Unexpected error") }
}

@Test(arguments: ["PrivateKey", "PublicKey", "PresharedKey", "Endpoint", "MTU", "ListenPort", "PersistentKeepalive"])
func wgRejectsDuplicateSingletons(_ key: String) {
    let original = config().split(separator: "\n").first { $0.hasPrefix(key + " =") }!
    expectImportError(config().replacingOccurrences(of: String(original), with: "\(original)\n\(original)"), .duplicate)
}

@Test func wgRejectsDuplicateAndMissingSections() {
    expectImportError(config("[Interface]"), .duplicate)
    expectImportError("[Peer]\nPublicKey = \(publicKey)", .syntax)
    expectImportError("[Interface]\nPrivateKey = \(privateKey)", .required)
    expectImportError(config().replacingOccurrences(of: "PrivateKey = \(privateKey)\n", with: ""), .required, field: .privateKey)
    expectImportError(config().replacingOccurrences(of: "PublicKey = \(publicKey)\n", with: ""), .required, field: .publicKey)
}

@Test func wgRejectsDuplicatePeerPublicKeys() {
    expectImportError(config("[Peer]\nPublicKey = \(publicKey)"), .duplicate, field: .publicKey)
}

@Test(arguments: ["", "not-a-key", "$(cat secret)", "../private-key", Data(repeating: 0, count: 32).base64EncodedString(), Data(repeating: 1, count: 31).base64EncodedString()])
func wgRejectsMalformedKeys(_ value: String) {
    expectImportError(config().replacingOccurrences(of: privateKey, with: value), .key, field: .privateKey)
}

@Test func wgRejectsUnpaddedAndNonCanonicalBase64() {
    expectImportError(config().replacingOccurrences(of: privateKey, with: String(privateKey.dropLast())), .key)
    expectImportError(config().replacingOccurrences(of: publicKey, with: " " + publicKey.replacingOccurrences(of: "=", with: "==")), .key)
}

@Test(arguments: ["192.0.2.10:0", "vpn.example:65536", "http://vpn.example:443", "2001:db8::1:51820", "[fe80::1%en0]:51820", "999.1.1.1:51820", "vpn.example:", "-vpn.example:1"])
func wgRejectsInvalidEndpoints(_ value: String) {
    expectImportError(config().replacingOccurrences(of: "192.0.2.10:51820", with: value), .endpoint, field: .endpoint)
}

@Test(arguments: ["10.0.0.1/33", "01.2.3.4/24", "10.0.0.1/", "10.0.0.1,,10.0.0.2", "::1/129", "fe80::1%en0/64"])
func wgRejectsInvalidRanges(_ value: String) {
    expectImportError(config().replacingOccurrences(of: "10.9.0.0/16", with: value), .address)
}

@Test func wgIPv6IsPreservedAndBlocksPartialSuccess() throws {
    let metadata = try parse(config("AllowedIPs = ::/0").replacingOccurrences(of: "192.0.2.10:51820", with: "[2001:db8::1]:51820"))
    #expect(metadata.peers[0].allowedIPs.last?.text == "::/0")
    #expect(metadata.peers[0].endpoint?.display == "[2001:db8::1]:51820")
    #expect(metadata.compatibilityIssues.contains { $0.code == "W_WG_IPV6_UNSUPPORTED" && $0.blocksPlanning })
    #expect(throws: WGImportError(.planning)) { try PolicyPreview.compile(imported(metadata)) }
}

@Test func wgHostnameIsNotResolvedOrSubstituted() throws {
    let metadata = try parse(config().replacingOccurrences(of: "192.0.2.10:51820", with: "vpn.example.invalid:51820"))
    #expect(metadata.peers[0].endpoint?.isHostname == true)
    #expect(metadata.compatibilityIssues.contains { $0.code == "W_WG_ENDPOINT_DNS" })
    #expect(throws: WGImportError(.planning)) { try PolicyPreview.compile(imported(metadata)) }
}

@Test func wgMissingClientInputsHaveCompatibilityIssues() throws {
    let text = config().replacingOccurrences(of: "Address = 10.255.0.2/32\n", with: "")
        .replacingOccurrences(of: "Endpoint = 192.0.2.10:51820\n", with: "")
        .replacingOccurrences(of: "AllowedIPs = 10.9.0.0/16", with: "AllowedIPs =")
    let metadata = try parse(text)
    #expect(metadata.compatibilityIssues.filter(\.blocksPlanning).count == 3)
}

@Test func wgOptionalPSKAndKeepaliveOff() throws {
    let text = config().replacingOccurrences(of: "PresharedKey = \(psk)\n", with: "")
        .replacingOccurrences(of: "PersistentKeepalive = 25", with: "PersistentKeepalive = off")
    let peer = try parse(text).peers[0]
    #expect(!peer.hadPresharedKey); #expect(peer.persistentKeepalive == 0)
}

@Test(arguments: ["MTU = 575", "ListenPort = -1", "PersistentKeepalive = 65536"])
func wgRejectsInvalidNumbers(_ pair: String) {
    let key = String(pair.split(separator: "=")[0]).trimmingCharacters(in: .whitespaces)
    let original = String(config().split(separator: "\n").first { $0.hasPrefix(key + " =") }!)
    expectImportError(config().replacingOccurrences(of: original, with: pair), .number)
}

@Test func wgRejectsEncodingControlsAndBadSyntax() {
    #expect(throws: WGImportError(.text)) { try WireGuardImport.parse(Data([0xff, 0xfe])) }
    expectImportError(config() + "\u{0}", .text)
    expectImportError(config().replacingOccurrences(of: "[Peer]", with: "[Unknown]"), .syntax)
    expectImportError(config().replacingOccurrences(of: "PrivateKey = \(privateKey)", with: "PrivateKey"), .syntax)
}

@Test func wgResourceBudgetsAreEnforced() {
    #expect(throws: WGImportError(.limit)) { try WireGuardImport.parse(Data(repeating: 32, count: WireGuardImport.byteLimit + 1)) }
    expectImportError(config() + String(repeating: "\n", count: 4096), .limit)
    expectImportError(config() + "#" + String(repeating: "x", count: 4096), .limit)
    expectImportError(config() + String(repeating: "\n[Peer]", count: 64), .limit)
    expectImportError(config("AllowedIPs = " + Array(repeating: "10.9.0.1", count: 500).joined(separator: ",")), .limit)
    let text = config() + String(repeating: "\nAllowedIPs = 10.9.0.1", count: 2048)
    expectImportError(text, .limit)
}

@Test func wgStructuredMetadataRejectsTamperingOnReload() throws {
    let data = try JSONEncoder().encode(parse(config()))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["formatVersion"] = 2
    let bad = try JSONDecoder().decode(WGMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: WGImportError(.metadata)) { try bad.validate() }
    object["formatVersion"] = 1; object["mtu"] = 1
    let invalid = try JSONDecoder().decode(WGMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: WGImportError(.metadata)) { try invalid.validate() }
}

@Test func wgMetadataCannotSwitchBackendOrUseOldSchema() throws {
    var profile = try imported()
    #expect(throws: DraftError.unsupportedVersion) { try Workspace(profiles: [profile]).validate() }
    profile.backend = .external
    #expect(throws: WGImportError(.backend)) { try Workspace(profiles: [profile], schemaVersion: 2).validate() }
    #expect(throws: DraftError.unsupportedVersion) { try Workspace(schemaVersion: 4).validate() }
}

@Test func wgV1DraftLoadsWithoutMigrationOrMetadata() throws {
    let data = try JSONEncoder().encode(Workspace(profiles: [ProfileDraft(name: "Existing")]))
    let value = try JSONDecoder().decode(Workspace.self, from: data)
    try value.validate(); #expect(value.schemaVersion == 1); #expect(value.profiles[0].wireGuard == nil)
}

@Test func wgConfirmationAppendsWithoutChangingExistingRules() throws {
    let original = Workspace(profiles: [ProfileDraft(name: "Original", rules: [DraftRule(value: "198.51.100.7")])])
    let pending = try WGImportTransaction(metadata: parse(config()), baseline: original)
    let next = try pending.applying(to: original)
    #expect(next.profiles.first == original.profiles.first)
    #expect(next.profiles.last?.rules.isEmpty == true)
    #expect(next.profiles.last?.wireGuard == pending.metadata)
    #expect(next.schemaVersion == 2)
    #expect(throws: DraftEditError.conflict) { try pending.applying(to: next) }
}

@Test func wgImportSaveIsAtomicRetryableAndClearsOldPreview() throws {
    try temp { root in
        let store = DraftStore(directory: root.appendingPathComponent("store"))
        let original = Workspace(profiles: [ProfileDraft()]); try store.save(original)
        var session = LocalSession(workspace: original); let token = try session.beginSimulation()
        let pending = try WGImportTransaction(metadata: parse(config()), baseline: original)
        let blocked = root.appendingPathComponent("blocked"); try Data().write(to: blocked)
        #expect(throws: DraftError.writeFailed) { try pending.save(session: &session, store: DraftStore(directory: blocked)) }
        #expect(session.workspace == original); #expect(session.preview != nil)
        #expect(try store.load() == original)
        try pending.save(session: &session, store: store)
        #expect(session.selectedID == pending.id); #expect(session.preview == nil)
        session.finishSimulation(token: token, success: true)
        #expect(session.connection.state == .idle)
        #expect(try store.load() == session.workspace)
        let json = try String(contentsOf: store.file, encoding: .utf8)
        for secret in [privateKey, publicKey, psk] { #expect(!json.contains(secret)) }
    }
}

@Test func wgImportDoesNotBypassProfileLimitsOrStaleState() throws {
    let many = Workspace(profiles: (0..<100).map { _ in ProfileDraft() })
    let pending = try WGImportTransaction(metadata: parse(config()), baseline: many)
    #expect(throws: DraftError.tooLarge) { try pending.applying(to: many) }
    var changed = many; changed.profiles[0].name = "Changed"
    #expect(throws: DraftEditError.conflict) { try pending.applying(to: changed) }
}

@Test func wgEditorPreservesMetadataAndPreventsBackendChange() throws {
    let profile = try imported()
    let workspace = Workspace(profiles: [profile], schemaVersion: 2)
    var edit = DraftEdit.settings(profile); edit.name = "New name"
    #expect(try edit.applying(to: workspace).profiles[0].wireGuard == profile.wireGuard)
    edit.backend = .openVPN
    #expect(throws: WGImportError(.backend)) { try edit.applying(to: workspace) }
}

@Test func wgActualCompilerAssignsPeerAndExplainsDNSException() throws {
    let profile = try imported(rules: [DraftRule(value: "10.9.4.5")])
    let preview = try PolicyPreview.compile(profile)
    let constrained = try #require(preview.constrainedPlan)
    #expect(constrained.decision(for: try IPv4Address("10.9.4.5")).wireGuardPeerID == "peer-1")
    let dns = constrained.decision(for: try IPv4Address("10.9.0.53"))
    #expect(dns.policyDecision.action == .direct); #expect(dns.action == .vpn)
    #expect(dns.infrastructureIDs == ["wg-dns-1"])
    #expect(preview.overrides.contains { $0.cidr.description == "10.9.0.53/32" })
    #expect(try preview.explain("10.9.0.53").contains("配置约束后预期 VPN"))
    #expect(preview.boundaryText.contains("未探测物理网关"))
    #expect(preview.text.contains("Peer 分配"))
}

@Test func wgActualCompilerRejectsOutOfPeerRange() throws {
    let profile = try imported(rules: [DraftRule(value: "198.51.100.7")])
    do { _ = try PolicyPreview.compile(profile); Issue.record("Uncovered route accepted") }
    catch let error as PolicyCompilationError {
        #expect(error.diagnostics.first?.code == .peerUnreachableRange)
        #expect(PolicyFeedback.issues(error, profile: profile).first?.ruleID == profile.rules[0].id)
        #expect(PolicyFeedback.issues(error, profile: profile).first?.text.contains("不会自动扩大") == true)
    }
}

@Test(arguments: ["192.0.2.10", "10.255.0.2"])
func wgEndpointAndInterfaceConflictsAreNotSilentlyOverridden(_ target: String) throws {
    let profile = try imported(rules: [DraftRule(value: target)])
    do { _ = try PolicyPreview.compile(profile); Issue.record("Conflict accepted") }
    catch let error as PolicyCompilationError { #expect(error.diagnostics.first?.code == .infrastructureConflict) }
}

@Test func wgDNSDirectConflictAndUncoveredDNSBlock() throws {
    let profile = try imported(rules: [DraftRule(value: "10.9.0.53", action: .direct)])
    #expect(throws: PolicyCompilationError.self) { try PolicyPreview.compile(profile) }
    let metadata = try parse(config().replacingOccurrences(of: "DNS = 10.9.0.53", with: "DNS = 203.0.113.53"))
    #expect(throws: PolicyCompilationError.self) { try PolicyPreview.compile(imported(metadata)) }
}

@Test func wgDuplicatePeerPrefixesAndLongestPrefixUseRealCompiler() throws {
    let key2 = Data(repeating: 68, count: 32).base64EncodedString()
    let extra = "[Peer]\nPublicKey = \(key2)\nEndpoint = 192.0.2.20:51820\nAllowedIPs = 10.9.4.0/24"
    let metadata = try parse(config(extra))
    let preview = try PolicyPreview.compile(imported(metadata, rules: [DraftRule(value: "10.9.0.0/16")]))
    #expect(try preview.constrainedPlan?.decision(for: IPv4Address("10.9.4.5")).wireGuardPeerID == "peer-2")
    let duplicate = try parse(config(extra.replacingOccurrences(of: "10.9.4.0/24", with: "10.9.0.0/16")))
    #expect(throws: PolicyCompilationError.self) { try PolicyPreview.compile(imported(duplicate)) }
}

@Test func wgRecheckFailureInvalidatesPreviousPreview() throws {
    try temp { root in
        var session = LocalSession(workspace: Workspace(profiles: [try imported()], schemaVersion: 2))
        try session.compile(); #expect(session.preview != nil)
        var next = session.workspace
        next.profiles[0].rules.append(DraftRule(value: "192.0.2.10"))
        try session.commit(next, store: DraftStore(directory: root))
        #expect(throws: PolicyCompilationError.self) { try session.compile() }
        #expect(session.preview == nil)
        #expect(session.connection.state == .idle)
    }
}

@Test func wgFileReaderDoesNotMutateOrCopySource() throws {
    try temp { root in
        let url = root.appendingPathComponent("synthetic.conf")
        let bytes = Data(config().utf8); try bytes.write(to: url)
        #expect(try WGImportFileReader.read(url).peers.count == 1)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["synthetic.conf"])
    }
}

@Test func wgFileReaderRejectsSymlinksDirectoriesFIFOsAndOtherFormats() throws {
    try temp { root in
        let file = root.appendingPathComponent("source.conf"); try Data(config().utf8).write(to: file)
        let link = root.appendingPathComponent("link.conf"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: WGImportError(.read)) { try WGImportFileReader.read(link) }
        let dir = root.appendingPathComponent("directory.conf"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        #expect(throws: WGImportError(.read)) { try WGImportFileReader.read(dir) }
        let fifo = root.appendingPathComponent("pipe.conf")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: WGImportError(.read)) { try WGImportFileReader.read(fifo) }
        #expect(throws: WGImportError(.fileType)) { try WGImportFileReader.read(root.appendingPathComponent("profile.ovpn")) }
        #expect(throws: WGImportError(.fileType)) { try WGImportFileReader.read(URL(string: "https://example.invalid/profile.conf")!) }
        #expect(try Data(contentsOf: file) == Data(config().utf8))
    }
}

@Test func wgFileReaderLimitsSizeBeforeParsing() throws {
    try temp { root in
        let file = root.appendingPathComponent("large.conf")
        try Data(repeating: 0, count: WireGuardImport.byteLimit + 1).write(to: file)
        #expect(throws: WGImportError(.limit)) { try WGImportFileReader.read(file) }
    }
}

@Test func wgFirstMatchStaysEquivalentWithConstraints() throws {
    var profile = try imported(rules: [DraftRule(value: "10.9.0.0/16"), DraftRule(value: "10.9.4.5", action: .direct)])
    let first = try PolicyPreview.compile(profile)
    #expect(first.plan.ruleEvaluations[1].effect == .fullyShadowed)
    #expect(try first.constrainedPlan?.decision(for: IPv4Address("10.9.4.5")).action == .vpn)
    profile.rules.reverse()
    let reversed = try PolicyPreview.compile(profile)
    #expect(try reversed.constrainedPlan?.decision(for: IPv4Address("10.9.4.5")).action == .direct)
    #expect(try reversed.constrainedPlan?.decision(for: IPv4Address("10.9.0.53")).action == .vpn)
}

@Test func wgBypassExplainsEndpointAndInterfaceExceptions() throws {
    let metadata = try parse(config().replacingOccurrences(of: "10.9.0.0/16", with: "0.0.0.0/0"))
    var profile = try imported(metadata); profile.defaultAction = .vpn
    let preview = try PolicyPreview.compile(profile)
    let plan = try #require(preview.constrainedPlan)
    #expect(plan.decision(for: try IPv4Address("192.0.2.10")).action == .direct)
    #expect(plan.decision(for: try IPv4Address("10.255.0.2")).action == .direct)
    #expect(try preview.explain("192.0.2.10").contains("用户规则预期 VPN"))
    #expect(try preview.explain("192.0.2.10").contains("配置约束后预期 DIRECT"))
    #expect(profile.wireGuard?.peers[0].allowedIPs[0].text == "0.0.0.0/0")
}

@Test func wgErrorDescriptionsNeverContainInputOrSecrets() {
    let secret = "PRIVATE-KEY-PAYLOAD"
    do { _ = try parse(config().replacingOccurrences(of: privateKey, with: secret)); Issue.record("Invalid key accepted") }
    catch let error as WGImportError {
        #expect(error.line == 2); #expect(error.field == .privateKey)
        for text in [error.description, error.message, String(reflecting: error), PolicyFeedback.message(error), PolicyPreview.errorText(error)] {
            #expect(!text.contains(secret)); #expect(!text.contains(privateKey)); #expect(!text.contains(psk))
        }
    } catch { Issue.record("Unexpected error type") }
}

@Test func wgTamperedV2WorkspaceIsPreservedAndNotReset() throws {
    try temp { root in
        let store = DraftStore(directory: root)
        try store.save(Workspace(profiles: [try imported()], schemaVersion: 2))
        let json = try String(contentsOf: store.file, encoding: .utf8)
        let tampered = Data(json.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99").utf8)
        #expect(tampered != Data(json.utf8))
        try tampered.write(to: store.file)
        #expect(throws: DraftError.readFailed) { try store.load() }
        #expect(try Data(contentsOf: store.file) == tampered)
    }
}

@Test func wgBlockedCompatibilityIsLocalizedWithoutEndpointEcho() throws {
    let endpoint = "private-corporate.example.invalid"
    let profile = try imported(parse(config().replacingOccurrences(of: "192.0.2.10", with: endpoint)))
    let issues = PolicyFeedback.issues(WGImportError(.planning), profile: profile)
    #expect(issues.count == 1)
    #expect(issues[0].code == "W_WG_ENDPOINT_DNS")
    #expect(issues[0].text.contains("尚未解析"))
    #expect(!issues[0].text.contains(endpoint))
}

@Test func wgFileReaderRejectsEmbeddedNUL() {
    let path = URL(fileURLWithPath: "/tmp/synthetic.conf\u{0}ignored.conf")
    #expect(throws: WGImportError(.read)) { try WGImportFileReader.read(path) }
}
