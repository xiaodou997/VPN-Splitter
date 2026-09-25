// SPDX-License-Identifier: MIT
import Foundation
import Testing
import PolicyCore
@testable import AppCore

private func withStore(_ body: (DraftStore) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("localdev-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    try body(DraftStore(directory: url))
}

private func sample() -> ProfileDraft {
    ProfileDraft(name: "Synthetic", rules: [
        DraftRule(value: "198.51.100.0/24", action: .vpn),
        DraftRule(value: "198.51.100.7", action: .direct)
    ])
}

@Test func firstMatchAndShadowExplanation() throws {
    let result = try PolicyPreview.compile(sample())
    #expect(result.plan.ruleEvaluations[1].effect == .fullyShadowed)
    #expect(try result.explain("198.51.100.7").contains("VPN；命中规则 1"))
    #expect(result.text.contains("完全被前序规则遮蔽"))
    #expect(result.text.contains("未检查基础设施/peer"))
}

@Test func reorderChangesActualCompilerDecision() throws {
    var profile = sample()
    profile.moveRule(id: profile.rules[1].id, offset: -1)
    let result = try PolicyPreview.compile(profile)
    #expect(try result.explain("198.51.100.7").contains("DIRECT；命中规则 1"))
    #expect(result.plan.ruleEvaluations[1].effect == .partiallyShadowed)
}

@Test func moveBoundaryAndInvalidOffsetsAreNoOps() {
    var profile = sample(); let original = profile
    profile.moveRule(id: profile.rules[0].id, offset: -1)
    profile.moveRule(id: profile.rules[1].id, offset: 1)
    profile.moveRule(id: profile.rules[0].id, offset: Int.max)
    profile.moveRule(id: UUID(), offset: 1)
    #expect(profile == original)
}

@Test func exactIPAndHostBitsNormalize() throws {
    let profile = ProfileDraft(rules: [DraftRule(value: "198.51.100.7")])
    #expect(try PolicyPreview.compile(profile).plan.overrides.map(\.cidr.description) == ["198.51.100.7/32"])
    let cidr = ProfileDraft(rules: [DraftRule(value: "198.51.100.7/24")])
    #expect(try PolicyPreview.compile(cidr).plan.overrides.map(\.cidr.description) == ["198.51.100.0/24"])
}

@Test func invalidIPv4Blocks() {
    #expect(throws: DraftError.invalidIPv4) {
        try PolicyPreview.compile(ProfileDraft(rules: [DraftRule(value: "not-an-ip")]))
    }
}

@Test(arguments: [DraftMatch.domain, .suffix, .ipv6])
func unsupportedEnabledMatchersBlock(match: DraftMatch) {
    #expect(throws: PolicyCompilationError.self) {
        try PolicyPreview.compile(ProfileDraft(rules: [DraftRule(match: match, value: "synthetic")]))
    }
}

@Test func rejectRuleAndDefaultBlock() {
    #expect(throws: PolicyCompilationError.self) {
        try PolicyPreview.compile(ProfileDraft(rules: [DraftRule(value: "198.51.100.7", action: .reject)]))
    }
    #expect(throws: PolicyCompilationError.self) {
        try PolicyPreview.compile(ProfileDraft(defaultAction: .reject))
    }
}

@Test func disabledInvalidDraftDoesNotDisappear() throws {
    let result = try PolicyPreview.compile(ProfileDraft(rules: [
        DraftRule(value: "invalid", action: .reject, enabled: false)
    ]))
    #expect(result.plan.ruleEvaluations.count == 1)
    #expect(result.plan.ruleEvaluations[0].effect == .disabled)
    #expect(try result.explain("203.0.113.1").contains("默认策略"))
}

@Test func externalIncludeBlockedByRealCapabilities() {
    #expect(throws: PolicyCompilationError.self) {
        try PolicyPreview.compile(ProfileDraft(backend: .external))
    }
}

@Test func externalBypassIsOnlyPlanning() throws {
    let result = try PolicyPreview.compile(ProfileDraft(backend: .external, defaultAction: .vpn))
    #expect(result.plan.limitations.contains(.planningOnly))
    #expect(result.plan.limitations.contains(.noSystemKillSwitch))
}

@Test func diagnosticsDoNotResolveOrEchoInvalidInput() throws {
    let preview = try PolicyPreview.compile(sample())
    #expect(throws: DraftError.invalidIPv4) { try preview.explain("secret.example.invalid") }
    #expect(PolicyPreview.errorText(DraftError.invalidIPv4) == "E_IPV4_INPUT")
    let error = NSError(domain: "PRIVATE-VALUE", code: 1)
    #expect(!PolicyPreview.errorText(error).contains("PRIVATE-VALUE"))
}

@Test func workspaceRoundTripAndModes() throws {
    try withStore { store in
        #expect(try store.load() == Workspace())
        let workspace = Workspace(profiles: [sample()])
        try store.save(workspace)
        #expect(try store.load() == workspace)
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        #expect(dirMode?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["workspace.json"])
    }
}

@Test func failedValidationDoesNotOverwrite() throws {
    try withStore { store in
        let valid = Workspace(profiles: [sample()]); try store.save(valid)
        let before = try Data(contentsOf: store.file)
        #expect(throws: DraftError.unsupportedVersion) { try store.save(Workspace(schemaVersion: 4)) }
        #expect(try Data(contentsOf: store.file) == before)
    }
}

@Test func corruptFileIsNotSilentlyReset() throws {
    try withStore { store in
        try store.save(Workspace())
        let corrupt = Data("not-json".utf8); try corrupt.write(to: store.file)
        #expect(throws: DraftError.readFailed) { try store.load() }
        #expect(try Data(contentsOf: store.file) == corrupt)
    }
}

@Test func futureSchemaIsNotSilentlyReset() throws {
    try withStore { store in
        try store.save(Workspace())
        try Data(#"{"schemaVersion":4,"profiles":[]}"#.utf8).write(to: store.file)
        #expect(throws: DraftError.unsupportedVersion) { try store.load() }
    }
}

@Test func loadResourceLimit() throws {
    try withStore { store in
        try store.save(Workspace())
        try Data(repeating: 0, count: Workspace.byteLimit + 1).write(to: store.file)
        #expect(throws: DraftError.tooLarge) { try store.load() }
    }
}

@Test func duplicatesAndResourceLimitsBlock() {
    let profile = sample()
    #expect(throws: DraftError.invalidDraft) { try Workspace(profiles: [profile, profile]).validate() }
    var duplicate = profile; duplicate.rules.append(duplicate.rules[0])
    #expect(throws: DraftError.invalidDraft) { try Workspace(profiles: [duplicate]).validate() }
    let many = (0..<101).map { _ in ProfileDraft() }
    #expect(throws: DraftError.tooLarge) { try Workspace(profiles: many).validate() }
    let rules = (0..<1001).map { _ in DraftRule() }
    #expect(throws: DraftError.tooLarge) { try Workspace(profiles: [ProfileDraft(rules: rules)]).validate() }
}

@Test func rawMultilineConfigurationCannotBeSavedAsRule() {
    let raw = "[Interface]\nPrivateKey = SYNTHETIC-NOT-A-KEY"
    let workspace = Workspace(profiles: [ProfileDraft(rules: [DraftRule(value: raw)])])
    #expect(throws: DraftError.invalidDraft) { try workspace.validate() }
}

@Test func persistedSchemaContainsNoConnectionOrCredentialFields() throws {
    let data = try JSONEncoder().encode(Workspace(profiles: [sample()]))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["schemaVersion", "profiles"])
    let profiles = try #require(object["profiles"] as? [[String: Any]])
    #expect(Set(profiles[0].keys) == ["id", "name", "backend", "defaultAction", "rules"])
}

@Test func symlinkTargetIsNotReadOrOverwritten() throws {
    try withStore { store in
        try store.save(Workspace())
        let target = store.directory.appendingPathComponent("target.json")
        let original = Data("original".utf8); try original.write(to: target)
        try FileManager.default.removeItem(at: store.file)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        #expect(throws: DraftError.invalidDraft) { try store.load() }
        #expect(throws: DraftError.invalidDraft) { try store.save(Workspace()) }
        #expect(try Data(contentsOf: target) == original)
    }
}

@Test func cancelledCompletionCannotReconnect() {
    var mock = MockConnection(); let token = mock.begin()
    mock.cancel(); mock.finish(token: token, success: true)
    #expect(mock.state == .idle)
}

@Test func staleCompletionCannotFinishNewAttempt() {
    var mock = MockConnection(); let old = mock.begin(); let current = mock.begin()
    mock.finish(token: old, success: true)
    #expect(mock.state == .connecting)
    mock.finish(token: current, success: false)
    #expect(mock.state == .failed)
    mock.finish(token: current, success: true)
    #expect(mock.state == .failed)
}

@Test func mockSuccessAlwaysLabelledSimulation() {
    var mock = MockConnection(); let token = mock.begin()
    mock.finish(token: token, success: true)
    #expect(mock.state == .connected)
    #expect(mock.state.rawValue.contains("模拟"))
    #expect(mock.state.rawValue.contains("不代表 VPN 已连接"))
}

@Test func editInvalidatesPreviewAndPendingConnection() throws {
    try withStore { store in
        var session = LocalSession(workspace: Workspace(profiles: [sample()]))
        let token = try session.beginSimulation()
        #expect(session.preview != nil)
        var next = session.workspace; next.profiles[0].rules.reverse()
        try session.commit(next, store: store)
        session.finishSimulation(token: token, success: true)
        #expect(session.preview == nil)
        #expect(session.connection.state == .idle)
        #expect(try store.load() == next)
    }
}

@Test func failedSavePreservesCurrentSession() throws {
    try withStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let blocked = store.directory.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blocked)
        var session = LocalSession(workspace: Workspace(profiles: [sample()]))
        try session.compile()
        let before = session.workspace
        #expect(throws: DraftError.writeFailed) {
            try session.commit(Workspace(), store: DraftStore(directory: blocked))
        }
        #expect(session.workspace == before)
        #expect(session.preview != nil)
    }
}

@Test func switchingProfilesAndDeletionInvalidate() throws {
    try withStore { store in
        let second = ProfileDraft(name: "Second")
        var session = LocalSession(workspace: Workspace(profiles: [sample(), second]))
        let token = try session.beginSimulation()
        session.select(second.id)
        session.finishSimulation(token: token, success: true)
        #expect(session.preview == nil)
        #expect(session.connection.state == .idle)
        try session.commit(Workspace(), store: store)
        #expect(session.selectedID == nil)
        #expect(throws: DraftError.noProfile) { try session.compile() }
    }
}

@Test func invalidRecompileClearsPriorPreview() throws {
    try withStore { store in
        var session = LocalSession(workspace: Workspace(profiles: [sample()]))
        try session.compile()
        var next = session.workspace; next.profiles[0].rules[0].match = .domain
        try session.commit(next, store: store)
        #expect(throws: PolicyCompilationError.self) { try session.compile() }
        #expect(session.preview == nil)
        #expect(session.connection.state == .idle)
    }
}

@Test func sameOrUnknownSelectionKeepsCurrentAttempt() throws {
    var session = LocalSession(workspace: Workspace(profiles: [sample()]))
    let token = try session.beginSimulation()
    session.select(session.selectedID)
    session.select(UUID())
    #expect(session.connection.state == .connecting)
    session.finishSimulation(token: token, success: true)
    #expect(session.connection.state == .connected)
}
