// SPDX-License-Identifier: MIT
#if os(macOS)
import SwiftUI
import AppKit
import ExternalCore

@MainActor
final class ExternalModel: ObservableObject {
    @Published var rules = "" { didSet {
        if preview != nil { message = "规则已修改，旧预览已失效；请重新检测并预览。" }
        preview = nil
    } }
    @Published private(set) var observation: ExternalObservation?
    @Published private(set) var preview: ExternalCore.ExternalPreview?
    @Published private(set) var busy = false
    @Published private(set) var message = "先连接原 VPN，再检测当前网络。只读，无需开发签名或管理员授权。"
    private let reader = ExternalSystemReader()
    private var operation: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var token = UUID()
    func detect(previewRules: Bool) {
        guard !busy else { return }
        preview = nil; observation = nil; expiry?.cancel()
        let id = UUID(); token = id; let text = rules
        busy = true; message = "正在只读检测，未修改网络…"
        operation = Task { @MainActor in
            defer { if token == id { busy = false; operation = nil } }
            do {
                let value = try await reader.capture()
                guard token == id, !Task.isCancelled else { return }
                observation = value
                if previewRules {
                    preview = try ExternalPlanner.preview(text, observation: value, now: ProcessInfo.processInfo.systemUptime)
                    message = "预览已生成，尚未应用。实际流量仍由原 VPN 和系统决定。"
                } else {
                    _ = try ExternalPlanner.topology(value, now: ProcessInfo.processInfo.systemUptime)
                    message = "找到可供规则预览的路由候选；不代表第三方 VPN 兼容性已通过。"
                }
            } catch {
                guard token == id, !Task.isCancelled else { return }
                preview = nil
                if let diagnostic = error as? ExternalRouteParseDiagnostic {
                    message = diagnostic.message
                } else {
                    let failure = error as? ExternalError ?? .readFailed
                    message = failure.message + "（" + failure.rawValue + "）"
                }
            }
            guard token == id, observation != nil else { return }
            // A result is a dated observation, never a live status. Clear even a failed
            // diagnostic snapshot after its remaining freshness window.
            let age = observation.map { ProcessInfo.processInfo.systemUptime - $0.capturedAtUptime } ?? 30
            expiry = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, 30 - age))) } catch { return }
                guard let self, self.token == id else { return }
                self.preview = nil; self.observation = nil
                self.message = "快照已过期，请重新检测；没有路由需要撤销。"
            }
        }
    }
    func cancel() {
        token = UUID(); operation?.cancel(); operation = nil; expiry?.cancel(); expiry = nil
        busy = false; preview = nil; observation = nil
        message = "只读检测已取消，旧结果不再显示；未停止原 VPN，未写路由或 DNS。"
    }
}

@main
struct ExternalPreviewApp: App {
    @StateObject private var model = ExternalModel()
    var body: some Scene {
        WindowGroup("VPN-Splitter · 第三方 VPN") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("第三方 VPN · EX-INT-01").font(.title2).bold()
                    Text("External 开发预览：原客户端负责连接，本应用只检测和预览指定目标的直连例外。尚未接入路由执行。")
                    HStack {
                        Button("检测当前网络（只读）") { model.detect(previewRules: false) }.disabled(model.busy)
                        Button("取消检测 / 清除结果") { model.cancel() }
                    }
                    Text(model.message).textSelection(.enabled)
                    if let snapshot = model.observation {
                        GroupBox("本次观察 · 非持续监测") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("IPv4 路由记录：\(snapshot.routes.count)；物理服务候选：\(snapshot.physicalPaths.count)")
                                ForEach(Array(snapshot.physicalPaths.enumerated()), id: \.offset) { _, path in
                                    Text("物理候选：\(path.interface) → 网关 \(path.gateway.description)")
                                }
                                Text("IPv4 隧道接口候选：" + snapshot.interfaces.filter { $0.isUp && $0.isTunnelCandidate }.map(\.name).joined(separator: ", "))
                                Text("动态存储中的 IPv4 DNS 地址数：\(snapshot.observedDNSServers.count)。这不是完整 resolver 或 DNS 查询路径验证。")
                            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    Divider()
                    Text("需要直连的 IPv4 地址 / CIDR（每行一条，最多 64 条）").bold()
                    Text("Bypass：保留原 VPN 全局模式，只预览 DIRECT 例外；不是默认直连，也不是按应用分流。")
                    TextEditor(text: $model.rules).font(.system(.body, design: .monospaced))
                        .frame(height: 140).border(.secondary).disabled(model.busy)
                    Button("重新检测并预览直连规则") { model.detect(previewRules: true) }
                        .disabled(model.busy || model.rules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let preview = model.preview {
                        GroupBox("拟议变更 · NOT_APPLIED") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("VPN 路由线索：\(preview.topology.pattern.rawValue) / \(preview.topology.tunnelInterface)")
                                ForEach(preview.proposals) { item in
                                    Text("\(item.destination.description) → \(item.gateway.description) / \(item.interface) · " +
                                        (item.disposition == .wouldAdd ? "拟增加，未执行" : "已有直连记录，不认领、不删除"))
                                }
                                Text("规则 \(preview.ruleEvaluations.count) 条 → 例外 \(preview.proposals.count) 条；按已有 PolicyCore 计算，重叠规则可能合并。")
                            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }
                    }
                    Text(ExternalCore.ExternalPreview.boundary).font(.footnote)
                    Text("原始网络观察只留在内存，不上传或自动保存。网络变化后必须重新检测；结果最多显示 30 秒。")
                        .font(.footnote)
                }.padding(24)
            }.frame(minWidth: 800, minHeight: 640)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in model.cancel() }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in model.cancel() }
        }.commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 External 开发预览") { model.cancel(); NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}
#else
import Foundation
@main
struct ExternalUnsupportedPlatform {
    static func main() { print("External preview requires macOS 26+; no network read was performed.") }
}
#endif
