// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

private func batchProfile() -> ProfileDraft {
    ProfileDraft(name: "Synthetic", rules: [DraftRule(value: "198.51.100.0/24")])
}

private func batchStore(_ body: (DraftStore) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("batch-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    try body(DraftStore(directory: url))
}

@Test func batchNormalizesButPreservesOrderAndDuplicates() throws {
    let batch = try IPv4RuleBatch.parse("198.51.100.7/24\n198.51.100.7\n198.51.100.7/32")
    #expect(batch.targets == ["198.51.100.0/24", "198.51.100.7", "198.51.100.7/32"])
    #expect(batch.normalizedCount == 1)
    #expect(batch.duplicateCount == 1)
    let rules = try batch.appending(to: [], action: .vpn)
    #expect(Set(rules.map(\.id)).count == 3)
    #expect(rules.allSatisfy { $0.enabled && $0.match == .ipv4 && $0.action == .vpn })
}

@Test func batchCRLFCommentsAndBOMHaveCorrectLineNumbers() throws {
    let text = "\u{FEFF}# example\r\n\r\n  198.51.100.7 \r\ninvalid-secret"
    #expect(throws: RuleBatchError.invalidIPv4(line: 4)) { try IPv4RuleBatch.parse(text) }
    #expect(try IPv4RuleBatch.parse("\u{FEFF}# example\r\n\r\n  198.51.100.7 \r").targets == ["198.51.100.7"])
}

@Test(arguments: ["", " \n\t\n", "# example\n # another"])
func batchEmptyIsNotAnEmptyReplacement(_ input: String) {
    #expect(throws: RuleBatchError.empty) { try IPv4RuleBatch.parse(input) }
}

@Test(arguments: ["secret.example.invalid", "2001:db8::1", "198.51.100.1/33", "198.51.100.01",
                  "198.51.100.7,DIRECT", "198.51.100.7 # inline", "198.51.100.7\u{0}"])
func batchInvalidLineFailsWholeParse(_ input: String) {
    #expect(throws: RuleBatchError.invalidIPv4(line: 2)) { try IPv4RuleBatch.parse("203.0.113.7\n" + input) }
    #expect(!PolicyFeedback.message(RuleBatchError.invalidIPv4(line: 2)).contains(input))
}

@Test func batchByteAndRuleBudgets() throws {
    #expect(throws: RuleBatchError.inputLimit) { try IPv4RuleBatch.parse(String(repeating: "x", count: 65537)) }
    #expect(throws: RuleBatchError.inputLimit) { try IPv4RuleBatch.parse(String(repeating: "字", count: 22000)) }
    let thousand = Array(repeating: "198.51.100.7", count: 1000).joined(separator: "\n")
    let batch = try IPv4RuleBatch.parse(thousand)
    #expect(try batch.appending(to: [], action: .direct).count == 1000)
    #expect(throws: RuleBatchError.ruleLimit) { try IPv4RuleBatch.parse(thousand + "\n198.51.100.8") }
    #expect(throws: RuleBatchError.ruleLimit) { try batch.appending(to: [DraftRule()], action: .direct) }
    #expect(throws: RuleBatchError.unsupportedAction) { try batch.appending(to: [], action: .reject) }
}

@Test func batchDefaultsToExceptionAction() {
    #expect(DraftEdit.batch(ProfileDraft()).batchAction == .vpn)
    #expect(DraftEdit.batch(ProfileDraft(defaultAction: .vpn)).batchAction == .direct)
    #expect(!DraftEdit.batch(ProfileDraft()).hasChanges)
}

@Test func batchAppendsWithoutChangingAnyOtherProfileFields() throws {
    var profile = batchProfile()
    profile.defaultAction = .vpn
    var workspace = Workspace(profiles: [profile, ProfileDraft(name: "Other")], schemaVersion: 3)
    workspace.pendingCredentialCleanup = []
    var edit = DraftEdit.batch(profile)
    edit.batchText = "203.0.113.7\n203.0.113.8"
    let next = try edit.applying(to: workspace)
    #expect(next.schemaVersion == 3 && next.pendingCredentialCleanup == [])
    #expect(next.profiles[1] == workspace.profiles[1])
    var expected = profile
    expected.rules = next.profiles[0].rules
    #expect(next.profiles[0] == expected)
    #expect(next.profiles[0].rules[0] == profile.rules[0])
    #expect(next.profiles[0].rules.dropFirst().allSatisfy { $0.action == .direct })
}

@Test func batchDoesNotOverwriteAChangedOrDeletedProfile() throws {
    let profile = batchProfile()
    var edit = DraftEdit.batch(profile); edit.batchText = "203.0.113.7"
    var changed = profile; changed.rules[0].enabled = false
    #expect(throws: DraftEditError.conflict) { try edit.applying(to: Workspace(profiles: [changed])) }
    #expect(throws: DraftEditError.missing) { try edit.applying(to: Workspace()) }
}

@Test func batchCancelRetainsDirtyBufferUntilDiscard() throws {
    var editor = DraftEditor(); try editor.begin(.batch(batchProfile()))
    let id = try #require(editor.edit?.id)
    editor.update(id: id) { $0.batchText = "203.0.113.7" }
    let kept = editor.cancel()
    #expect(!kept)
    #expect(editor.edit?.batchText == "203.0.113.7")
    #expect(!editor.allowsWorkspaceActions)
    #expect(throws: DraftEditError.alreadyEditing) { try editor.begin(.settings(batchProfile())) }
    let discarded = editor.cancel(discardChanges: true)
    #expect(discarded)
    #expect(editor.allowsWorkspaceActions)
}

@Test func batchSaveFailureKeepsEditorSessionDiskAndPreview() throws {
    try batchStore { store in
        let profile = batchProfile(); let workspace = Workspace(profiles: [profile])
        try store.save(workspace)
        var session = LocalSession(workspace: workspace); try session.compile()
        var editor = DraftEditor(); var edit = DraftEdit.batch(profile)
        edit.batchText = "203.0.113.7"; try editor.begin(edit)
        let occupied = store.directory.appendingPathComponent("occupied")
        try Data("not-a-directory".utf8).write(to: occupied)
        #expect(throws: DraftError.writeFailed) { try editor.save(session: &session, store: DraftStore(directory: occupied)) }
        #expect(session.workspace == workspace && session.preview != nil)
        #expect(editor.edit?.batchText == edit.batchText)
        #expect(try store.load() == workspace)
        try editor.save(session: &session, store: store)
        #expect(session.workspace.profiles[0].rules.count == 2)
        #expect(session.preview == nil && editor.edit == nil)
        #expect(try store.load() == session.workspace)
    }
}

@Test func batchInvalidInputCannotPartiallyCommit() throws {
    try batchStore { store in
        let profile = batchProfile(); let workspace = Workspace(profiles: [profile]); try store.save(workspace)
        var session = LocalSession(workspace: workspace)
        var editor = DraftEditor(); var edit = DraftEdit.batch(profile)
        edit.batchText = "203.0.113.7\nnot-an-address"; try editor.begin(edit)
        #expect(throws: RuleBatchError.invalidIPv4(line: 2)) { try editor.save(session: &session, store: store) }
        #expect(session.workspace == workspace && editor.hasUnsavedChanges)
        #expect(try store.load() == workspace)
    }
}

@Test func batchSelectionFenceAndLateSimulationCompletion() throws {
    try batchStore { store in
        let profile = batchProfile(), other = ProfileDraft(name: "Other")
        var session = LocalSession(workspace: Workspace(profiles: [profile, other]))
        let token = try session.beginSimulation()
        var editor = DraftEditor(); var edit = DraftEdit.batch(profile)
        edit.batchText = "198.51.100.7"; edit.batchAction = .direct; try editor.begin(edit)
        session.select(other.id)
        #expect(throws: DraftEditError.conflict) { try editor.save(session: &session, store: store) }
        session.select(profile.id)
        try editor.save(session: &session, store: store)
        session.finishSimulation(token: token, success: true)
        #expect(session.connection.state == .idle && session.preview == nil)
        let preview = try PolicyPreview.compile(try #require(session.profile))
        #expect(preview.plan.ruleEvaluations[1].effect == .fullyShadowed)
        #expect(try preview.explain("198.51.100.7").contains("VPN；命中规则 1"))
    }
}

@Test func searchUsesOriginalIndicesAndDoesNotChangeRuleIntent() throws {
    let rules = [DraftRule(value: "198.51.100.0/24"), DraftRule(value: "203.0.113.7", action: .direct),
                 DraftRule(match: .domain, value: "Corp.Example", enabled: false)]
    #expect(RuleSearch.indices(in: rules, query: " ") == [0, 1, 2])
    #expect(RuleSearch.indices(in: rules, query: "203.0.113") == [1])
    #expect(RuleSearch.indices(in: rules, query: "direct") == [1])
    #expect(RuleSearch.indices(in: rules, query: "直连") == [1])
    #expect(RuleSearch.indices(in: rules, query: " CORP.EXAMPLE ") == [2])
    #expect(RuleSearch.indices(in: rules, query: "已禁用") == [2])
    #expect(RuleSearch.indices(in: rules, query: "已启用") == [0, 1])
    #expect(RuleSearch.indices(in: rules, query: "no-match").isEmpty)
    let preview = try PolicyPreview.compile(ProfileDraft(rules: rules))
    #expect(try preview.explain("198.51.100.7").contains("VPN；命中规则 1"))
    #expect(preview.plan.ruleEvaluations.count == 3)
}
