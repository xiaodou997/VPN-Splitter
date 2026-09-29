// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Network
import NetworkExtension
import ExternalFlowCore

private final class ProbeCounters: @unchecked Sendable {
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
    func snapshot() -> ExternalFlowProbeReport { lock.lock(); defer { lock.unlock() }; return report }
}

/// FLOW-01 capability probe only. It never opens a replacement remote connection,
/// never copies bytes, and always returns false so transparent-proxy flows continue
/// to their original ultimate destination according to system networking.
@objc(ExternalTransparentProbeProvider)
public final class ExternalTransparentProbeProvider: NETransparentProxyProvider {
    private let counters = ProbeCounters()

    public override func startProxy(options: [String : Any]? = nil,
                                    completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.includedNetworkRules = [
            NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                          localNetworkEndpoint: nil, localPrefix: 0,
                          protocol: .any, direction: .outbound)
        ]
        setTunnelNetworkSettings(settings, completionHandler: completionHandler)
    }

    public override func stopProxy(with reason: NEProviderStopReason,
                                   completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    public override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        counters.record(flow)
        return false
    }

    public override func handleAppMessage(_ messageData: Data,
                                          completionHandler: ((Data?) -> Void)? = nil) {
        guard messageData == Data("probe-report-v1".utf8) else { completionHandler?(nil); return }
        completionHandler?(try? JSONEncoder().encode(counters.snapshot()))
    }
}
#else
public enum ExternalTransparentProbeProviderUnavailable {}
#endif
