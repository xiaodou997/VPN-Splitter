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
        // Make the existing strong capture explicit; the separate expiry task stays weak.
        operation = Task { @MainActor [self] in
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
    @NSApplicationDelegateAdaptor(ExternalTerminationDelegate.self) private var delegate
    @StateObject private var model: ExternalModel
    @StateObject private var profiles: ExternalProfilesModel
    @StateObject private var helper: ExternalHelperModel
    @State private var section: ExternalSidebarSection = .overview
    init() {
        let network = ExternalModel()
        let documents = ExternalProfilesModel()
        let control = ExternalHelperModel()
        _model = StateObject(wrappedValue: network)
        _profiles = StateObject(wrappedValue: documents)
        _helper = StateObject(wrappedValue: control)
        ExternalTerminationDelegate.shouldTerminate = { [weak network, weak documents, weak control] in
            guard documents?.confirmDiscard() != false, control?.confirmQuit() != false else { return false }
            network?.cancel(); return true
        }
    }
    var body: some Scene {
        WindowGroup("VPN-Splitter · 第三方 VPN") {
            ExternalRootView(model: model, profiles: profiles, helper: helper, selection: $section)
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
                    model.cancel(); helper.invalidate()
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    model.cancel(); helper.invalidate()
                }
        }
        .commands {
            CommandMenu("导航") {
                ForEach(ExternalSidebarSection.allCases) { item in
                    Button(item.title) { section = item }
                        .keyboardShortcut(KeyEquivalent(Character(String(ExternalSidebarSection.allCases.firstIndex(of: item)! + 1))),
                                          modifiers: .command)
                }
            }
            CommandMenu("规则") {
                Button("新建方案") { section = .rules; profiles.newProfile() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("保存方案") { profiles.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!profiles.canSave)
                Button("重新载入方案") { profiles.reload() }
                    .disabled(profiles.busy)
            }
            CommandMenu("分流") {
                Button("检测当前网络") { section = .session; model.detect(previewRules: false) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.busy)
                Button("预览当前规则") {
                    section = .session
                    model.rules = profiles.enabledRules
                    model.detect(previewRules: true)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.busy || profiles.busy || profiles.editor.mustReload ||
                          profiles.hasUnsavedChanges || profiles.enabledRules.isEmpty)
                Divider()
                Button("停止 / 撤销当前会话") { helper.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                Button("核查恢复状态") { section = .recovery; helper.auditRecovery() }
                    .disabled(helper.busy)
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 VPN-Splitter") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        Settings {
            ExternalSettingsView(helper: helper)
        }
    }
#else
import Foundation
@main
struct ExternalUnsupportedPlatform {
    static func main() { print("External preview requires macOS 26+; no network read was performed.") }
}
#endif
