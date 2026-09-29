// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import SystemExtensions
import SwiftUI

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
            configurationStatus = matching.isEmpty ? "未保存 Transparent Proxy 配置" :
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
            configurationStatus = "探针配置已保存但未启用；没有启动 Transparent Proxy。"
        }
    }

    func startProbe() {
        perform {
            var manager = try Self.requireManager()
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                manager = try Self.requireManager()
            }
            try manager.connection.startVPNTunnel()
            configurationStatus = "已请求启动 TCP metadata 探针；provider 仍对所有 flow 返回 false。"
        }
    }

    func stopProbe() {
        perform {
            let manager = try Self.requireManager()
            manager.connection.stopVPNTunnel()
            configurationStatus = "已请求停止 metadata 探针；保留配置和 system extension 安装状态。"
        }
    }

    func removeProbeConfiguration() {
        perform {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            for manager in managers where Self.bundleIdentifier(manager) == Self.extensionID {
                manager.connection.stopVPNTunnel()
                try await manager.removeFromPreferences()
            }
            configurationStatus = "已移除本应用 Transparent Proxy 配置；未停用 system extension。"
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
    private static func safeCode(_ error: any Error) -> String {
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
        Task { @MainActor [weak self] in
            self?.busy = false
            self?.extensionStatus = "System Extension 激活失败：" + Self.safeCode(error)
        }
    }
}

enum FlowProbeControlError: String, Error {
    case configurationMissing
}
