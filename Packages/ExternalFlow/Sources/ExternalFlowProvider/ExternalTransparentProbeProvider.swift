// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Network
import NetworkExtension
import ExternalFlowCore
import ExternalFlowWire

final class ProbeCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var report = ExternalFlowProbeReport()
    func record(_ flow: NEAppProxyFlow) {
        lock.lock(); defer { lock.unlock() }
        report.total += 1
        if flow is NEAppProxyTCPFlow { report.tcp += 1 }
        if flow is NEAppProxyUDPFlow { report.udp += 1 }
        if !flow.metaData.sourceAppSigningIdentifier.isEmpty { report.withSourceSigningIdentifier += 1 }
        if flow.remoteHostname != nil { report.withRemoteHostname += 1 }
        if flow is NEAppProxyTCPFlow { report.withRemoteEndpoint += 1 }
    }
    func recordRulesLoaded(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        report.rulesLoaded = count
        report.rulesRejected = 0
    }
    func recordRulesRejected() {
        lock.lock(); defer { lock.unlock() }
        report.rulesLoaded = 0
        report.rulesRejected += 1
    }
    func recordRelayRefusedInterface() { lock.lock(); report.relayRefusedInterface += 1; lock.unlock() }
    func recordRelayRefusedLimit() { lock.lock(); report.relayRefusedLimit += 1; lock.unlock() }
    func recordRelayRefusedPaused() { lock.lock(); report.relayRefusedPaused += 1; lock.unlock() }
    func recordRelayUDPRefusedLimit() { lock.lock(); report.relayUDPRefusedLimit += 1; lock.unlock() }
    func recordRelayStarted() {
        lock.lock(); report.relayStarted += 1; report.relayActive += 1; lock.unlock()
    }
    func recordRelayEnded(_ outcome: ExternalFlowRelayOutcome) {
        lock.lock(); defer { lock.unlock() }
        report.relayActive = max(0, report.relayActive - 1)
        switch outcome {
        case .completed: report.relayCompleted += 1
        case .failed: report.relayFailed += 1
        case .cancelled: report.relayCancelled += 1
        }
    }
    func recordRelayUDPStarted() {
        lock.lock(); report.relayUDPStarted += 1; report.relayUDPActive += 1; lock.unlock()
    }
    func recordRelayUDPEnded(_ outcome: ExternalFlowRelayOutcome) {
        lock.lock(); defer { lock.unlock() }
        report.relayUDPActive = max(0, report.relayUDPActive - 1)
        switch outcome {
        case .completed: report.relayUDPCompleted += 1
        case .failed: report.relayUDPFailed += 1
        case .cancelled: report.relayUDPCancelled += 1
        }
    }
    func snapshot() -> ExternalFlowProbeReport { lock.lock(); defer { lock.unlock() }; return report }
}

/// Transparent proxy provider. Without a valid DIRECT rules entry in
/// providerConfiguration it stays a pure pass-through probe (FLOW-01): it
/// counts metadata and returns false for every flow. With valid rules, TCP
/// flows matching a DIRECT rule are relayed by ExternalFlowRelayEngine over a
/// provider-owned connection bound to the physical interface (FLOW-02), and
/// UDP flows matching an APPLICATION/DOMAIN-class rule are relayed as an
/// endpoint-keyed bounded NAT (FLOW-03); unmatched flows still return false.
/// While paused via provider message (ADR-EX-INT-08), matched flows are closed
/// instead of relayed.
public final class ExternalTransparentProbeProvider: NETransparentProxyProvider {
    private let counters = ProbeCounters()
    private let engine = ExternalFlowRelayEngine()

    public override func startProxy(options: [String : Any]? = nil,
                                    completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        engine.start(policy: Self.loadPolicy(from: protocolConfiguration, counters: counters))
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                          localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .TCP, direction: .outbound),
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                          localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .UDP, direction: .outbound)
        ]
        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    public override func stopProxy(with reason: NEProviderStopReason,
                                   completionHandler: @escaping () -> Void) {
        engine.stop()
        completionHandler()
    }

    public override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        counters.record(flow)
        if let tcp = flow as? NEAppProxyTCPFlow { return engine.handle(tcp, counters: counters) }
        if let udp = flow as? NEAppProxyUDPFlow { return engine.handle(udp, counters: counters) }
        return false
    }

    /// Bounded message surface (ADR-EX-INT-08): a read-only counters report
    /// plus two parameterless relay pause/resume verbs. Pause is runtime-only
    /// and never persists; unknown messages get no response.
    public override func handleAppMessage(_ messageData: Data,
                                          completionHandler: ((Data?) -> Void)? = nil) {
        switch messageData {
        case Data("probe-report-v1".utf8):
            completionHandler?(try? JSONEncoder().encode(currentReport()))
        case Data("relay-pause-v1".utf8):
            engine.setPaused(true)
            completionHandler?(try? JSONEncoder().encode(currentReport()))
        case Data("relay-resume-v1".utf8):
            engine.setPaused(false)
            completionHandler?(try? JSONEncoder().encode(currentReport()))
        default:
            completionHandler?(nil)
        }
    }

    private func currentReport() -> ExternalFlowProbeReport {
        var report = counters.snapshot()
        report.relayPaused = engine.isPaused
        return report
    }

    private static func loadPolicy(from configuration: NEVPNProtocol?,
                                   counters: ProbeCounters) -> ExternalFlowPolicy? {
        guard let data = (configuration as? NETunnelProviderProtocol)?
            .providerConfiguration?["VPNSplitterFlowRules"] as? Data, !data.isEmpty else { return nil }
        do {
            let wire = try JSONDecoder().decode(ExternalFlowRulesWire.self, from: data)
            let policy = try ExternalFlowPolicy(rulesWire: wire)
            counters.recordRulesLoaded(wire.rules.count)
            return policy
        } catch {
            counters.recordRulesRejected()
            return nil
        }
    }
}
#else
public enum ExternalTransparentProbeProviderUnavailable {}
#endif
