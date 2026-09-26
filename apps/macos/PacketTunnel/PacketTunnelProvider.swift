// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import PolicyCore
import ProviderConfiguration
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let log = Logger(subsystem: "io.github.xiaodou997.VPNSplitter.S1", category: "packet-tunnel")
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Route explicit Managed requests first so mixed smoke/Managed options cannot
        // skip the strict boundary. This branch is the actual extension entry, not a probe.
        if options?[ManagedLaunchContract.startKey] != nil {
            startManaged(options: options, completionHandler: completionHandler)
            return
        }
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
    private func startManaged(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
                  let providerID = Bundle.main.bundleIdentifier else {
                throw ManagedLaunchError.invalidContainer
            }
            _ = try ManagedLaunchContract.check(
                providerBundleIdentifier: configuration.providerBundleIdentifier,
                expectedProviderBundleIdentifier: providerID,
                providerConfiguration: configuration.providerConfiguration,
                passwordReference: configuration.passwordReference, options: options)
        } catch {
            Self.log.notice("MANAGED_START_REJECTED network_settings=NOT_APPLIED")
            completionHandler(NSError(domain: "VPNSplitter.Managed", code: 2002,
                userInfo: [NSLocalizedDescriptionKey: "Managed launch metadata is invalid or does not match the saved profile."]))
            return
        }
        // Metadata equality is NOT credential authorization. Do not install a fake
        // credential loader, guess a utun, or report connected to remove this gate.
        // Still required: authorized record resolution, runtime network identity,
        // owned packet channel, and ManagedWireGuardSession + teardown integration.
        Self.log.notice("MANAGED_METADATA_VALIDATED backend=NOT_CONNECTED network_settings=NOT_APPLIED")
        completionHandler(NSError(domain: "VPNSplitter.Managed", code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "Managed launch metadata validated; credential and tunnel runtime integration are not yet available. No VPN was started."]))
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Self.log.notice("S1_PROVIDER_STOPPED")
        completionHandler()
    }
}
