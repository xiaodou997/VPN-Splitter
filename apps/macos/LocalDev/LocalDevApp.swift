// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LocalDevModel: ObservableObject {
    @Published private(set) var session = LocalSession(workspace: Workspace())
    @Published private(set) var editor = DraftEditor()
    @Published private(set) var pendingImport: CredentialImportTransaction?
    @Published private(set) var choosingImport = false
    @Published private(set) var storageReady = false
    @Published private(set) var message = ""
    @Published private(set) var issues: [CheckIssue] = []
    @Published private var quitAfterEditorDismissal = false
    @Published private(set) var keychainBusy = false
    private var lease: WorkspaceLease?
    private var store: DraftStore?
    private var completion: Task<Void, Never>?
    var canAct: Bool { storageReady && editor.allowsWorkspaceActions && pendingImport == nil && !choosingImport && !quitAfterEditorDismissal && !keychainBusy }

    init() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            message = "无法定位用户数据目录，已禁止写入。"; return
        }
        let store = DraftStore(directory: support.appendingPathComponent("VPN-Splitter-LocalDev", isDirectory: true))
        self.store = store
        do {
            lease = try WorkspaceLease(directory: store.directory)
            session = LocalSession(workspace: try store.load())
            storageReady = true
        } catch {
            message = PolicyFeedback.message(error) + " 请按 docs/localdev.md 保护原文件后恢复。"
        }
    }

    func select(_ id: UUID?) {
        guard canAct else { return }
        let previous = session.selectedID
        session.select(id)
        if session.selectedID != previous { completion?.cancel(); message = ""; issues = [] }
    }

    @discardableResult
    private func commit(_ workspace: Workspace) -> Bool {
        guard canAct, let store else { return false }
        do {
            try session.commit(workspace, store: store)
            completion?.cancel(); message = ""; issues = []
            return true
        } catch { message = PolicyFeedback.message(error); return false }
    }

    func chooseWireGuard(replacing profileID: UUID? = nil) {
        guard canAct else { return }
        choosingImport = true
        defer { choosingImport = false }
        let panel = NSOpenPanel()
        panel.title = profileID == nil ? "导入 WireGuard 配置" : "重新导入当前策略的 WireGuard 配置"
        panel.message = "只读取所选 .conf，随后选择仅保存结构或同时保存到 Keychain；不连接 VPN。"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        completion?.cancel(); session.invalidate(); issues = []; message = ""
        do {
            let material = try WGImportFileReader.readCredentials(url)
            pendingImport = try CredentialImportTransaction(material: material, workspace: session.workspace, replacing: profileID)
        } catch { message = PolicyFeedback.message(error) }
    }

    // The worker returns its partially committed session even after failure, so the UI
    // sees durable recovery references. No cancellation or concurrent editing mid-write.
    private func performCredentialWork(
        _ operation: @escaping @Sendable (inout LocalSession, DraftStore) throws -> String,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        guard storageReady, !keychainBusy, let store else { return }
        keychainBusy = true; message = ""; issues = []
        completion?.cancel(); session.cancelSimulation()
        let initial = session
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (LocalSession, Bool, String) in
                var working = initial
                do {
                    let notice = try operation(&working, store)
                    return (working, true, notice)
                } catch { return (working, false, PolicyFeedback.message(error)) }
            }.value
            guard let self else { return }
            self.session = result.0; self.keychainBusy = false
            self.message = result.2
            if result.1 { onSuccess() }
        }
    }

    func confirmImport(id: UUID, persistCredentials: Bool) {
        guard storageReady, !keychainBusy, editor.allowsWorkspaceActions, !choosingImport,
              let pending = pendingImport, pending.id == id else { return }
        performCredentialWork({ state, store in
            let vault = KeychainCredentialVault()
            try CredentialOperations.save(pending, persistCredentials: persistCredentials,
                session: &state, store: store, vault: vault)
            if let old = pending.previousCredential {
                do { try CredentialOperations.cleanup(session: &state, store: store, vault: vault, only: old) }
                catch { return "新配置已保存；旧凭据清理未完成。" + PolicyFeedback.message(error) }
            }
            return persistCredentials ? "凭据已保存到 Keychain 并读回校验；这不是 VPN 认证或连接结果。" : "仅结构已保存；不代表完整凭据已保存。"
        }, onSuccess: { [weak self] in self?.pendingImport = nil })
    }

    func cancelImport() {
        guard !keychainBusy else { return }
        pendingImport = nil; message = ""
    }

    func retryCredentialCleanup() {
        guard storageReady, !keychainBusy, editor.allowsWorkspaceActions, !choosingImport else { return }
        performCredentialWork { state, store in
            try CredentialOperations.cleanup(session: &state, store: store, vault: KeychainCredentialVault())
            return "已完成已记录条目的清理；没有扫描或删除其他 Keychain 内容。"
        }
    }

    func verifyCredentials(_ profileID: UUID) {
        guard canAct, let profile = session.profile, profile.id == profileID,
              let reference = profile.credential, let metadata = profile.wireGuard else { return }
        performCredentialWork { _, _ in
            try KeychainCredentialVault().verify(reference: reference, metadata: metadata)
            return "本次 Keychain 读取与结构校验通过；未验证服务器认证，未建立隧道。"
        }
    }

    private func removeStoredData(_ profileID: UUID, deleteProfile: Bool, removeMetadata: Bool) {
        guard canAct, session.selectedID == profileID else { return }
        let reference = session.profile?.credential
        performCredentialWork { state, store in
            try CredentialOperations.remove(profileID: profileID, deleteProfile: deleteProfile,
                removeMetadata: removeMetadata, session: &state, store: store)
            if let reference {
                do { try CredentialOperations.cleanup(session: &state, store: store,
                    vault: KeychainCredentialVault(), only: reference) }
                catch { return "本地删除/解除关联已保存；Keychain 清理待重试。" + PolicyFeedback.message(error) }
            }
            return "操作已完成；原 .conf 未修改。"
        }
    }

    func removeWireGuard(_ profileID: UUID) {
        guard canAct else { return }
        removeStoredData(profileID, deleteProfile: false, removeMetadata: true)
    }

    func removeCredentials(_ profileID: UUID) {
        guard canAct else { return }
        removeStoredData(profileID, deleteProfile: false, removeMetadata: false)
    }

    func addProfile() {
        guard canAct else { return }
        var next = session.workspace
        let profile = ProfileDraft(name: "策略 \(next.profiles.count + 1)")
        next.profiles.append(profile)
        if commit(next) { session.select(profile.id) }
    }

    func deleteProfile(_ id: UUID) {
        guard canAct, session.selectedID == id else { return }
        removeStoredData(id, deleteProfile: true, removeMetadata: true)
    }

    func changeRules(_ change: (inout ProfileDraft) -> Void) {
        guard canAct else { return }
        var next = session.workspace
        guard let index = next.profiles.firstIndex(where: { $0.id == session.selectedID }) else { return }
        change(&next.profiles[index])
        _ = commit(next)
    }

    func openSettings() {
        guard canAct, let profile = session.profile else { return }
        begin(.settings(profile))
    }

    func openRule(_ id: UUID? = nil) {
        guard canAct, let profile = session.profile else { return }
        do { begin(try .rule(profile, id: id)) }
        catch { message = PolicyFeedback.message(error) }
    }

    func openBatchRules() {
        guard canAct, let profile = session.profile else { return }
        begin(.batch(profile))
    }

    private func begin(_ value: DraftEdit) {
        do {
            try editor.begin(value)
            completion?.cancel(); session.cancelSimulation(); message = ""
        } catch { message = PolicyFeedback.message(error) }
    }

    func updateEditor(id: UUID, _ change: (inout DraftEdit) -> Void) {
        editor.update(id: id, change)
    }

    @discardableResult
    func closeEditor(discard: Bool = false) -> Bool {
        guard !keychainBusy else { return false }
        let closed = editor.cancel(discardChanges: discard)
        if closed { message = "" }
        return closed
    }

    @discardableResult
    func saveEditor() -> Bool {
        guard storageReady, !keychainBusy, let store else { return false }
        do {
            try editor.save(session: &session, store: store)
            completion?.cancel(); message = ""; issues = []
            return true
        } catch { message = PolicyFeedback.message(error); return false }
    }

    func compile() {
        guard canAct else { return }
        completion?.cancel(); issues = []; message = ""
        do { try session.compile() }
        catch { reportCheck(error) }
    }

    private func reportCheck(_ error: any Error) {
        if let profile = session.profile { issues = PolicyFeedback.issues(error, profile: profile) }
        else { message = PolicyFeedback.message(error) }
    }

    func simulate(failure: Bool) {
        guard canAct else { return }
        completion?.cancel(); issues = []; message = ""
        do {
            let token = try session.beginSimulation()
            completion = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.session.finishSimulation(token: token, success: !failure)
            }
        } catch { reportCheck(error) }
    }

    func cancel() { completion?.cancel(); session.cancelSimulation() }

    // The buffer lives on the App model, not on a replaceable profile View.
    // Menu Quit and the application delegate both use this same decision.
    func canQuit() -> Bool {
        guard !choosingImport, !keychainBusy else { return false }
        if pendingImport != nil {
            let alert = NSAlert()
            alert.messageText = "导入尚未确认保存"
            alert.informativeText = "退出会释放本次导入的内存内容；已保存的策略与待清理记录保留，原 .conf 不变。"
            alert.addButton(withTitle: "继续查看")
            alert.addButton(withTitle: "放弃导入并退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            cancelImport()
        }
        guard editor.hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "请选择继续编辑、保存并退出，或放弃本次修改。保存失败不会退出。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "放弃并退出")
        switch alert.runModal() {
        case .alertSecondButtonReturn: return saveEditor()
        case .alertThirdButtonReturn: return closeEditor(discard: true)
        default: return false
        }
    }

    func requestQuit() {
        let wasEditing = editor.edit != nil || pendingImport != nil
        guard canQuit() else { return }
        quitAfterEditorDismissal = wasEditing
        _ = closeEditor(discard: true)
        if !wasEditing { NSApplication.shared.terminate(nil) }
    }

    func editorDidDismiss() {
        // Wait for actual sheet dismissal, not an estimated animation delay.
        guard quitAfterEditorDismissal else { return }
        quitAfterEditorDismissal = false
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class LocalDevDelegate: NSObject, NSApplicationDelegate {
    weak var model: LocalDevModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.canQuit() == false ? .terminateCancel : .terminateNow
    }
}

@main
@MainActor
struct LocalDevApp: App {
    @StateObject private var model = LocalDevModel()
    @NSApplicationDelegateAdaptor(LocalDevDelegate.self) private var delegate
    var body: some Scene {
        Window("VPN-Splitter · LocalDev", id: "localdev") {
            LocalDevRoot(model: model)
                .frame(minWidth: 860, minHeight: 600)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 VPN-Splitter LocalDev") { model.requestQuit() }
                    .keyboardShortcut("q")
            }
        }
    }
}

private struct LocalDevRoot: View {
    @ObservedObject var model: LocalDevModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("本地开发模式：不接管网络", systemImage: "wrench.and.screwdriver").bold()
                Spacer()
                Text("LD-02C · 真实 VPN 未接入").foregroundStyle(.secondary)
            }.padding().background(.quaternary)
            if !model.message.isEmpty {
                Text(model.message).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            if model.keychainBusy {
                HStack { ProgressView().controlSize(.small); Text("正在处理本地事务；可能出现系统 Keychain 授权。请勿强制退出。") }
                    .padding(.horizontal).padding(.bottom, 8)
            }
            if !model.session.workspace.cleanupQueue.isEmpty {
                HStack {
                    Text("有 \(model.session.workspace.cleanupQueue.count) 项凭据待清理；未确认清理成功。")
                    Spacer()
                    Button("重试清理") { model.retryCredentialCleanup() }.disabled(!model.canAct)
                }.padding().background(.quaternary)
            }
            // This is a workspace, not a navigation stack. A nested navigation
            // toolbar can put a glass layer over the fixed profile header on macOS 26.
            // Keep the banner and profile header in normal layout, with no overlay.
            HSplitView {
                VStack(alignment: .leading) {
                    Text("我的策略").font(.headline).padding(.horizontal)
                    List(selection: Binding(get: { model.session.selectedID }, set: { model.select($0) })) {
                        ForEach(model.session.workspace.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                Text("\(profile.rules.count) 条规则").font(.caption).foregroundStyle(.secondary)
                            }.tag(profile.id)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Button("导入 WireGuard .conf", systemImage: "square.and.arrow.down") { model.chooseWireGuard() }
                        Button("新建空白策略", systemImage: "plus") { model.addProfile() }
                    }.padding()
                }
                .disabled(!model.canAct)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                Group {
                    if let profile = model.session.profile {
                        ProfilePane(model: model, profile: profile).id(profile.id).disabled(!model.canAct)
                    } else {
                        ContentUnavailableView("新建一份分流策略", systemImage: "list.bullet.rectangle",
                            description: Text("可导入 WireGuard 并选择凭据保存方式，或新建空白策略。本版不连接 VPN。"))
                    }
                }
                .frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: Binding(get: { model.editor.edit != nil }, set: { presented in
            // A presentation callback cannot discard a dirty buffer.
            if !presented { _ = model.closeEditor() }
        }), onDismiss: { model.editorDidDismiss() }) {
            EditorPane(model: model).interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(get: { model.pendingImport != nil }, set: { presented in
            if !presented { model.cancelImport() }
        }), onDismiss: { model.editorDidDismiss() }) {
            WireGuardImportPane(model: model).interactiveDismissDisabled()
        }
    }
}

private struct ProfilePane: View {
    @ObservedObject var model: LocalDevModel
    let profile: ProfileDraft
    @State private var tab = 0
    @State private var searchQuery = ""
    @State private var target = "198.51.100.7"
    @State private var explanation = ""
    @State private var simulateFailure = false
    @State private var confirmDelete = false
    @State private var deleteRuleID: UUID?
    @State private var showWireGuard = false
    @State private var confirmRemoveWireGuard = false
    @State private var confirmRemoveCredentials = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.title2).bold().lineLimit(2)
                        .accessibilityIdentifier("profile-title")
                    Text(PolicyFeedback.mode(profile.defaultAction)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("设置") { model.openSettings() }.accessibilityIdentifier("profile-settings")
                Menu {
                    if profile.backend == .wireGuard {
                        Button("重新导入 WireGuard .conf") { model.chooseWireGuard(replacing: profile.id) }
                    }
                    if profile.credential != nil {
                        Button("仅移除凭据", role: .destructive) { confirmRemoveCredentials = true }
                    }
                    if profile.wireGuard != nil {
                        Button("移除导入结构", role: .destructive) { confirmRemoveWireGuard = true }
                        Divider()
                    }
                    Button("删除策略", role: .destructive) { deleteRuleID = nil; confirmDelete = true }
                } label: { Image(systemName: "ellipsis") }.help("策略操作")
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            if let metadata = profile.wireGuard {
                DisclosureGroup(profile.credential == nil ? "WireGuard · 仅结构，未关联凭据" : "WireGuard · 已关联 Keychain（非认证结果）", isExpanded: $showWireGuard) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button("重新导入") { model.chooseWireGuard(replacing: profile.id) }
                                if profile.credential != nil {
                                    Button("检查 Keychain 读取") { model.verifyCredentials(profile.id) }
                                }
                            }
                            Text(metadata.summary).font(.caption).textSelection(.enabled)
                            ForEach(Array(metadata.compatibilityIssues.enumerated()), id: \.offset) { _, issue in
                                Text(issue.message).font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 170).padding(.top, 8)
                }
                if metadata.compatibilityIssues.contains(where: \.blocksPlanning) {
                    Text("结构已保存，但存在尚未支持的项目，配置约束检查被阻止。展开上方查看原因。")
                        .font(.caption)
                }
            }
            TabView(selection: $tab) {
                rules.tabItem { Label("规则", systemImage: "list.bullet") }.tag(0)
                diagnostics.tabItem { Label("检查", systemImage: "checkmark.magnifyingglass") }.tag(1)
            }
            developerTools
        }
        .padding()
        .onChange(of: profile) { _, _ in explanation = "" }
        .onChange(of: target) { _, _ in explanation = "" }
        .onChange(of: model.session.preview?.plan.context.sessionID) { _, _ in explanation = "" }
        .confirmationDialog(deleteRuleID == nil ? "删除这份策略及全部规则？" : "删除这条规则？",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("确认删除", role: .destructive) {
                guard model.session.selectedID == profile.id else { return }
                if let id = deleteRuleID { model.changeRules { $0.rules.removeAll { $0.id == id } } }
                else { model.deleteProfile(profile.id) }
            }
            Button("取消", role: .cancel) {}
        } message: { Text(deleteRuleID == nil ? "删除策略并尝试清理其 Keychain 凭据；清理失败会保留待处理记录。原 .conf 不变，删除无法撤销。" : "只删除这条规则，不删除凭据。删除后无法撤销。") }
        .confirmationDialog("移除导入的 WireGuard 结构？", isPresented: $confirmRemoveWireGuard, titleVisibility: .visible) {
            Button("移除结构", role: .destructive) { model.removeWireGuard(profile.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保留名称和规则，同时解除并尝试清理关联凭据。原 .conf 不变；此后仅能检查规则意图，不再检查 Peer 或配置基础设施。")
        }
        .confirmationDialog("仅移除 Keychain 凭据？", isPresented: $confirmRemoveCredentials, titleVisibility: .visible) {
            Button("移除凭据", role: .destructive) { model.removeCredentials(profile.id) }
            Button("取消", role: .cancel) {}
        } message: { Text("保留当前网络结构、名称和规则。以后保存完整凭据需重新选择原 .conf。") }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("添加规则", systemImage: "plus") { model.openRule() }
                Button("批量添加") { model.openBatchRules() }
                Spacer()
                Button("检查规则") { model.compile(); tab = 1 }.buttonStyle(.borderedProminent)
            }
            Text("从上到下匹配，第一条命中后停止。开关和排序立即保存；编辑在独立窗口中保存。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("搜索目标、动作或启用状态", text: $searchQuery)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("rule-search")
                if !searchQuery.isEmpty { Button("清除") { searchQuery = "" } }
                Text("\(visibleRuleIndices.count) / \(profile.rules.count) 条").font(.caption)
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("搜索仅筛选显示，检查仍使用全部规则。请清除搜索后调整顺序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if profile.rules.isEmpty {
                ContentUnavailableView("还没有规则", systemImage: "list.bullet",
                    description: Text("添加一个 IP 地址或网段，选择走 VPN 或直连。"))
            } else if visibleRuleIndices.isEmpty {
                ContentUnavailableView("没有匹配的规则", systemImage: "magnifyingglass",
                    description: Text("规则未被删除；清除搜索可显示全部规则。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleRuleIndices, id: \.self) { index in
                            ruleRow(profile.rules[index], index: index)
                            Divider()
                        }
                    }
                }
            }
        }.padding()
    }

    private var visibleRuleIndices: [Int] { RuleSearch.indices(in: profile.rules, query: searchQuery) }
    private var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func ruleRow(_ item: DraftRule, index: Int) -> some View {
        HStack(alignment: .top) {
            Toggle("启用第 \(index + 1) 条规则", isOn: Binding(get: { item.enabled }, set: { value in
                model.changeRules { draft in
                    if let position = draft.rules.firstIndex(where: { $0.id == item.id }) {
                        draft.rules[position].enabled = value
                    }
                }
            })).labelsHidden().help("启用 / 禁用；立即保存")
            VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). \(item.value.isEmpty ? "未填写目标" : item.value)").bold().textSelection(.enabled)
                Text("\(item.match.rawValue) · \(PolicyFeedback.action(item.action))\(item.enabled ? "" : " · 已禁用")")
                    .font(.caption).foregroundStyle(.secondary)
                if let hint = PolicyFeedback.ruleHint(item) { Text(hint).font(.caption) }
                if let issue = model.issues.first(where: { $0.ruleID == item.id }) { Text(issue.text).font(.caption) }
                if let evaluation = model.session.preview?.plan.ruleEvaluations.first(where: { $0.ruleID == item.id.uuidString }) {
                    if evaluation.effect == .fullyShadowed {
                        Text("被前面的规则完全覆盖；需要优先匹配时请上移。").font(.caption)
                    } else if evaluation.effect == .partiallyShadowed {
                        Text("部分目标已由前面的规则匹配。").font(.caption)
                    }
                }
            }
            Spacer()
            Button("编辑") { model.openRule(item.id) }
            Menu {
                Button("上移") { model.changeRules { $0.moveRule(id: item.id, offset: -1) } }.disabled(index == 0 || isSearching)
                Button("下移") { model.changeRules { $0.moveRule(id: item.id, offset: 1) } }
                    .disabled(index + 1 == profile.rules.count || isSearching)
                Divider()
                Button("删除规则", role: .destructive) { deleteRuleID = item.id; confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }.help("排序或删除规则")
        }
    }

    private var diagnostics: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("仅检查已保存的规则，不应用网络设置。").foregroundStyle(.secondary)
                if let preview = model.session.preview {
                    Label(preview.constrainedPlan == nil ? "规则意图检查通过" : "配置范围内检查通过（非网络验证）", systemImage: "checkmark.circle").font(.headline)
                    Text("\(preview.plan.ruleEvaluations.count) 条规则 · \(preview.overrides.count) 条例外路由（未安装）")
                } else if !model.issues.isEmpty {
                    Label("需要修改后重新检查", systemImage: "exclamationmark.triangle").font(.headline)
                } else {
                    Text("尚未检查，或保存后结果已失效。").font(.headline)
                }
                ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                    HStack(alignment: .top) {
                        Text(issue.text).textSelection(.enabled)
                        if let id = issue.ruleID { Button("编辑规则") { model.openRule(id) } }
                        else if profile.wireGuard != nil { Button("查看配置结构") { showWireGuard = true } }
                        else { Button("策略设置") { model.openSettings() } }
                    }
                }
                Button("重新检查规则") { model.compile() }
                Divider()
                Text("这个地址会走哪里？").font(.headline)
                HStack {
                    TextField("IPv4 地址", text: $target)
                    Button("查看选路") {
                        if model.session.preview == nil { model.compile() }
                        do { explanation = try model.session.preview?.explain(target) ?? "请先修正上面的规则问题。" }
                        catch { explanation = PolicyFeedback.message(error) }
                    }
                }
                Text(explanation).textSelection(.enabled)
                DisclosureGroup("范围与技术详情") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.session.preview?.boundaryText ?? PolicyPreview.boundary)
                        Text(model.issues.map(\.code).joined(separator: "\n"))
                        Text(model.session.preview?.text ?? "没有可用的规则预览。")
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }

    private var developerTools: some View {
        DisclosureGroup("开发工具（模拟与合成示例）") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.session.connection.state.rawValue).font(.callout)
                HStack {
                    Button("开始 / 重试模拟") { model.simulate(failure: simulateFailure) }
                    Button("取消 / 停止模拟") { model.cancel() }
                    Toggle("注入认证失败", isOn: $simulateFailure)
                }
                Button("添加合成示例") {
                    model.changeRules { draft in
                        draft.rules += [DraftRule(value: "198.51.100.0/24"),
                                        DraftRule(value: "198.51.100.7", action: .direct)]
                    }
                }
                Text("能力预设可在设置的开发选项中修改；不是后端可用性探测。").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
    }
}

private struct EditorPane: View {
    @ObservedObject var model: LocalDevModel
    @State private var confirmDiscard = false

    private func field<Value>(_ key: WritableKeyPath<DraftEdit, Value>, edit: DraftEdit) -> Binding<Value> {
        Binding(get: { model.editor.edit?[keyPath: key] ?? edit[keyPath: key] },
                set: { value in model.updateEditor(id: edit.id) { $0[keyPath: key] = value } })
    }

    @ViewBuilder
    private func batchFields(_ edit: DraftEdit) -> some View {
        Text("每行一个 IPv4 地址或网段；支持空行和 # 注释。全部使用下面选择的动作。")
            .font(.callout)
        TextEditor(text: field(\.batchText, edit: edit))
            .font(.system(.body, design: .monospaced)).frame(height: 130)
            .accessibilityLabel("批量 IP 或网段，一行一个")
        Picker("这些目标的流量", selection: field(\.batchAction, edit: edit)) {
            Text("走 VPN").tag(DraftAction.vpn)
            Text("直连").tag(DraftAction.direct)
        }
        switch Result(catching: { try IPv4RuleBatch.parse(edit.batchText) }) {
        case .success(let batch):
            Text("将追加 \(batch.targets.count) 条，保存后共 \(edit.baseline.rules.count + batch.targets.count) 条；不替换已有规则或改变默认出口。")
                .font(.caption)
            if edit.baseline.rules.count + batch.targets.count > 1000 {
                Text(RuleBatchError.ruleLimit.message).font(.caption)
            }
            if batch.normalizedCount > 0 {
                Text("\(batch.normalizedCount) 项已归一化为网络地址，可能覆盖整个网段；保存前请展开核对。")
                    .font(.caption).bold()
            }
            if batch.duplicateCount > 0 {
                Text("本批有 \(batch.duplicateCount) 项重复目标；保留原顺序，不自动去重。")
                    .font(.caption)
            }
            DisclosureGroup("查看将保存的目标（规范化后）") {
                ScrollView {
                    Text(batch.targets.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 80)
            }
        case .failure(let error):
            Text(PolicyFeedback.message(error)).font(.caption).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        if let edit = model.editor.edit {
            VStack(alignment: .leading, spacing: 16) {
                Text(edit.kind == .settings ? "策略设置" : (edit.kind == .batch ? "批量添加规则" : (edit.isNewRule ? "添加规则" : "编辑规则")))
                    .font(.title2).bold()
                if edit.kind == .settings {
                    TextField("策略名称", text: field(\.name, edit: edit))
                    Picker("分流方式", selection: field(\.defaultAction, edit: edit)) {
                        Text("仅指定目标走 VPN").tag(DraftAction.direct)
                        Text("除指定目标外走 VPN").tag(DraftAction.vpn)
                        if edit.defaultAction == .reject { Text("阻止（未支持）").tag(DraftAction.reject) }
                    }
                    Text("切换分流方式只改默认出口，不改已有规则；每条规则仍按自己的动作匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("开发选项") {
                        Picker("规划能力预设", selection: field(\.backend, edit: edit)) {
                            ForEach(DraftBackend.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.disabled(edit.baseline.wireGuard != nil)
                        if edit.baseline.wireGuard != nil {
                            Text("已关联 WireGuard 结构。需先在策略菜单移除结构，才能更改预设。")
                                .font(.caption)
                        }
                        Text("只影响规则检查，不表示 VPN 后端已经实现。External 仅支持第二种分流方式。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if edit.kind == .batch {
                    batchFields(edit)
                } else {
                    TextField("目标 IP / 网段", text: field(\.rule.value, edit: edit))
                    Picker("目标流量", selection: field(\.rule.action, edit: edit)) {
                        Text("走 VPN").tag(DraftAction.vpn)
                        Text("直连").tag(DraftAction.direct)
                        if edit.rule.action == .reject { Text("阻止（未支持）").tag(DraftAction.reject) }
                    }
                    Toggle("启用规则", isOn: field(\.rule.enabled, edit: edit))
                    if let hint = PolicyFeedback.ruleHint(edit.rule) { Text(hint).font(.callout) }
                    if edit.rule.match != .ipv4 { Text("当前类型：\(edit.rule.match.rawValue)（未支持）").bold() }
                    DisclosureGroup("其他草稿类型（开发选项）") {
                        Picker("类型", selection: field(\.rule.match, edit: edit)) {
                            ForEach(DraftMatch.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("草稿动作", selection: field(\.rule.action, edit: edit)) {
                            ForEach(DraftAction.allCases, id: \.self) { Text(PolicyFeedback.action($0)).tag($0) }
                        }
                        Text("DOMAIN、后缀、IPv6 和 REJECT 暂不支持；启用时会阻止预览。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(edit.kind == .batch ? "保存会一次追加全部有效规则；含格式错误时整批不保存。只更新本地草稿，不接管网络。不要填写密钥或密码。" : "保存只更新本地草稿，不接管网络。未完成的规则可以保存，但必须修正或禁用后才能通过检查。不要填写密钥或密码。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.message.isEmpty { Text(model.message).textSelection(.enabled) }
                HStack {
                    Text(edit.hasChanges ? "有未保存的修改" : "尚未修改").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { if !model.closeEditor() { confirmDiscard = true } }.keyboardShortcut(.cancelAction)
                    Button(edit.kind == .batch ? "确认追加规则" : "保存草稿") { _ = model.saveEditor() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 540)
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { _ = model.closeEditor(discard: true) }
                Button("继续编辑", role: .cancel) {}
            }
        }
    }
}

private struct WireGuardImportPane: View {
    @ObservedObject var model: LocalDevModel
    @State private var persistCredentials = false
    var body: some View {
        if let pending = model.pendingImport {
            VStack(alignment: .leading, spacing: 14) {
                Text(pending.replacing ? "重新导入 WireGuard" : "WireGuard 导入报告").font(.title2).bold()
                Text(pending.replacing ? "替换当前策略的配置，保留名称、规则顺序和默认出口；不自动扩大 AllowedIPs。" : "创建新策略，不覆盖现有规则。格式正确不代表已认证或可连接。")
                Toggle("同时把凭据保存到本机 Keychain", isOn: $persistCredentials).disabled(model.keychainBusy)
                Text("包含私钥、Peer 公钥及可选预共享密钥；不写入普通 JSON、日志或报告。原 .conf 请继续保留。")
                    .font(.caption).foregroundStyle(.secondary)
                if !persistCredentials, pending.previousCredential != nil {
                    Text("仅保存结构会解除并尝试清理这份策略的旧 Keychain 凭据，不继续使用旧密钥。")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(pending.metadata.summary).textSelection(.enabled)
                        Divider()
                        Text("兼容性检查").font(.headline)
                        if pending.metadata.compatibilityIssues.isEmpty {
                            Text("可以进行配置提供的 IPv4 范围检查。物理网络、实际出口和认证仍未验证。")
                        }
                        ForEach(Array(pending.metadata.compatibilityIssues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message)
                            Text(issue.code).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("结构导入使用 v2 或更高版本；首次凭据事务升级到 v3，旧版本会拒绝读取。中途失败可能留下待清理记录，不会把旧密钥改写成新密钥。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("LocalDev 重编译后 Keychain 访问可能需要系统重新授权；不可访问时不会放宽权限或回退明文。正式扩展共享尚未验证。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.message.isEmpty { Text(model.message).textSelection(.enabled) }
                if !model.session.workspace.cleanupQueue.isEmpty {
                    HStack {
                        Text("待清理 \(model.session.workspace.cleanupQueue.count) 项。清理后可重试；当前报告仍保留。")
                        Button("重试清理") { model.retryCredentialCleanup() }.disabled(model.keychainBusy)
                    }
                }
                if model.keychainBusy { ProgressView("正在处理，请响应系统 Keychain 授权…") }
                HStack {
                    Button("取消导入") { model.cancelImport() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(persistCredentials ? "保存结构与凭据" : "仅保存结构") {
                        model.confirmImport(id: pending.id, persistCredentials: persistCredentials)
                    }.keyboardShortcut(.defaultAction)
                }.disabled(model.keychainBusy)
            }.padding(24).frame(width: 680, height: 660)
                .onAppear { persistCredentials = pending.previousCredential != nil }
        }
    }
}
