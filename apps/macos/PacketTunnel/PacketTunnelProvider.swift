// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import PolicyCore
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let log = Logger(subsystem: "io.github.xiaodou997.VPNSplitter.S1", category: "packet-tunnel")
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard (options?["S1SmokeTest"] as? NSNumber)?.boolValue == true,
              let raw = options?["S1Attempt"] as? String, let attempt = UUID(uuidString: raw) else {
            completionHandler(NSError(domain: "VPNSplitter.S1", code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Only the explicit S1 smoke test is supported."]))
            return
        }
        // Exercise the local package linkage without creating network settings or reading packets.
        guard (try? IPv4CIDR("198.51.100.7/24"))?.description == "198.51.100.0/24" else {
            completionHandler(NSError(domain: "VPNSplitter.S1", code: 1003))
            return
        }
        Self.log.notice("S1_PROVIDER_REACHED attempt=\(attempt.uuidString, privacy: .public) backend=NOT_IMPLEMENTED network_settings=NOT_APPLIED")
        completionHandler(NSError(domain: "VPNSplitter.S1", code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "S1 provider reached; protocol backend intentionally not implemented."]))
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.log.notice("S1_PROVIDER_STOPPED")
        completionHandler()
    }
}
