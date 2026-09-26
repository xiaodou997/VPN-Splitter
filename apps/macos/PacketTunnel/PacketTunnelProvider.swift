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
        let launch: CheckedManagedLaunch
        #if os(macOS)
        var ownerUID: UInt32?
        #endif
        do {
            guard let configuration = protocolConfiguration as? NETunnelProviderProtocol,
                  let providerID = Bundle.main.bundleIdentifier else {
                throw ManagedLaunchError.invalidContainer
            }
            launch = try ManagedLaunchContract.check(
                providerBundleIdentifier: configuration.providerBundleIdentifier,
                expectedProviderBundleIdentifier: providerID,
                providerConfiguration: configuration.providerConfiguration,
                passwordReference: configuration.passwordReference, options: options)
            #if os(macOS)
            if let text = configuration.username, text.utf8.count <= 10,
               let uid = UInt32(text), uid > 0, String(uid) == text { ownerUID = uid }
            #endif
        } catch {
            Self.log.notice("MANAGED_START_REJECTED network_settings=NOT_APPLIED")
            completionHandler(NSError(domain: "VPNSplitter.Managed", code: 2002,
                userInfo: [NSLocalizedDescriptionKey: "Managed launch metadata is invalid or does not match the saved profile."]))
            return
        }
        #if os(macOS)
        let reply = ManagedProviderCompletion(completionHandler)
        let requestedUID = ownerUID
        Task { @MainActor in
            do {
                guard let ownerUID = requestedUID, let runtime = ManagedExtensionRuntime.shared else {
                    throw ManagedTransferError.deliveryMissing
                }
                let received = try runtime.consume(launch, ownerUID: ownerUID)
                // Authentication and semantic admission are separate. Validate actual bytes
                // here even when an older/signed App claims it already checked its input.
                Self.log.notice("MANAGED_CREDENTIAL_DELIVERY_CONSUMED attempt=\(launch.request.attemptID.uuidString, privacy: .public) backend=NOT_CONNECTED network_settings=NOT_APPLIED")
                let checked = try received.withContents {
                    try ManagedWireGuardInput.prepare(configuration: $0, policyArchive: $1)
                }
                _ = checked // Typed source + policy; NOT native conversion or an installable plan.
                Self.log.notice("MANAGED_INPUT_VALIDATED attempt=\(launch.request.attemptID.uuidString, privacy: .public) network_settings=NOT_APPLIED")
                reply.finish(NSError(domain: "VPNSplitter.Managed", code: 2001,
                    userInfo: [NSLocalizedDescriptionKey: "Authenticated material passed configuration and policy checks. Native WireGuard runtime is not installed; no VPN was started."]))
            } catch let error as ManagedWireGuardInputError {
                Self.log.notice("MANAGED_INPUT_REJECTED attempt=\(launch.request.attemptID.uuidString, privacy: .public) code=\(error.rawValue, privacy: .public) network_settings=NOT_APPLIED")
                reply.finish(NSError(domain: "VPNSplitter.Managed", code: 2004,
                    userInfo: [NSLocalizedDescriptionKey: error.message]))
            } catch {
                Self.log.notice("MANAGED_CREDENTIAL_DELIVERY_REJECTED network_settings=NOT_APPLIED")
                reply.finish(NSError(domain: "VPNSplitter.Managed", code: 2003,
                    userInfo: [NSLocalizedDescriptionKey: "A matching, live authenticated credential delivery is required. No VPN was started."]))
            }
        }
        #else
        // Existing Linux framework-double harness covers metadata only, NOT native XPC.
        _ = launch
        Self.log.notice("MANAGED_METADATA_VALIDATED backend=NOT_CONNECTED network_settings=NOT_APPLIED")
        completionHandler(NSError(domain: "VPNSplitter.Managed", code: 2001,
            userInfo: [NSLocalizedDescriptionKey: "Native credential delivery is unavailable on this platform."]))
        #endif
    }
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        #if os(macOS)
        let reply = ManagedProviderCompletion { _ in completionHandler() }
        Task { @MainActor in
            ManagedExtensionRuntime.shared?.discard()
            Self.log.notice("S1_PROVIDER_STOPPED network_restore=NOT_OBSERVED")
            reply.finish(nil)
        }
        #else
        Self.log.notice("S1_PROVIDER_STOPPED")
        completionHandler()
        #endif
    }
}

#if os(macOS)
// Framework completion is deliberately transferred to MainActor and invoked once.
private final class ManagedProviderCompletion: @unchecked Sendable {
    private let callback: (Error?) -> Void
    @MainActor private var finished = false
    init(_ callback: @escaping (Error?) -> Void) { self.callback = callback }
    @MainActor func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true; callback(error)
    }
}
#endif
