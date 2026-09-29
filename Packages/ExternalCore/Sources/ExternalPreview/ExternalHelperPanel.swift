// SPDX-License-Identifier: MIT
#if os(macOS)
import SwiftUI
import AppKit
import ExternalCore
import ExternalControl

@MainActor
final class ExternalHelperModel: ObservableObject {
    @Published private(set) var registration = "未检查"
    @Published private(set) var message = "EX-INT-03B：系统授权不等于应用分流。普通预览版不能注册 Helper。"
    @Published private(set) var response: ExternalControlReply?
    @Published private(set) var busy = false
    @Published var confirmed = false
    private let client = ExternalHelperClient()
    private var operation: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var selection: (UUID, UUID, String)?
    private(set) var cleanupUnconfirmed = false
    init() {
        client.onDisconnect = { [weak self] in self?.invalidate() }
    }
    var canApply: Bool { !busy && confirmed && response?.canApply == true && response?.result.state == .prepared }
    var canClearRecovery: Bool {
        !busy && response?.result.state == .recoveryRequired &&
            response?.result.code == "recoveryAbsent" &&
            (response?.result.recoveryCandidates ?? 0) > 0 &&
            response?.result.recoveryPresent == 0
    }
    func refresh() { registration = client.registrationStatus() }
    func register() {
        let alert = NSAlert(); alert.messageText = "向系统申请注册 External Helper？"
        alert.informativeText = "需要独立签名的控制版放在 /Applications，并由管理员在系统设置批准。此操作不会应用路由。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "申请注册")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try client.register(); refresh(); message = "注册请求已提交；请检查系统授权状态，尚未应用分流。" }
        catch { report(error) }
    }
    func openSettings() { client.openApprovalSettings() }
    func auditRecovery() {
        guard !busy else { return }
        perform { [self] in
            if !client.isConnected { _ = try await client.connect() }
            accept(try await client.send(.init(.recoveryAudit, instance: client.instance)))
        }
    }
    func clearRecovery() {
        guard canClearRecovery else { return }
        let alert = NSAlert(); alert.messageText = "清除本工具的恢复标记？"
        alert.informativeText = "Helper 会重新采集当前网络；只有全部候选及更具体路由仍不存在时才删除 marker。不会删除任何路由或修改 DNS。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新核查并清除标记")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { [self] in
            guard client.isConnected else { throw ExternalControlError.disconnected }
            accept(try await client.send(.init(.recoveryClear, instance: client.instance)))
        }
    }
    func unregister() {
        guard !busy, !cleanupUnconfirmed else { return }
        let alert = NSAlert(); alert.messageText = "注销 External Helper？"
        alert.informativeText = "将先查询服务，只有无活动会话且无未确认清理时才请求注销。不会删除恢复记录。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "查询并注销")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { [self] in
            try await client.unregisterAfterCleanStatus(); response = nil; refresh()
            message = "系统注销请求完成；没有删除路由或恢复记录。"
        }
    }
    private func savedSelection(_ profiles: ExternalProfilesModel) async throws -> (UUID, UUID, String) {
        try Task.checkCancellation()
        guard !profiles.busy, !profiles.hasUnsavedChanges, !profiles.editor.mustReload,
              let profile = profiles.editor.workspace.selected, let revision = profiles.editor.workspace.revision else {
            throw ExternalControlError.staleSelection
        }
        let rules = try profile.routeExecutionRulesText()
        guard !rules.isEmpty else { throw ExternalControlError.staleSelection }
        let before = profiles.editor.workspace; let id = profiles.changeID
        let store = try ExternalProfileStore.applicationStore()
        let disk = try await store.load()
        try Task.checkCancellation()
        guard disk == before, profiles.changeID == id, !profiles.hasUnsavedChanges,
              !profiles.busy, !profiles.editor.mustReload else { throw ExternalControlError.staleSelection }
        return (profile.id, revision, rules)
    }
    func prepare(_ profiles: ExternalProfilesModel) {
        guard !busy, !cleanupUnconfirmed else { return }
        invalidate()
        perform { [self] in
            let selected = try await savedSelection(profiles)
            _ = try await client.connect()
            let reply = try await client.send(.init(.prepare, instance: client.instance,
                profile: selected.0, revision: selected.1, rules: selected.2))
            guard !Task.isCancelled else { throw ExternalControlError.disconnected }
            selection = selected; accept(reply)
            message = reply.result.state == .prepared ? "Helper 已重新检查当前网络。确认窗口 15 秒，未应用；请核对下列提案。" : "Helper 拒绝预检：\(reply.result.code)"
            watch()
        }
    }
    func apply(_ profiles: ExternalProfilesModel) {
        guard canApply, let ticket = response?.ticket, let selected = selection else { return }
        confirmed = false
        perform { [self] in
            let current = try await savedSelection(profiles)
            guard current.0 == selected.0, current.1 == selected.1, current.2 == selected.2 else { throw ExternalControlError.staleSelection }
            cleanupUnconfirmed = true // From submission until an actual clean terminal reply.
            message = "正在请求应用；尚未确认添加，超时不会视为没有写入。"
            let reply = try await client.send(.init(.apply, instance: client.instance,
                profile: selected.0, revision: selected.1, ticket: ticket))
            try Task.checkCancellation()
            accept(reply)
        }
    }
    func stop() {
        guard client.isConnected else { invalidate(); return }
        if busy { invalidate(); return } // Channel loss revokes even a pending native start.
        perform { [self] in accept(try await client.send(.init(.stop, instance: client.instance))) }
    }
    func invalidate() {
        generation = UUID(); operation?.cancel(); operation = nil; monitor?.cancel(); monitor = nil
        client.close(); busy = false; confirmed = false; selection = nil; response = nil
        message = cleanupUnconfirmed ? "连接已撤销；系统清理尚未确认，请保留恢复记录。不能把断开连接当成路由已恢复。" : "尚未应用；请用已保存方案重新预检。"
    }
    func confirmQuit() -> Bool {
        guard cleanupUnconfirmed else { invalidate(); return true }
        let alert = NSAlert(); alert.messageText = "分流会话尚未确认清理"
        alert.informativeText = "建议先请求停止并检查结果。强制退出不能保证撤销，恢复记录会保留。"
        alert.addButton(withTitle: "返回"); alert.addButton(withTitle: "请求停止"); alert.addButton(withTitle: "撤销连接并退出")
        switch alert.runModal() {
        case .alertSecondButtonReturn: stop(); return false
        case .alertThirdButtonReturn: invalidate(); return true
        default: return false
        }
    }
    private func accept(_ value: ExternalControlReply) {
        // Retain the one-shot ticket only during prepared; status cannot create one.
        var reply = value
        if value.result.state == .prepared, let old = response { reply.ticket = old.ticket; reply.proposals = old.proposals }
        response = reply
        switch value.result.state {
        case .active:
            cleanupUnconfirmed = true
            message = "路由添加响应及读回通过，最多 60 秒；实际目标流量尚未验证。"
        case .closed:
            cleanupUnconfirmed = value.result.owned != 0
            if value.result.code == "recoveryCleared" {
                cleanupUnconfirmed = false
                message = "恢复标记已在新鲜零残留审计后清除；没有删除路由或修改 DNS。可以重新预检。"
            } else {
                message = "会话结束：\(value.result.code)，剩余回执 \(value.result.owned)，快照 \(value.result.comparison)。不是全系统恢复保证。"
            }
            monitor?.cancel(); monitor = nil; client.close()
        case .recoveryRequired:
            cleanupUnconfirmed = true
            if value.result.code == "recoveryAbsent" {
                message = "恢复核查：候选 \(value.result.recoveryCandidates) 条，当前未发现候选或更具体路由。可执行二次核查后仅清除本工具 marker。"
            } else if value.result.code == "recoveryPresent" {
                message = "恢复核查：候选 \(value.result.recoveryCandidates) 条，仍发现 \(value.result.recoveryPresent) 条存在/歧义。不会提供强制删除。"
            } else {
                message = "需要恢复：\(value.result.code)。不要重复应用或删除标记。"
            }
            monitor?.cancel(); monitor = nil
        case .refused:
            message = "Helper 拒绝：\(value.result.code)。"
        default: break
        }
    }
    private func report(_ error: any Error) {
        let code = (error as? ExternalControlError)?.rawValue ?? (error as? ExternalProfileError)?.rawValue ?? "unavailable"
        client.close(); monitor?.cancel(); monitor = nil
        response = nil; selection = nil; confirmed = false
        message = "操作未完成：\(code)。" + (cleanupUnconfirmed ? "清理未确认，保留恢复记录。" : "没有提交应用；不要降低签名检查。")
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; let id = generation
        operation = Task { @MainActor [self] in
            defer { if generation == id { busy = false; operation = nil } }
            do { try await work() }
            catch { if generation == id { report(error) } }
        }
    }
    private func watch() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.client.isConnected else { return }
                if self.busy { continue }
                self.perform { [self] in self.accept(try await self.client.send(.init(.status, instance: self.client.instance))) }
            }
        }
    }
}

struct ExternalHelperSessionPanel: View {
    @ObservedObject var helper: ExternalHelperModel
    @ObservedObject var profiles: ExternalProfilesModel
    var body: some View {
        GroupBox("分流会话") {
            VStack(alignment: .leading, spacing: 12) {
                Text(helper.message).textSelection(.enabled)
                Button("用已保存方案进行预检") { helper.prepare(profiles) }
                    .disabled(helper.busy || helper.cleanupUnconfirmed || profiles.busy ||
                              profiles.hasUnsavedChanges || profiles.editor.mustReload || !profiles.canRouteExecute)
                if let response = helper.response {
                    ForEach(Array(response.proposals.enumerated()), id: \.offset) { _, route in
                        Text("\(route.destination) → \(route.gateway) / \(route.interface) · \(route.disposition)")
                            .font(.system(.body, design: .monospaced))
                    }
                    Text("状态：\(response.result.state.rawValue) · \(response.result.diagnostic)")
                        .font(.caption).textSelection(.enabled)
                    if !response.canApply {
                        Text("当前控制版为只读接线；受控写入需要单独签名的 route-trial 构建。").font(.caption)
                    }
                }
                if profiles.hasEnabledFlowRules {
                    Label("此方案含域名/应用规则，等待 Flow Bypass；当前 Route Helper 不会忽略后继续执行。",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                Toggle("我已核对提案，允许本次有限 IPv4 直连例外", isOn: $helper.confirmed)
                    .disabled(helper.busy || helper.response?.result.state != .prepared || helper.response?.canApply != true)
                HStack {
                    Button("开始 60 秒分流") { helper.apply(profiles) }.disabled(!helper.canApply)
                        .buttonStyle(.borderedProminent)
                    Button("停止 / 撤销") { helper.stop() }
                }
                Text("这里只控制本应用的有限 DIRECT 例外；不会停止原 VPN、修改默认路由或 DNS。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ExternalRecoveryPanel: View {
    @ObservedObject var helper: ExternalHelperModel
    var body: some View {
        GroupBox("恢复与异常处理") {
            VStack(alignment: .leading, spacing: 12) {
                Text(helper.message).textSelection(.enabled)
                if let result = helper.response?.result, result.state == .recoveryRequired {
                    LabeledContent("恢复候选") { Text("\(result.recoveryCandidates)") }
                    LabeledContent("仍存在 / 歧义") { Text("\(result.recoveryPresent)") }
                }
                HStack {
                    Button("核查恢复状态（只读）") { helper.auditRecovery() }
                    Button("重新核查并清除恢复标记") { helper.clearRecovery() }
                        .disabled(!helper.canClearRecovery)
                }.disabled(helper.busy)
                Text("不会在这里强制删除路由。只有两次新鲜观察均确认候选不存在时，才删除本工具的恢复标记。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ExternalHelperSettingsPanel: View {
    @ObservedObject var helper: ExternalHelperModel
    var body: some View {
        GroupBox("系统 Helper") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("注册状态") { Text(helper.registration) }
                HStack {
                    Button("检查状态") { helper.refresh() }
                    Button("申请系统授权") { helper.register() }
                    Button("打开系统设置") { helper.openSettings() }
                    Button("注销 Helper") { helper.unregister() }.disabled(helper.cleanupUnconfirmed)
                }.disabled(helper.busy)
                Text("系统授权只允许控制 App 与 Helper 建立受限连接；不会自动应用任何分流规则。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Compatibility wrapper for focused tests and older call sites.
struct ExternalHelperPanel: View {
    @ObservedObject var helper: ExternalHelperModel
    @ObservedObject var profiles: ExternalProfilesModel
    var body: some View {
        VStack(spacing: 16) {
            ExternalHelperSessionPanel(helper: helper, profiles: profiles)
            ExternalRecoveryPanel(helper: helper)
            ExternalHelperSettingsPanel(helper: helper)
        }
    }
}
#endif
