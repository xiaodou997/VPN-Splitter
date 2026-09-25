// SPDX-License-Identifier: MIT
import AppKit
import Combine
@preconcurrency import NetworkExtension
@preconcurrency import SystemExtensions

/// All system mutations require a button press. Only this spike's profile is managed.
@MainActor
final class SpikeController: NSObject, ObservableObject, @preconcurrency OSSystemExtensionRequestDelegate {
    @Published var extensionStatus = "扩展状态：尚未请求激活"
    @Published var profileStatus = "测试配置：尚未读取"
    @Published var message = "先完成签名检查，将 App 复制到 /Applications 后再激活。"
    @Published var confirmed = false
    @Published var busy = false
    private var manager: NETunnelProviderManager?
    private var pendingRequest: OSSystemExtensionRequest?
    private let ownerKey = "VPN-Splitter.S1.owner"
    private let ownerValue = "signing-smoke-v1"
    private var extensionID: String? {
        Bundle.main.object(forInfoDictionaryKey: "VPNExtensionBundleIdentifier") as? String
    }
    private func requireInstalled() throws {
        let url = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().path == "/Applications", extensionID != nil else {
            throw SpikeError.notInstalled
        }
    }
    private func report(_ error: Error) {
        let e = error as NSError
        message = "操作未完成：\(e.domain) / \(e.code)。请查看本地构建文档；不要关闭系统保护。"
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() } catch { report(error) }
        }
    }
    private func ownProfile() async throws -> NETunnelProviderManager? {
        guard let id = extensionID else { throw SpikeError.invalidConfiguration }
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let matches = all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == id }
        guard matches.count <= 1 else { throw SpikeError.ambiguousProfile }
        if let found = matches.first {
            let config = found.protocolConfiguration as? NETunnelProviderProtocol
            guard config?.providerConfiguration?[ownerKey] as? String == ownerValue else {
                throw SpikeError.foreignProfile
            }
        }
        return matches.first
    }
    func refresh() {
        perform {
            self.manager = try await self.ownProfile()
            self.profileStatus = self.manager.map { "本测试配置：NEVPNStatus=\($0.connection.status.rawValue)（不是分流证明）" } ?? "没有本测试配置"
        }
    }
    func saveProfile() {
        perform {
            try self.requireInstalled()
            let m = try await self.ownProfile() ?? NETunnelProviderManager()
            guard m.connection.status == .invalid || m.connection.status == .disconnected else {
                throw SpikeError.sessionActive
            }
            let p = NETunnelProviderProtocol()
            p.providerBundleIdentifier = self.extensionID
            p.serverAddress = "s1.invalid" // Placeholder only; the provider performs no connection.
            p.providerConfiguration = [self.ownerKey: self.ownerValue]
            p.includeAllNetworks = false
            p.enforceRoutes = false
            m.protocolConfiguration = p
            m.localizedDescription = "VPN-Splitter S1 · No traffic tunnel"
            m.isOnDemandEnabled = false
            m.onDemandRules = []
            m.isEnabled = true
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            self.manager = m
            self.profileStatus = "本测试配置已保存（尚未启动）"
            self.message = "下一步是受控启动失败测试，不会建立可用 VPN。"
        }
    }
    func startSmoke() {
        guard confirmed else { return }
        perform {
            try self.requireInstalled()
            guard let m = try await self.ownProfile() else { throw SpikeError.missingProfile }
            guard m.connection.status == .disconnected || m.connection.status == .invalid else {
                throw SpikeError.sessionActive
            }
            self.manager = m
            let attempt = UUID().uuidString
            self.message = "请求已发出，等待 Provider 日志。attempt=\(attempt)。预计返回未实现错误，不代表 VPN 已连接。"
            try m.connection.startVPNTunnel(options: ["S1SmokeTest": NSNumber(value: true), "S1Attempt": attempt as NSString])
        }
    }
    func stop() {
        perform {
            guard let m = try await self.ownProfile() else { return }
            m.connection.stopVPNTunnel()
            self.manager = m
            self.message = "已请求停止本测试会话；刷新状态确认。未操作其他 VPN。"
        }
    }
    func removeProfile() {
        perform {
            guard let m = try await self.ownProfile() else { self.profileStatus = "没有本测试配置"; return }
            guard m.connection.status == .disconnected || m.connection.status == .invalid else {
                throw SpikeError.sessionActive
            }
            try await m.removeFromPreferences()
            self.manager = nil
            self.profileStatus = "本测试配置已移除"
        }
    }
    func activate() { submitExtension(activation: true) }
    func deactivate() {
        perform {
            if let m = try await self.ownProfile(), m.connection.status != .invalid && m.connection.status != .disconnected {
                throw SpikeError.sessionActive
            }
            self.submitExtension(activation: false)
        }
    }
    private func submitExtension(activation: Bool) {
        guard pendingRequest == nil else { return }
        do {
            try requireInstalled()
            guard let id = extensionID else { throw SpikeError.invalidConfiguration }
            let request = activation
                ? OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: id, queue: .main)
                : OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: id, queue: .main)
            request.delegate = self
            pendingRequest = request
            extensionStatus = activation ? "扩展激活请求已提交" : "扩展停用请求已提交"
            OSSystemExtensionManager.shared.submitRequest(request)
        } catch { report(error) }
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        extensionStatus = "等待用户在系统设置中批准；批准前不算激活成功"
    }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        pendingRequest = nil
        extensionStatus = result == .completed ? "扩展请求完成（不代表隧道可用）" : "扩展请求需重启后完成"
    }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        pendingRequest = nil
        extensionStatus = "扩展请求失败"
        report(error)
    }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Do not silently replace a differently identified extension or downgrade a build.
        guard existing.bundleIdentifier == ext.bundleIdentifier,
              let old = Int(existing.bundleVersion), let new = Int(ext.bundleVersion), new >= old else { return .cancel }
        return .replace
    }
}
private enum SpikeError: Int, Error {
    case notInstalled = 1, invalidConfiguration, ambiguousProfile, foreignProfile, sessionActive, missingProfile
}
