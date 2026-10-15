// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import SystemExtensions
import SwiftUI
import ExternalFlowWire

@MainActor
final class FlowProbeController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let extensionID = "io.github.xiaodou997.VPNSplitter.FlowProbeExtension"
    @Published private(set) var extensionStatus = "未请求安装"
    @Published private(set) var configurationStatus = "未检查配置"
    @Published private(set) var busy = false

    func activateExtension() {
        guard !busy else { return }
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard app.deletingLastPathComponent().path == "/Applications" else {
            extensionStatus = "请先把签名后的 Flow Probe App 放到 /Applications；未提交激活请求。"
            return
        }
        busy = true
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionID, queue: .main)
        request.delegate = self
        extensionStatus = "已提交系统扩展激活请求；等待系统结果/用户批准。"
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func refreshConfiguration() {
        perform {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            let matching = managers.filter { Self.bundleIdentifier($0) == Self.extensionID }
            self.configurationStatus = matching.isEmpty ? "未保存 Transparent Proxy 配置" :
                "已有 \(matching.count) 个本应用配置；状态 " + Self.connectionSummary(matching[0])
        }
    }

    func saveProbeConfiguration() {
        perform {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            let manager: NETransparentProxyManager
            if let existing = managers.first(where: { Self.bundleIdentifier($0) == Self.extensionID }) {
                manager = existing
            } else {
                manager = NETransparentProxyManager()
            }
            let provider = NETunnelProviderProtocol()
            provider.providerBundleIdentifier = Self.extensionID
            provider.providerConfiguration = ["VPNSplitterFlowProbe": "metadata-only-v1"]
            provider.serverAddress = "127.0.0.1"
            manager.protocolConfiguration = provider
            manager.localizedDescription = "VPN-Splitter Flow Metadata Probe"
            manager.isEnabled = false
            try await manager.saveToPreferences()
            self.configurationStatus = "探针配置已保存但未启用；没有启动 Transparent Proxy。"
        }
    }

    func startProbe() {
        perform {
            var manager = try await Self.requireManager()
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                manager = try await Self.requireManager()
            }
            try manager.connection.startVPNTunnel()
            self.configurationStatus = "已请求启动 TCP/UDP metadata 探针；provider 仍对所有 flow 返回 false；DNS（目的端口 53）不进入代理。"
        }
    }

    func stopProbe() {
        perform {
            let manager = try await Self.requireManager()
            manager.connection.stopVPNTunnel()
            self.configurationStatus = "已请求停止 metadata 探针；保留配置和 system extension 安装状态。"
        }
    }

    /// FLOW-02 trial channel: reads the rules file the main app exported to
    /// the user-local Flow bridge and writes it into the probe's provider
    /// configuration. Takes effect on the next probe start; an unchanged rule
    /// set does not rewrite preferences.
    func reloadRules() {
        perform {
            let store = try ExternalFlowRulesBridgeStore.applicationStore()
            guard let wire = try await store.load() else {
                self.configurationStatus = "Flow 桥中没有已导出的规则；请先在主 App 的 Flow 实验页导出 DIRECT 规则。"
                return
            }
            let data = try JSONEncoder().encode(wire)
            let manager = try await Self.requireManager()
            let provider = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
            let existing = provider.providerConfiguration?["VPNSplitterFlowRules"] as? Data
            if existing == data {
                self.configurationStatus = "DIRECT 规则（\(wire.rules.count) 条）与当前配置一致；未重写探针配置。"
                return
            }
            provider.providerBundleIdentifier = Self.extensionID
            provider.providerConfiguration = ["VPNSplitterFlowProbe": "metadata-only-v1",
                                              "VPNSplitterFlowRules": data]
            provider.serverAddress = "127.0.0.1"
            manager.protocolConfiguration = provider
            try await manager.saveToPreferences()
            self.configurationStatus = "已写入 \(wire.rules.count) 条 DIRECT 试验规则；重启探针后生效。匹配的 TCP/UDP flow 将由 provider 经物理接口直连；DNS（目的端口 53）不进入代理。"
        }
    }

    func removeProbeConfiguration() {
        perform {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            for manager in managers where Self.bundleIdentifier(manager) == Self.extensionID {
                manager.connection.stopVPNTunnel()
                try await manager.removeFromPreferences()
            }
            self.configurationStatus = "已移除本应用 Transparent Proxy 配置；未停用 system extension。"
        }
    }

    func publishSnapshot() {
        perform {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            let matching = managers.filter { Self.bundleIdentifier($0) == Self.extensionID }
            let selected = matching.first
            let attempt: (String?, ExternalFlowProbeReport?)
            if let selected { attempt = await Self.providerReportAttempt(selected) }
            else { attempt = (nil, nil) }
            let snapshot = ExternalFlowProbeSnapshot(
                configurationCount: matching.count,
                configurationEnabled: selected?.isEnabled ?? false,
                connectionStatus: selected.map { Self.statusName($0.connection.status) } ?? "not_configured",
                providerMessageStatus: attempt.0,
                providerReport: attempt.1
            )
            let store = try ExternalFlowProbeSnapshotStore.applicationStore()
            try await store.save(snapshot)
            if let report = attempt.1 {
                self.configurationStatus = "provider message=PASS；TCP \(report.tcp) / UDP \(report.udp)，App ID 可见 \(report.withSourceSigningIdentifier)，hostname 可见 \(report.withRemoteHostname)；rules=\(report.rulesLoaded)，relay started/completed/failed=\(report.relayStarted)/\(report.relayCompleted)/\(report.relayFailed)，UDP relay=\(report.relayUDPStarted)/\(report.relayUDPCompleted)/\(report.relayUDPFailed)。"
            } else {
                self.configurationStatus = "已发布配置/连接状态；provider message=" + (attempt.0 ?? "not_attempted") + "。"
            }
        }
    }

    /// ADR-EX-INT-08: hot relay pause/resume over the provider message channel.
    /// No tunnel restart and no preferences rewrite; the pause lives only in
    /// the running provider and is cleared by a probe restart.
    func setRelayPaused(_ paused: Bool) {
        perform {
            self.configurationStatus = try await self.relayPauseRequest(paused)
        }
    }

    /// ADR-EX-INT-09: awaitable variant for the isolation guard. Waits for any
    /// in-flight operation to clear, then sends the verb inline; returns false
    /// when the pause/resume could not be confirmed by the provider.
    func setRelayPausedAwaitable(_ paused: Bool) async -> Bool {
        var waited: Double = 0
        while busy, waited < 5 {
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            configurationStatus = try await relayPauseRequest(paused)
            return true
        } catch {
            configurationStatus = "操作失败：\(Self.safeCode(error))"
            return false
        }
    }

    private func relayPauseRequest(_ paused: Bool) async throws -> String {
        let manager = try await Self.requireManager()
        guard manager.connection.status == .connected else {
            throw FlowProbeControlError.probeNotConnected
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw FlowProbeControlError.unsupportedSession
        }
        let verb = paused ? "relay-pause-v1" : "relay-resume-v1"
        guard let data = try await Self.sendProviderMessage(session, verb: verb),
              !data.isEmpty, data.count <= 16_384,
              let report = try? JSONDecoder().decode(ExternalFlowProbeReport.self, from: data).validated() else {
            throw FlowProbeControlError.providerMessageFailed
        }
        return report.relayPaused == paused
            ? (paused ? "DIRECT relay 已暂停：匹配的 TCP/UDP flow 将被关闭而非直连，未匹配 flow 不变；重启探针会清除暂停。"
                      : "DIRECT relay 已恢复：匹配的 TCP/UDP flow 继续经物理接口直连。")
            : "暂停状态与预期不一致（relayPaused=\(report.relayPaused)）；请重新发布报告核对。"
    }

    private static func sendProviderMessage(_ session: NETunnelProviderSession, verb: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(verb.utf8)) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor [self] in
            defer { busy = false }
            do { try await work() }
            catch { configurationStatus = "操作失败：\(Self.safeCode(error))" }
        }
    }

    private static func providerReportAttempt(_ manager: NETransparentProxyManager) async -> (String, ExternalFlowProbeReport?) {
        guard manager.connection.status == .connected else { return ("not_connected", nil) }
        guard let session = manager.connection as? NETunnelProviderSession else {
            return ("unsupported_session", nil)
        }
        let data: Data?
        do {
            data = try await sendProviderMessage(session, verb: "probe-report-v1")
        } catch {
            return ("send_failed", nil)
        }
        guard let data, !data.isEmpty, data.count <= 16_384 else {
            return ("no_response", nil)
        }
        do {
            let report = try JSONDecoder().decode(ExternalFlowProbeReport.self, from: data).validated()
            return ("pass", report)
        } catch {
            return ("invalid_response", nil)
        }
    }

    private static func statusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    private static func requireManager() async throws -> NETransparentProxyManager {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        guard let manager = managers.first(where: { bundleIdentifier($0) == extensionID }) else {
            throw FlowProbeControlError.configurationMissing
        }
        return manager
    }
    private static func bundleIdentifier(_ manager: NETransparentProxyManager) -> String? {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
    }
    private static func connectionSummary(_ manager: NETransparentProxyManager) -> String {
        "enabled=\(manager.isEnabled) connection=\(manager.connection.status.rawValue)"
    }
    nonisolated private static func safeCode(_ error: any Error) -> String {
        if let own = error as? FlowProbeControlError { return own.rawValue }
        let value = error as NSError
        return "\(value.domain)#\(value.code)"
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor [weak self] in
            self?.extensionStatus = "需要用户在系统设置中批准 Network Extension。"
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor [weak self] in
            self?.busy = false
            self?.extensionStatus = result == .completed
                ? "System Extension 已激活。下一步可显式保存探针配置。"
                : "System Extension 请求完成，但需要重启后才完全生效。"
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let code = Self.safeCode(error)
        Task { @MainActor [weak self, code] in
            self?.busy = false
            self?.extensionStatus = "System Extension 激活失败：" + code
        }
    }
}

enum FlowProbeControlError: String, Error {
    case configurationMissing
    case probeNotConnected
    case unsupportedSession
    case providerMessageFailed
}
