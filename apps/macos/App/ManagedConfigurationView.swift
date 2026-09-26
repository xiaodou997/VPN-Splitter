// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ProviderConfiguration
import PolicyCore

@MainActor
final class ManagedConfigurationModel: ObservableObject {
    static let shared = ManagedConfigurationModel()
    @Published var rules = ""
    @Published var fileSelected = false
    @Published var saveConsent = false
    @Published var deliveryConsent = false
    @Published var busy = false
    @Published var message = "先载入当前正式配置，再选择 .conf 并填写 IPv4 VPN 网段。这里保存的是交付草稿，不建立 VPN。"
    @Published var generation: UInt64?
    @Published var selectionLoaded = false
    private var configuration: Data?
    private var workflow: ManagedAppWorkflow?
    private var operation: Task<Void, Never>?
    private var epoch = UUID()

    private func control() throws -> ManagedAppWorkflow {
        if let workflow { return workflow }
        let created = try ManagedAppWorkflow.open()
        workflow = created
        return created
    }
    func selectConfiguration() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try ManagedWireGuardInput.readConfigurationFile(url)
            configuration = bytes; fileSelected = true; saveConsent = false
            message = "配置已通过格式与首轮范围检查，尚未保存；保存时还会检查网段、AllowedIPs 和基础设施冲突。没有建立 VPN。"
        } catch {
            // A rejected replacement must not leave the prior file armed for saving.
            configuration = nil; fileSelected = false; saveConsent = false
            message = (error as? ManagedWireGuardInputError ?? .file).message
        }
    }
    func refresh() {
        perform { model in
            let control = try model.control(); try await control.refresh()
            model.generation = control.selectedGeneration; model.selectionLoaded = true
            return model.generation.map { "已载入正式配置版本 \($0)，尚未读取凭据。" } ?? "尚无正式配置；可以保存新草稿。"
        }
    }
    func save() {
        guard selectionLoaded, saveConsent, let configuration else { return }
        let rules = self.rules
        perform { model in
            let policy = try ManagedWireGuardInput.encodeIncludePolicy(rules)
            let control = try model.control()
            // Keep the explicit loaded baseline; do not adopt a new selection behind the user.
            try await control.save(configuration: configuration, policyArchive: policy)
            model.generation = control.selectedGeneration
            model.configuration = nil; model.fileSelected = false; model.saveConsent = false
            return "配置与规则检查通过，保存并重新载入一致。旧凭据版本保留；物理网络和出口未验证，没有启动 VPN。"
        }
    }
    func checkDelivery() {
        guard selectionLoaded, deliveryConsent else { return }
        perform { model in
            let control = try model.control()
            let attempt = try await control.checkDelivery()
            return "XPC 已确认暂存，启动请求已提交。attempt=\(attempt.uuidString)。须查看 Provider 接收日志；引擎未接通，预期受控失败，不表示 VPN 连接成功。"
        }
    }
    func cancel() {
        epoch = UUID(); operation?.cancel(); workflow?.cancel()
        configuration = nil; fileSelected = false; saveConsent = false
        message = "已取消交付授权，并请求停止本次已提交的会话。保存回调未结束时仍需等待其结果；不表示系统网络已恢复。"
    }
    private func perform(_ body: @escaping @MainActor (ManagedConfigurationModel) async throws -> String) {
        guard !busy else { return }
        busy = true; let current = UUID(); epoch = current
        operation = Task { @MainActor in
            defer { busy = false; operation = nil }
            do {
                let result = try await body(self)
                if epoch == current { message = result }
            } catch {
                if workflow?.publicationUnconfirmed == true {
                    selectionLoaded = false
                    message = "保存结果未确认：凭据已保留，禁止交付。请先刷新重新核对；不要删除 Keychain、锁文件或系统配置来强行继续。"
                } else if epoch == current, let admission = error as? ManagedWireGuardInputError {
                    message = admission.message + "（" + admission.rawValue + "）"
                } else if epoch == current {
                    let code = (error as? ManagedTransferError ?? .unavailable).rawValue
                    message = "操作未完成（\(code)）。需匹配签名和 App Group；旧 S1 配置须先在 S1 页明确移除。无自动重试或权限回退。"
                }
            }
        }
    }
}

@MainActor
struct ManagedConfigurationView: View {
    @ObservedObject private var model = ManagedConfigurationModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正式配置与凭据交付联调").font(.title2)
            Text("首轮只接受单 Peer、IPv4 数字端点、无 DNS 字段的 Include 配置。保存及交付都会检查脚本、密钥格式、AllowedIPs 和规则冲突；此页仍不建立 VPN。")
            HStack {
                Button("选择 .conf") { model.selectConfiguration() }
                Text(model.fileSelected ? "配置已在内存选择" : "未选择配置")
                Button("载入当前正式配置") { model.refresh() }
            }.disabled(model.busy)
            Text("指定 VPN 网段：每行一个 IPv4 CIDR，其余目标直连。")
            TextEditor(text: $model.rules).font(.system(.body, design: .monospaced)).frame(minHeight: 110)
                .disabled(model.busy)
            Toggle("确认写入正式 App 私有 Keychain，并保存系统 VPN 配置；不自动连接", isOn: $model.saveConsent)
            Button("保存并选择该配置") { model.save() }
                .disabled(model.busy || !model.selectionLoaded || !model.saveConsent || !model.fileSelected)
            Divider()
            Text("交付使用当前已保存版本；上方未保存的输入不参与交付。")
            Toggle("已完成签名及扩展授权、断开其他 VPN，并同意运行凭据交付检查", isOn: $model.deliveryConsent)
            HStack {
                Button("检查凭据交付（不连接 VPN）") { model.checkDelivery() }
                    .disabled(model.busy || !model.selectionLoaded || !model.deliveryConsent)
                Button("取消交付 / 请求停止") { model.cancel() }
            }
            Text(model.message).textSelection(.enabled)
            Text("不是 LocalDev：不会读取或放宽 LocalDev 的旧凭据权限。没有已验证的隧道数据通道、握手或分流出口。")
                .font(.footnote)
        }.padding(24).frame(minWidth: 760, minHeight: 600)
    }
}

@MainActor
final class ManagedAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ManagedConfigurationModel.shared.cancel()
    }
}
