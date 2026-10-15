// SPDX-License-Identifier: MIT
import Foundation
import Network
import PolicyCore
import ExternalCore
import ExternalFlowCore
import ExternalFlowWire

/// Isolation guard (ADR-EX-INT-09): explicit user toggle that watches the
/// third-party VPN and drives the provider's relay pause. Detection is the
/// same read-only capture as the preview watchdog plus an optional dual-path
/// bare-TCP probe; actuation is only the two existing provider verbs. Nothing
/// is persisted; stopping the app stops the guard. Never blocks system sleep.
@MainActor
final class FlowProbeGuard: ObservableObject {
    static let pollIntervalSeconds: Double = 4
    static let probeTimeoutSeconds: Double = 3
    static let defaultProbeTarget = "captive.apple.com:80"

    enum GuardError: String, Error {
        case invalidTarget = "探测目标格式无效：需要 host:port，端口 1–65535。"
        case targetMatchesDirectRule = "探测目标命中当前 DIRECT 规则，探针流量会被自己的 relay 暂停误伤；请更换目标。"
    }

    @Published var probeTarget = FlowProbeGuard.defaultProbeTarget
    @Published var probingEnabled = true
    @Published private(set) var running = false
    @Published private(set) var status = "未开启。开启后：VPN 断开或断流时自动暂停 DIRECT relay（匹配的 TCP 连接被关闭，不能访问网络），恢复后自动解除。"
    private weak var controller: FlowProbeController?
    private var tracker = ExternalWatchdogTracker()
    private var logic = ExternalFlowGuardLogic()
    private var loop: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.github.xiaodou997.VPNSplitter.FlowProbeGuard.Path")
    private var physicalInterface: NWInterface?

    init(controller: FlowProbeController) { self.controller = controller }

    func start() {
        guard loop == nil else { return }
        guard let target = Self.parseTarget(probeTarget) else {
            status = GuardError.invalidTarget.rawValue; return
        }
        tracker = ExternalWatchdogTracker(); logic = ExternalFlowGuardLogic()
        running = true
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "VPN isolation guard")
        startMonitor()
        status = "守卫运行中：只读观察路由形态\(probingEnabled ? " + 探测 VPN 路径" : "")；异常时自动暂停 relay。"
        let probing = probingEnabled
        loop = Task { @MainActor [self] in
            if probing, await targetHitsDirectRule(target) {
                status = GuardError.targetMatchesDirectRule.rawValue
                stop()
                return
            }
            while !Task.isCancelled {
                await tick(target: target, probing: probing)
                do { try await Task.sleep(for: .seconds(Self.pollIntervalSeconds)) } catch { break }
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        monitor.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        running = false
        status = "守卫已关闭；provider 维持当前暂停状态（重启探针会清除暂停）。"
    }

    private func tick(target: (host: NWEndpoint.Host, port: NWEndpoint.Port), probing: Bool) async {
        let observation: ExternalObservation
        do {
            observation = try await Task.detached { try ExternalSystemSnapshotReader().capture() }.value
        } catch {
            // Capture failure is not a VPN verdict; keep current state.
            status = "本轮只读采集失败；未对 VPN 状态下结论。"
            return
        }
        _ = tracker.ingest(observation)
        guard case .online(let topology) = tracker.health else {
            await apply(logic.onRouteForm(available: false), detail: "路由形态不可识别")
            return
        }
        await apply(logic.onRouteForm(available: true), detail: "路由形态在线")
        guard probing, logic.paused != .routeFormLost else { return }
        let vpnOK = await probe(target, interface: nil)
        let physicalOK = await probe(target, interface: physicalInterface)
        let verdict = vpnOK ? "VPN 路径可达" :
            (physicalOK ? "VPN 路径不可达但物理可达（疑似断流）" : "双路均不可达（本地断网或 VPN 断流）")
        await apply(logic.onProbe(vpnPathOK: vpnOK), detail: verdict)
    }

    private func apply(_ action: ExternalFlowGuardLogic.Action, detail: String) async {
        switch action {
        case .stay:
            status = "守卫运行中：\(detail)；relay \(logic.paused == nil ? "未暂停" : "已暂停（\(logic.paused!.rawValue)）")。"
        case .pauseRouteFormLost, .pauseVPNPathDead:
            let reason = action == .pauseRouteFormLost ? "VPN 路由形态消失" : "VPN 路径连续探测失败（假在线/断流）"
            if await controller?.setRelayPausedAwaitable(true) == true {
                status = "已自动暂停 DIRECT relay：\(reason)。匹配规则的连接现在无法访问网络；VPN 恢复后自动解除。"
            } else {
                logic.undoPause()
                status = "检测到\(reason)，但暂停指令未送达 provider（探针未连接或正忙）；下轮自动重试。"
            }
        case .resume:
            if await controller?.setRelayPausedAwaitable(false) == true {
                status = "VPN 已恢复，已自动解除 relay 暂停。"
            } else {
                logic.undoResume()
                status = "VPN 已恢复，但解除暂停未送达 provider；下轮自动重试。"
            }
        }
    }

    /// Bare TCP handshake probe: no bytes are sent, success = connection ready
    /// within the timeout. `interface == nil` follows the system default route
    /// (the VPN path while the VPN is up); otherwise binds the interface.
    private func probe(_ target: (host: NWEndpoint.Host, port: NWEndpoint.Port),
                       interface: NWInterface?) async -> Bool {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        let connection = NWConnection(host: target.host, port: target.port, using: parameters)
        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: connection.stateUpdateHandler = nil; continuation.resume(returning: true)
                        case .failed: connection.stateUpdateHandler = nil; continuation.resume(returning: false)
                        case .cancelled: connection.stateUpdateHandler = nil; continuation.resume(returning: false)
                        default: break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.probeTimeoutSeconds))
                connection.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        connection.cancel()
        return result
    }

    private func startMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            let physical = path.availableInterfaces.filter { $0.type == .wifi || $0.type == .wiredEthernet }
            let selected = physical.count == 1 ? physical[0] : nil
            Task { @MainActor [weak self] in self?.physicalInterface = selected }
        }
        monitor.start(queue: monitorQueue)
    }

    /// Refuse probe targets covered by the exported DIRECT rules: the proxy
    /// intercepts this app's own probes, and a paused relay would close them,
    /// faking a dead-VPN verdict.
    private func targetHitsDirectRule(_ target: (host: NWEndpoint.Host, port: NWEndpoint.Port)) async -> Bool {
        guard let store = try? ExternalFlowRulesBridgeStore.applicationStore(),
              let wire = try? await store.load(),
              let policy = try? ExternalFlowPolicy(rulesWire: wire) else { return false }
        var address: PolicyCore.IPv4Address?
        if case .ipv4(let value) = target.host { address = try? PolicyCore.IPv4Address(value.debugDescription) }
        let hostname: String?
        if case .name(let name, _) = target.host { hostname = name } else { hostname = nil }
        let descriptor = ExternalFlowDescriptor(sourceAppSigningIdentifier: nil,
                                                remoteHostname: hostname, destinationIPv4: address)
        if case .direct = policy.evaluate(descriptor) { return true }
        return false
    }

    static func parseTarget(_ text: String) -> (host: NWEndpoint.Host, port: NWEndpoint.Port)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[trimmed.startIndex..<colon])
        guard let port = UInt16(trimmed[trimmed.index(after: colon)...]), port > 0,
              !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                                     (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { return nil }
        let endpointHost: NWEndpoint.Host = Network.IPv4Address(host).map { .ipv4($0) } ?? .name(host, nil)
        return (endpointHost, NWEndpoint.Port(rawValue: port)!)
    }
}
