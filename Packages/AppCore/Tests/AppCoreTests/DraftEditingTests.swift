// SPDX-License-Identifier: MIT
import Foundation
import Testing
import PolicyCore
@testable import AppCore

private func editingProfile() -> ProfileDraft {
    ProfileDraft(name: "Synthetic", rules: [DraftRule(value: "198.51.100.7")])
}

private func editingStore(_ body: (DraftStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edit-tests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(DraftStore(directory: directory))
}

@Test func editCopyDoesNotChangeAcceptedWorkspace() throws {
    let profile = editingProfile(); let workspace = Workspace(profiles: [profile])
    var edit = try DraftEdit.rule(profile, id: profile.rules[0].id)
    edit.rule.value = "203.0.113.8"
    #expect(workspace.profiles[0].rules[0].value == "198.51.100.7")
    #expect(edit.hasChanges)
    #expect(try edit.applying(to: workspace).profiles[0].rules[0].value == "203.0.113.8")
}

@Test(arguments: [true, false]) func staleEnableStateCannotBeOverwritten(enabled: Bool) throws {
    var profile = editingProfile(); profile.rules[0].enabled = enabled
    var edit = try DraftEdit.rule(profile, id: profile.rules[0].id)
    edit.rule.value = "203.0.113.8"
    var latest = Workspace(profiles: [profile]); latest.profiles[0].rules[0].enabled.toggle()
    #expect(throws: DraftEditError.conflict) { try edit.applying(to: latest) }
    #expect(latest.profiles[0].rules[0].enabled == !enabled)
}

@Test func deletedRuleIsNotResurrected() throws {
    let profile = editingProfile(); let edit = try DraftEdit.rule(profile, id: profile.rules[0].id)
    var latest = Workspace(profiles: [profile]); latest.profiles[0].rules = []
    #expect(throws: DraftEditError.conflict) { try edit.applying(to: latest) }
}

@Test func deletedProfileIsNotResurrected() throws {
    let edit = DraftEdit.settings(editingProfile())
    #expect(throws: DraftEditError.missing) { try edit.applying(to: Workspace()) }
}

@Test func editorIdentityAndRuleIdentityCannotBeReplaced() throws {
    let profile = editingProfile(); var editor = DraftEditor()
    let edit = try DraftEdit.rule(profile, id: profile.rules[0].id)
    try editor.begin(edit)
    editor.update(id: edit.id) { $0 = .settings(profile) }
    #expect(editor.edit == edit)
    var tampered = edit; tampered.rule.id = UUID()
    #expect(throws: DraftEditError.conflict) { try tampered.applying(to: Workspace(profiles: [profile])) }
}

@Test func onlyOneEditorCanBeOpen() throws {
    let profile = editingProfile(); var editor = DraftEditor()
    let edit = DraftEdit.settings(profile); try editor.begin(edit)
    #expect(!editor.allowsWorkspaceActions)
    #expect(throws: DraftEditError.alreadyEditing) { try editor.begin(.settings(profile)) }
    #expect(editor.edit == edit)
}

@Test func staleBindingCannotMutateNewEditor() throws {
    let profile = editingProfile(); var editor = DraftEditor()
    let old = DraftEdit.settings(profile); try editor.begin(old)
    let closed = editor.cancel(); #expect(closed)
    let current = DraftEdit.settings(profile); try editor.begin(current)
    editor.update(id: old.id) { $0.name = "stale" }
    #expect(editor.edit == current)
}

@Test func cleanAndRevertedEditorClosesWithoutDiscardPrompt() throws {
    var editor = DraftEditor(); let edit = DraftEdit.settings(editingProfile())
    try editor.begin(edit)
    #expect(!editor.hasUnsavedChanges)
    editor.update(id: edit.id) { $0.name = "changed" }
    #expect(editor.hasUnsavedChanges)
    editor.update(id: edit.id) { $0.name = edit.baseline.name }
    let closed = editor.cancel(); #expect(closed)
    #expect(editor.allowsWorkspaceActions)
}

@Test func dirtyCancelPreservesInputUntilExplicitDiscard() throws {
    var editor = DraftEditor(); let edit = try DraftEdit.rule(editingProfile())
    try editor.begin(edit); editor.update(id: edit.id) { $0.rule.value = "203.0.113.8" }
    let closed = editor.cancel(); #expect(!closed)
    #expect(editor.edit?.rule.value == "203.0.113.8")
    let discarded = editor.cancel(discardChanges: true); #expect(discarded)
    #expect(editor.edit == nil)
}

@Test func successfulSaveClosesEditorAndInvalidatesPreview() throws {
    try editingStore { store in
        let profile = editingProfile(); var session = LocalSession(workspace: Workspace(profiles: [profile]))
        let token = try session.beginSimulation(); var editor = DraftEditor()
        let edit = try DraftEdit.rule(profile, id: profile.rules[0].id); try editor.begin(edit)
        editor.update(id: edit.id) { $0.rule.enabled = false }
        try editor.save(session: &session, store: store)
        session.finishSimulation(token: token, success: true)
        #expect(editor.edit == nil)
        #expect(session.preview == nil)
        #expect(session.connection.state == .idle)
        #expect(try store.load() == session.workspace)
        #expect(session.profile?.rules[0].enabled == false)
    }
}

@Test func failedSaveKeepsEditorSessionAndDisk() throws {
    try editingStore { store in
        let profile = editingProfile(); let workspace = Workspace(profiles: [profile]); try store.save(workspace)
        let before = try Data(contentsOf: store.file)
        let blocked = store.directory.appendingPathComponent("occupied")
        try Data("synthetic".utf8).write(to: blocked)
        var session = LocalSession(workspace: workspace); try session.compile()
        var editor = DraftEditor(); let edit = DraftEdit.settings(profile); try editor.begin(edit)
        editor.update(id: edit.id) { $0.name = "updated" }
        #expect(throws: DraftError.writeFailed) {
            try editor.save(session: &session, store: DraftStore(directory: blocked))
        }
        #expect(editor.edit?.name == "updated")
        #expect(session.workspace == workspace)
        #expect(session.preview != nil)
        #expect(try Data(contentsOf: store.file) == before)
        // Retry uses the same retained buffer, not a reconstructed edit.
        try editor.save(session: &session, store: store)
        #expect(session.profile?.name == "updated")
    }
}

@Test func validationFailureDoesNotDismissEditor() throws {
    try editingStore { store in
        let profile = editingProfile(); var session = LocalSession(workspace: Workspace(profiles: [profile]))
        var editor = DraftEditor(); let edit = DraftEdit.settings(profile); try editor.begin(edit)
        editor.update(id: edit.id) { $0.name = "" }
        #expect(throws: DraftError.invalidDraft) { try editor.save(session: &session, store: store) }
        #expect(editor.hasUnsavedChanges)
        #expect(editor.edit?.name == "")
        #expect(session.profile == profile)
    }
}

@Test func changingSelectionCannotSaveIntoAnotherProfile() throws {
    try editingStore { store in
        let profile = editingProfile(); let second = ProfileDraft(name: "second")
        var session = LocalSession(workspace: Workspace(profiles: [profile, second]))
        var editor = DraftEditor(); let edit = DraftEdit.settings(profile); try editor.begin(edit)
        editor.update(id: edit.id) { $0.name = "unsaved" }
        session.select(second.id)
        #expect(throws: DraftEditError.conflict) { try editor.save(session: &session, store: store) }
        #expect(editor.edit?.name == "unsaved")
        #expect(session.profile == second)
    }
}

@Test func settingsSavePreservesRulesAndSchema() throws {
    let profile = editingProfile(); var edit = DraftEdit.settings(profile)
    edit.name = "renamed"; edit.defaultAction = .vpn; edit.backend = .external
    let result = try edit.applying(to: Workspace(profiles: [profile]))
    #expect(result.schemaVersion == 1)
    #expect(result.profiles[0].rules == profile.rules)
    #expect(result.profiles[0].defaultAction == .vpn)
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
    #expect(Set(object.keys) == ["schemaVersion", "profiles"])
}

@Test func unrelatedProfileChangesArePreserved() throws {
    let profile = editingProfile(); var edit = DraftEdit.settings(profile); edit.name = "updated"
    let other = ProfileDraft(name: "other")
    let next = try edit.applying(to: Workspace(profiles: [profile, other]))
    #expect(next.profiles[1] == other)
}

@Test func newRuleUsesOppositeDefaultWithoutChangingMode() throws {
    var profile = editingProfile()
    #expect(try DraftEdit.rule(profile).rule.action == .vpn)
    profile.defaultAction = .vpn
    let edit = try DraftEdit.rule(profile)
    #expect(edit.rule.action == .direct)
    #expect(!edit.hasChanges)
    let next = try edit.applying(to: Workspace(profiles: [profile]))
    #expect(next.profiles[0].defaultAction == .vpn)
    #expect(next.profiles[0].rules.count == 2)
}

@Test func unknownRuleCannotStartEditing() {
    #expect(throws: DraftEditError.missing) { try DraftEdit.rule(editingProfile(), id: UUID()) }
}

@Test func unsupportedDraftIsPreservedAndStillBlocksWhenEnabled() throws {
    var profile = editingProfile(); profile.rules[0].match = .domain; profile.rules[0].value = "synthetic.invalid"
    var edit = try DraftEdit.rule(profile, id: profile.rules[0].id); edit.rule.enabled = false
    let next = try edit.applying(to: Workspace(profiles: [profile]))
    #expect(next.profiles[0].rules[0].match == .domain)
    #expect(PolicyFeedback.ruleHint(next.profiles[0].rules[0])?.contains("已禁用") == true)
    _ = try PolicyPreview.compile(next.profiles[0])
    #expect(throws: PolicyCompilationError.self) { try PolicyPreview.compile(profile) }
}

@Test func ipErrorsPointToAllInvalidEnabledRowsWithoutInputEcho() {
    let profile = ProfileDraft(rules: [DraftRule(value: "PRIVATE-ONE"), DraftRule(value: "PRIVATE-TWO"),
                                     DraftRule(value: "PRIVATE-THREE", enabled: false)])
    let issues = PolicyFeedback.issues(DraftError.invalidIPv4, profile: profile)
    #expect(issues.map(\.ruleID) == [profile.rules[0].id, profile.rules[1].id])
    #expect(issues[1].text.contains("第 2 条"))
    #expect(!issues.map(\.text).joined().contains("PRIVATE"))
}

@Test func compilerIssuesKeepRuleIdentityAndGuidance() throws {
    let profile = ProfileDraft(rules: [DraftRule(match: .domain, value: "PRIVATE-HOST")])
    do { _ = try PolicyPreview.compile(profile); Issue.record("Must reject an enabled domain rule") }
    catch {
        let issues = PolicyFeedback.issues(error, profile: profile)
        #expect(issues[0].ruleID == profile.rules[0].id)
        #expect(issues[0].text.contains("域名规则尚未实现"))
        #expect(!issues[0].text.contains("PRIVATE"))
        #expect(issues[0].code == "E_CAPABILITY_UNSUPPORTED")
    }
}

@Test func externalModeErrorHasNoMisleadingRuleIndex() {
    let profile = ProfileDraft(backend: .external)
    do { _ = try PolicyPreview.compile(profile); Issue.record("External Include must fail") }
    catch {
        let issues = PolicyFeedback.issues(error, profile: profile)
        #expect(issues[0].ruleID == nil)
        #expect(issues[0].text.contains("External"))
    }
}

@Test func localizedMessagesNeverExposeArbitraryErrorText() {
    let error = NSError(domain: "PRIVATE-DOMAIN", code: 99, userInfo: [NSLocalizedDescriptionKey: "SECRET"])
    #expect(!PolicyFeedback.message(error).contains("PRIVATE"))
    #expect(!PolicyFeedback.message(error).contains("SECRET"))
    #expect(PolicyFeedback.message(DraftEditError.conflict).contains("未覆盖"))
}

@Test func ruleHintsAcceptIPAndCIDRButNotEnabledInvalidInput() {
    #expect(PolicyFeedback.ruleHint(DraftRule(value: "198.51.100.7")) == nil)
    #expect(PolicyFeedback.ruleHint(DraftRule(value: "198.51.100.7/24")) == nil)
    #expect(PolicyFeedback.ruleHint(DraftRule(value: "invalid")) != nil)
    #expect(PolicyFeedback.ruleHint(DraftRule(value: "invalid", enabled: false)) == nil)
}

@Test func noOpSaveDoesNotInvalidateExistingPreview() throws {
    try editingStore { store in
        let profile = editingProfile(); var session = LocalSession(workspace: Workspace(profiles: [profile]))
        try session.compile(); let context = session.preview?.plan.context
        var editor = DraftEditor(); try editor.begin(.settings(profile))
        try editor.save(session: &session, store: store)
        #expect(editor.edit == nil)
        #expect(session.preview?.plan.context == context)
    }
}
