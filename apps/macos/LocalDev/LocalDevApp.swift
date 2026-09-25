// SPDX-License-Identifier: MIT
import AppCore
import SwiftUI

@MainActor
final class LocalDevModel: ObservableObject {
    @Published private(set) var session = LocalSession(workspace: Workspace())
    @Published private(set) var storageReady = false
    @Published private(set) var message = ""
    private var store: DraftStore?
    private var completion: Task<Void, Never>?

    init() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            message = "E_DRAFT_READ：无法定位用户数据目录。"; return
        }
        let store = DraftStore(directory: support.appendingPathComponent("VPN-Splitter-LocalDev", isDirectory: true))
        self.store = store
        do {
            session = LocalSession(workspace: try store.load())
            storageReady = true
        } catch {
            message = PolicyPreview.errorText(error) + "：为保护原文件，已禁止写入。请按 docs/localdev.md 恢复后重启。"
        }
    }

    func select(_ id: UUID?) {
        let previous = session.selectedID
        session.select(id)
        if session.selectedID != previous { completion?.cancel(); message = "" }
    }

    @discardableResult
    private func commit(_ workspace: Workspace) -> Bool {
        guard storageReady, let store else { return false }
        do {
            try session.commit(workspace, store: store)
            completion?.cancel(); message = ""
            return true
        } catch { message = PolicyPreview.errorText(error) + "：保存失败，未接受本次编辑。"; return false }
    }

    func addProfile() {
        var next = session.workspace
        let profile = ProfileDraft(name: "配置草稿 \(next.profiles.count + 1)")
        next.profiles.append(profile)
        if commit(next) { session.select(profile.id) }
    }

    func deleteProfile() {
        var next = session.workspace
        next.profiles.removeAll { $0.id == session.selectedID }
        _ = commit(next)
    }

    @discardableResult
    func editProfile(_ edit: (inout ProfileDraft) -> Void) -> Bool {
        var next = session.workspace
        guard let index = next.profiles.firstIndex(where: { $0.id == session.selectedID }) else { return false }
        edit(&next.profiles[index])
        return commit(next)
    }

    func compile() {
        completion?.cancel()
        do { try session.compile(); message = "" }
        catch { message = PolicyPreview.errorText(error) }
    }

    func simulate(failure: Bool) {
        completion?.cancel()
        do {
            let token = try session.beginSimulation()
            message = ""
            completion = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.session.finishSimulation(token: token, success: !failure)
            }
        } catch { message = PolicyPreview.errorText(error) }
    }

    func cancel() { completion?.cancel(); session.cancelSimulation() }
}

@main
@MainActor
struct LocalDevApp: App {
    @StateObject private var model = LocalDevModel()
    var body: some Scene {
        Window("VPN-Splitter · LocalDev", id: "localdev") {
            LocalDevRoot(model: model)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1060, height: 780)
    }
}

private struct LocalDevRoot: View {
    @ObservedObject var model: LocalDevModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                Text("本地开发模式：不接管网络").bold()
                Spacer()
                Text("无隧道 · 无路由写入 · 无 DNS 修改").foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary)
            if !model.message.isEmpty {
                Text(model.message).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            NavigationSplitView {
                VStack(alignment: .leading) {
                    Text("配置草稿").font(.headline).padding(.horizontal)
                    List(selection: Binding(get: { model.session.selectedID }, set: { model.select($0) })) {
                        ForEach(model.session.workspace.profiles) { profile in
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                Text("\(profile.backend.rawValue) · 仅规划").font(.caption).foregroundStyle(.secondary)
                            }.tag(profile.id)
                        }
                    }
                    Button("新建草稿", systemImage: "plus") { model.addProfile() }
                        .disabled(!model.storageReady).padding()
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            } detail: {
                if let profile = model.session.profile {
                    ProfilePane(model: model, profile: profile).id(profile.id)
                        .disabled(!model.storageReady)
                } else {
                    ContentUnavailableView("先新建配置草稿", systemImage: "doc.badge.plus",
                        description: Text("这一版编辑策略，不导入 VPN 密钥，也不建立真实连接。"))
                }
            }
        }
    }
}

private struct ProfilePane: View {
    @ObservedObject var model: LocalDevModel
    let profile: ProfileDraft
    @State private var name = ""
    @State private var rule = DraftRule()
    @State private var target = "198.51.100.7"
    @State private var explanation = ""
    @State private var simulateFailure = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.name).font(.title2).bold()
            Text(model.session.connection.state.rawValue).font(.headline)
            HStack {
                Button("开始 / 重试模拟") { model.simulate(failure: simulateFailure) }
                Button("取消 / 停止模拟") { model.cancel() }
                Toggle("下次模拟：认证失败", isOn: $simulateFailure)
            }
            TabView {
                settings.tabItem { Label("配置", systemImage: "slider.horizontal.3") }
                rules.tabItem { Label("规则", systemImage: "list.bullet") }
                diagnostics.tabItem { Label("诊断", systemImage: "stethoscope") }
            }
        }
        .padding()
        .onAppear { name = profile.name }
        .onChange(of: profile) { _, _ in explanation = "" }
        .onChange(of: target) { _, _ in explanation = "" }
        .onChange(of: model.session.preview?.plan.context.sessionID) { _, _ in explanation = "" }
        .confirmationDialog("删除当前草稿及其全部规则？", isPresented: $confirmDelete) {
            Button("删除草稿", role: .destructive) { model.deleteProfile() }
        }
    }

    private var settings: some View {
        Form {
            HStack {
                TextField("名称", text: $name)
                Button("保存名称") { _ = model.editProfile { $0.name = name } }
            }
            Picker("规划能力预设（非运行时探测）", selection: Binding(
                get: { profile.backend }, set: { value in _ = model.editProfile { $0.backend = value } })) {
                ForEach(DraftBackend.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("默认出口", selection: Binding(
                get: { profile.defaultAction }, set: { value in _ = model.editProfile { $0.defaultAction = value } })) {
                Text("DIRECT · Include").tag(DraftAction.direct)
                Text("VPN · Bypass").tag(DraftAction.vpn)
            }
            Text("只保存名称、能力预设和规则。不要在文本字段中粘贴密钥或密码。")
            Text(".conf / .ovpn 导入、Keychain、基础设施与 peer 检查将在后续接入；当前不是可连接的 VPN 配置。")
                .foregroundStyle(.secondary)
            Text("保存、切换或删除草稿会清除旧预览并停止模拟，必须重新编译。")
                .foregroundStyle(.secondary)
            Button("删除当前草稿", role: .destructive) { confirmDelete = true }
        }.padding()
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按列表顺序首次命中。DOMAIN、后缀、IPv6 和 REJECT 暂不支持；启用时会阻止预览。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("类型", selection: $rule.match) {
                    ForEach(DraftMatch.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 210)
                TextField("IP / CIDR 或草稿选择器", text: $rule.value)
                Picker("动作", selection: $rule.action) {
                    ForEach(DraftAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 150)
            }
            HStack {
                Toggle("启用", isOn: $rule.enabled)
                Button(profile.rules.contains(where: { $0.id == rule.id }) ? "保存修改" : "添加规则") {
                    let accepted = model.editProfile { draft in
                        if let index = draft.rules.firstIndex(where: { $0.id == rule.id }) { draft.rules[index] = rule }
                        else { draft.rules.append(rule) }
                    }
                    if accepted { rule = DraftRule() }
                }
                Button("取消编辑") { rule = DraftRule() }
                Spacer()
                Button("添加合成示例") {
                    _ = model.editProfile { draft in
                        draft.rules += [DraftRule(value: "198.51.100.0/24"),
                                        DraftRule(value: "198.51.100.7", action: .direct)]
                    }
                }
            }
            Text("编辑区先保存；预览只使用已保存的规则。").font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(profile.rules.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Toggle("", isOn: Binding(get: { item.enabled }, set: { value in
                                _ = model.editProfile { draft in
                                    if let position = draft.rules.firstIndex(where: { $0.id == item.id }) {
                                        draft.rules[position].enabled = value
                                    }
                                }
                            })).labelsHidden().help("启用规则")
                            VStack(alignment: .leading) {
                                Text("\(index + 1). \(item.match.rawValue) → \(item.action.rawValue)").bold()
                                Text(item.value.isEmpty ? "（空草稿）" : item.value).textSelection(.enabled)
                            }
                            Spacer()
                            Button("编辑") { rule = item }
                            Button("上移") { _ = model.editProfile { $0.moveRule(id: item.id, offset: -1) } }
                                .disabled(index == 0)
                            Button("下移") { _ = model.editProfile { $0.moveRule(id: item.id, offset: 1) } }
                                .disabled(index + 1 == profile.rules.count)
                            Button("删除") {
                                if model.editProfile({ $0.rules.removeAll { $0.id == item.id } }), rule.id == item.id {
                                    rule = DraftRule()
                                }
                            }
                        }
                        Divider()
                    }
                }
            }
            Button("编译规则预览（不应用）") { model.compile() }
        }.padding()
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PolicyPreview.boundary).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("重新编译预览") { model.compile() }
                TextField("诊断 IPv4 地址", text: $target)
                Button("解释命中") {
                    do { explanation = try model.session.preview?.explain(target) ?? "请先编译预览。" }
                    catch { explanation = PolicyPreview.errorText(error) }
                }.disabled(model.session.preview == nil)
            }
            Text(explanation).textSelection(.enabled)
            ScrollView {
                Text(model.session.preview?.text ?? "尚无预览。请先编译；编辑后旧预览会自动失效。")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding()
    }
}
