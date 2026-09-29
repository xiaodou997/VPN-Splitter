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
            self.configurationStatus = "已请求启动 TCP metadata 探针；provider 仍对所有 flow 返回 false。"
        }
    }

    func stopProbe() {
        perform {
            let manager = try await Self.requireManager()
            manager.connection.stopVPNTunnel()
            self.configurationStatus = "已请求停止 metadata 探针；保留配置和 system extension 安装状态。"
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
                self.configurationStatus = "provider message=PASS；TCP \(report.tcp)，App ID 可见 \(report.withSourceSigningIdentifier)，hostname 可见 \(report.withRemoteHostname)。"
            } else {
                self.configurationStatus = "已发布配置/连接状态；provider message=" + (attempt.0 ?? "not_attempted") + "。"
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
            data = try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(Data("probe-report-v1".utf8)) { response in
                        continuation.resume(returning: response)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
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
}
