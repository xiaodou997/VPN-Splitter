// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import SwiftUI
import ExternalCore
import ExternalFlowWire

@MainActor
final class ExternalFlowBridgeModel: ObservableObject {
    @Published private(set) var snapshot: ExternalFlowProbeSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var message = "尚未读取 Flow Probe 报告。"
    private let store: ExternalFlowProbeSnapshotStore?
    private let rulesStore: ExternalFlowRulesBridgeStore?
    private var operation: Task<Void, Never>?

    init(store: ExternalFlowProbeSnapshotStore? = nil, rulesStore: ExternalFlowRulesBridgeStore? = nil) {
        do { self.store = try store ?? ExternalFlowProbeSnapshotStore.applicationStore() }
        catch {
            self.store = nil
            self.rulesStore = nil
            message = "Flow Probe 报告存储不可用；不影响 Route Bypass。"
            return
        }
        do { self.rulesStore = try rulesStore ?? ExternalFlowRulesBridgeStore.applicationStore() }
        catch { self.rulesStore = nil }
        reload()
    }

    func reload() {
        guard !busy, let store else { return }
        operation?.cancel()
        busy = true
        operation = Task { @MainActor [self] in
            defer { busy = false; operation = nil }
            do {
                let value = try await store.load()
                guard !Task.isCancelled else { return }
                snapshot = value
                if let value {
                    let age = max(0, Date().timeIntervalSince(value.capturedAt))
                    message = age > 300
                        ? "已读取旧报告（约 \(Int(age / 60)) 分钟前）；请在 Flow Probe App 重新发布。"
                        : "已读取最新 Flow Probe 脱敏快照。"
                } else {
                    message = "还没有 Flow Probe 报告；请先在签名探针 App 中显式发布。"
                }
            } catch {
                snapshot = nil
                message = "Flow Probe 报告无效或不可读；没有修改网络。"
            }
        }
    }

    /// FLOW-02 trial channel: writes the profile's enabled rules to the
    /// user-local Flow bridge. The Flow Probe App still has to reload them
    /// explicitly; this never touches the Network Extension configuration.
    func exportRules(profile: ExternalSavedProfile) {
        guard !busy, let rulesStore else {
            message = "Flow 规则桥存储不可用；未导出。"
            return
        }
        operation?.cancel()
        busy = true
        operation = Task { @MainActor [self] in
            defer { busy = false; operation = nil }
            do {
                let enabled = profile.rules.filter(\.enabled)
                guard !enabled.isEmpty else {
                    message = "当前方案没有启用的规则；未导出。删除桥文件需在 Flow Probe App 重新保存探针配置。"
                    return
                }
                let wire = try ExternalFlowRulesWire(profileName: profile.name,
                                                     rules: enabled.map(Self.wireRule)).validated()
                try await rulesStore.save(wire)
                guard !Task.isCancelled else { return }
                message = "已导出 \(wire.rules.count) 条 DIRECT 规则到 Flow 桥（仅试验通道）；请到 Flow Probe App 点「重载规则并更新探针配置」。"
            } catch {
                message = "导出失败：规则集无效或存储不可用；未修改任何配置或网络。"
            }
        }
    }

    private static func wireRule(_ rule: ExternalSavedRule) -> ExternalFlowRuleWire {
        let kind: ExternalFlowRuleWireKind
        switch rule.kind {
        case .ipCIDR: kind = .ipCIDR
        case .domain: kind = .domain
        case .domainSuffix: kind = .domainSuffix
        case .domainKeyword: kind = .domainKeyword
        case .application: kind = .application
        }
        return ExternalFlowRuleWire(kind: kind, target: rule.target,
                                    applicationIdentifier: rule.applicationIdentifier)
    }

    func clearView() {
        operation?.cancel(); operation = nil; busy = false; snapshot = nil
        message = "已清除本窗口中的 Flow 报告显示；没有删除磁盘快照或修改网络。"
    }
}
#endif
