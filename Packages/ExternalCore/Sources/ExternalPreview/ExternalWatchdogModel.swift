// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import ExternalCore

struct ExternalWatchdogEventRecord: Identifiable, Sendable {
    let id = UUID()
    let event: ExternalWatchdogEvent
    let uptime: TimeInterval
}

/// Read-only third-party VPN health monitor. Polls with the same fixed read-only
/// collector as a manual detect; never applies rules, writes routes/DNS, talks to
/// the Helper or persists anything. Started and stopped only by explicit clicks.
@MainActor
final class ExternalWatchdogModel: ObservableObject {
    static let pollIntervalSeconds: Double = 3
    static let maximumEvents = 50
    @Published private(set) var running = false
    @Published private(set) var health: ExternalVPNHealth?
    @Published private(set) var events: [ExternalWatchdogEventRecord] = []
    @Published private(set) var message = "未监测。开始后用与「检测网络」相同的只读采集按固定间隔观察；不修改路由、DNS 或原 VPN。"
    private let reader = ExternalSystemReader()
    private var tracker = ExternalWatchdogTracker()
    private var loop: Task<Void, Never>?

    var healthTitle: String {
        guard let health else { return "未监测" }
        switch health {
        case .online: return "形态可识别"
        case .unavailable: return "形态不可识别"
        }
    }
    var healthDetail: String {
        guard let health else { return running ? "正在取得首张快照…" : "监测未启动" }
        switch health {
        case .online(let topology):
            return "物理 \(topology.physicalInterface) → \(topology.physicalGateway)；隧道 \(topology.tunnelInterface)（\(topology.pattern.rawValue)）。仅形态判定，不代表厂商/加密/端点已验证。"
        case .unavailable(let error):
            return error.message + "（" + error.rawValue + "）"
        }
    }
    func eventSummary(_ event: ExternalWatchdogEvent) -> String {
        switch event {
        case .initialOnline: return "开始监测：路由形态可识别"
        case .initialUnavailable: return "开始监测：当前形态不可识别"
        case .vpnDisconnected: return "第三方 VPN 的隧道路由形态消失；分流语义可能已失效，建议核查"
        case .physicalPathLost: return "物理网络路径丢失或出现多条候选；可能是断网或切网"
        case .observationFailed: return "本轮只读采集失败；未对 VPN 状态下结论"
        case .topologyBecameUnsupported: return "默认路由形态不再满足支持的判定；建议核查"
        case .vpnReconnected: return "路由形态恢复可识别（可能已换隧道接口）；建议重新检测并预览"
        case .tunnelInterfaceChanged: return "隧道接口已更换（VPN 重连迹象）；已有预览/分流假设可能失效"
        case .physicalPathChanged: return "物理网络已切换（网关/接口变化）；已有预览/分流假设可能失效"
        case .routingPatternChanged: return "全局路由形态变化（split/replaced 切换）"
        }
    }

    func start() {
        guard loop == nil else { return }
        tracker = ExternalWatchdogTracker()
        health = nil; events = []
        running = true
        message = "监测中：每 \(Int(Self.pollIntervalSeconds)) 秒只读采集一次；不修改网络，停止或退出即结束。"
        loop = Task { @MainActor [self] in
            while !Task.isCancelled {
                await poll()
                do { try await Task.sleep(for: .seconds(Self.pollIntervalSeconds)) } catch { break }
            }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        running = false
        message = "监测已停止；未修改网络，事件只保留在本窗口内存。"
    }

    private func poll() async {
        do {
            let observation = try await reader.capture()
            record(tracker.ingest(observation))
            health = tracker.health
        } catch {
            let failure = (error as? ExternalRouteParseDiagnostic)?.code ?? (error as? ExternalError ?? .readFailed)
            record(tracker.ingestFailure(failure))
            health = tracker.health
        }
    }

    private func record(_ event: ExternalWatchdogEvent?) {
        guard let event else { return }
        events.insert(ExternalWatchdogEventRecord(event: event, uptime: ProcessInfo.processInfo.systemUptime), at: 0)
        if events.count > Self.maximumEvents { events.removeLast(events.count - Self.maximumEvents) }
        message = eventSummary(event)
    }
}
#endif
