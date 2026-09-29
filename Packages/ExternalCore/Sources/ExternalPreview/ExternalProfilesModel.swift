// SPDX-License-Identifier: MIT
#if os(macOS)
import SwiftUI
import AppKit
import ExternalCore

@MainActor
final class ExternalProfilesModel: ObservableObject {
    @Published private(set) var editor = ExternalProfileEditor()
    @Published private(set) var busy = false
    @Published private(set) var message = "正在载入本机规则方案，不检测网络…"
    @Published private(set) var changeID = UUID()
    @Published var batchText = ""
    private var store: ExternalProfileStore?
    private var operation: Task<Void, Never>?
    var hasUnsavedChanges: Bool { editor.isDirty || !batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var enabledRules: String { (try? editor.draft?.validated().routeExecutionRulesText()) ?? "" }
    var hasEnabledFlowRules: Bool { (try? editor.draft?.validated().hasEnabledFlowRules) ?? false }
    var canRouteExecute: Bool { !hasEnabledFlowRules && !enabledRules.isEmpty }
    var canSave: Bool { editor.loaded && editor.draft != nil && !editor.mustReload && !busy }

    init(store: ExternalProfileStore? = nil) {
        do { self.store = try store ?? ExternalProfileStore.applicationStore() }
        catch { message = (error as? ExternalProfileError ?? .unsafeStorage).message; return }
        // Automatic LOCAL document loading only; no topology/collector/Helper calls.
        reload()
    }
    func confirmDiscard() -> Bool {
        if busy {
            let alert = NSAlert(); alert.messageText = "正在保存或载入"
            alert.informativeText = "请在本次本地事务结束后再关闭或切换。"
            alert.addButton(withTitle: "返回"); _ = alert.runModal(); return false
        }
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert(); alert.messageText = "放弃未保存修改？"
        alert.informativeText = "当前编辑和尚未加入列表的内容会丢弃；已保存文件保持不变。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃修改")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func reload() {
        guard !busy, confirmDiscard() else { return }
        transact { store, _ in try await store.load() }
    }
    func newProfile() {
        guard !busy, confirmDiscard() else { return }
        do {
            try editor.new(discard: true); batchText = ""; changeID = UUID()
            message = "新方案尚未保存。保存规则不会修改网络。"
        } catch { report(error) }
    }
    func select(_ id: UUID) {
        guard !busy, confirmDiscard() else { return }
        do {
            let candidate = try editor.workspace.selecting(id)
            guard editor.loaded, !editor.mustReload else { throw ExternalProfileError.staleRevision }
            transact { store, before in try await store.save(candidate, expectedRevision: before.workspace.revision) }
        } catch { report(error) }
    }
    func save() {
        guard canSave else { return }
        guard batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请先将输入加入规则列表，或清空该输入；不会在保存时忽略它。"; return
        }
        do {
            let candidate = try editor.candidate()
            transact { store, before in try await store.save(candidate, expectedRevision: before.workspace.revision) }
        } catch { report(error) }
    }
    func duplicate() {
        guard !busy, let draft = editor.draft else { return }
        guard batchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请先加入或清空批量输入；复制不会忽略待加入内容。"; return
        }
        if editor.isDirty {
            let alert = NSAlert(); alert.messageText = "复制当前编辑到新方案？"
            alert.informativeText = "当前规则（包括未保存修改）会保留在新副本中；原已保存方案不变。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "复制当前编辑")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        do {
            let copy = draft.duplicated(name: String(draft.name.prefix(55)) + " 副本")
            try editor.new(name: copy.name, discard: true)
            try editor.edit { $0.name = copy.name; $0.rules = copy.rules }
            batchText = ""; changeID = UUID(); message = "副本尚未保存，不会自动应用。"
        } catch { report(error) }
    }
    func deleteSelected() {
        guard !busy, let id = editor.draft?.id, editor.workspace.profiles.contains(where: { $0.id == id }),
              !editor.mustReload else { return }
        let alert = NSAlert(); alert.messageText = "删除这套已保存方案？"
        alert.informativeText = "删除成功后不会自动选择或应用其他方案。当前未保存编辑也会丢弃。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除方案")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            let candidate = try editor.workspace.deleting(id)
            transact { store, before in try await store.save(candidate, expectedRevision: before.workspace.revision) }
        } catch { report(error) }
    }
    func discard() {
        guard !busy, confirmDiscard() else { return }
        editor.discarded(); batchText = ""; changeID = UUID()
        message = editor.mustReload ? "当前编辑已放弃，仍需重新载入磁盘版本。" : "已恢复本窗口上次载入的方案，未改网络。"
    }
    func editName(_ text: String) { mutate { $0.name = text } }
    func editRule(_ id: UUID, text: String? = nil, enabled: Bool? = nil) {
        mutate { profile in
            guard let index = profile.rules.firstIndex(where: { $0.id == id }) else { return }
            if let text { profile.rules[index].target = text }
            if let enabled { profile.rules[index].enabled = enabled }
        }
    }
    func moveRule(_ id: UUID, by offset: Int) { mutate { $0.move(id, by: offset) } }
    func removeRule(_ id: UUID) { mutate { $0.rules.removeAll { $0.id == id } } }
    func addBatch() {
        guard !busy else { return }
        do {
            try editor.edit { try $0.appendBatch(batchText) }
            batchText = ""; changeID = UUID()
            message = hasEnabledFlowRules
                ? "已加入规则。域名/应用规则已保存为正式类型，但当前 Route Bypass 不会执行；等待 Flow Bypass。"
                : "已加入编辑列表；CIDR 已规范化，尚未保存或应用。"
        } catch { report(error) }
    }
    private func mutate(_ body: (inout ExternalSavedProfile) -> Void) {
        guard !busy else { return }
        do { try editor.edit(body); changeID = UUID(); message = "编辑尚未保存，旧预览已失效。" }
        catch { report(error) }
    }
    private func report(_ error: any Error) {
        let failure = error as? ExternalProfileError ?? .readFailed
        editor.failed(failure); changeID = UUID(); message = failure.message + "（" + failure.rawValue + "）"
    }
    private func transact(_ work: @escaping @Sendable (ExternalProfileStore, ExternalProfileEditor) async throws -> ExternalProfileWorkspace) {
        guard !busy, let store else { return }
        busy = true; let before = editor
        operation = Task { @MainActor [self] in
            defer { busy = false; operation = nil }
            do {
                let value = try await work(store, before)
                try editor.saved(value); batchText = ""; changeID = UUID()
                message = "本机方案已载入 / 保存。没有读取凭据、修改网络或执行分流。"
            } catch { report(error) }
        }
    }
}

/// Covers Dock/menu/keyboard quit; closing a window leaves shared in-memory edits
/// with the application. An OS forced termination is not a document-save guarantee.
@MainActor
final class ExternalTerminationDelegate: NSObject, NSApplicationDelegate {
    static var shouldTerminate: (@MainActor () -> Bool)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.shouldTerminate?() == false ? .terminateCancel : .terminateNow
    }
}
#endif
