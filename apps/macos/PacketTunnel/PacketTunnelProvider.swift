// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import PolicyCore
import ProviderConfiguration
import os

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    static let log = Logger(subsystem: "io.github.xiaodou997.VPNSplitter.S1", category: "packet-tunnel")
    #if VPNSPLITTER_PACKET_FLOW_RUNTIME
    @MainActor private var flowSession: ManagedPacketFlowSession?
    #endif
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
                  let providerID = Bundle.main.bundleIdentifier else { throw ManagedLaunchError.invalidContainer }
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
                #if VPNSPLITTER_PACKET_FLOW_RUNTIME
                guard self.flowSession == nil else {
                    reply.finish(NSError(domain: "VPNSplitter.Runtime", code: 2010)); return
                }
                #endif
                guard let ownerUID = requestedUID, let runtime = ManagedExtensionRuntime.shared else {
                    throw ManagedTransferError.deliveryMissing
                }
                let received = try runtime.consume(launch, ownerUID: ownerUID)
                let admitted: CheckedManagedWireGuardInput
                do {
                    admitted = try received.material.withContents {
                        try ManagedWireGuardInput.prepare(configuration: $0, policyArchive: $1)
                    }
                } catch {
                    #if VPNSPLITTER_PACKET_FLOW_RUNTIME
                    runtime.finishRun(launch.request.attemptID)
                    #endif
                    Self.log.notice("MANAGED_MATERIAL_REJECTED network_settings=NOT_APPLIED")
                    reply.finish(NSError(domain: "VPNSplitter.Managed", code: 2004,
                        userInfo: [NSLocalizedDescriptionKey: "WireGuard configuration or policy was rejected. No VPN was started."]))
                    return
                }
                #if VPNSPLITTER_PACKET_FLOW_RUNTIME
                if received.purpose == .run {
                    do {
                        let session = try ManagedPacketFlowSession.make(provider: self, input: admitted, received: received,
                            event: { value in Self.log.notice("WG_RUNTIME event=\(value, privacy: .public)") })
                        self.flowSession = session
                        session.start { result in
                            switch result {
                            case .success:
                                Self.log.notice("WG_RUNTIME_ENGINE_READY attempt=\(launch.request.attemptID.uuidString, privacy: .public) handshake=NOT_VERIFIED")
                                reply.finish(nil)
                            case .failure:
                                reply.finish(NSError(domain: "VPNSplitter.Runtime", code: 2011,
                                    userInfo: [NSLocalizedDescriptionKey: "WireGuard startup failed or was cancelled. System recovery must be checked independently."]))
                            }
                        }
                    } catch {
                        received.authorization?.invalidate(); runtime.finishRun(launch.request.attemptID)
                        reply.finish(NSError(domain: "VPNSplitter.Runtime", code: 2010,
                            userInfo: [NSLocalizedDescriptionKey: "Another runtime attempt is active or authorization is unavailable."]))
                    }
                    return
                }
                #endif
                _ = admitted
                Self.log.notice("MANAGED_CREDENTIAL_DELIVERY_CONSUMED attempt=\(launch.request.attemptID.uuidString, privacy: .public) backend=NOT_CONNECTED network_settings=NOT_APPLIED")
                reply.finish(NSError(domain: "VPNSplitter.Managed", code: 2001,
                    userInfo: [NSLocalizedDescriptionKey: "Credential check completed without starting VPN. Explicit runtime consent and the integrated build are required to connect."]))
            } catch {
                Self.log.notice("MANAGED_CREDENTIAL_DELIVERY_REJECTED network_settings=NOT_APPLIED")
                reply.finish(NSError(domain: "VPNSplitter.Managed", code: 2003,
                    userInfo: [NSLocalizedDescriptionKey: "A matching, live authenticated credential delivery is required. No VPN was started."]))
            }
        }
        #else
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
            #if VPNSPLITTER_PACKET_FLOW_RUNTIME
            if let session = self.flowSession {
                session.stop { result in
                    if case .failure = result { Self.log.notice("WG_RUNTIME_STOP cleanup=UNCONFIRMED network_restore=NOT_OBSERVED") }
                    else if self.flowSession === session { self.flowSession = nil }
                    reply.finish(nil)
                }
                return
            }
            #endif
            Self.log.notice("S1_PROVIDER_STOPPED network_restore=NOT_OBSERVED")
            reply.finish(nil)
        }
        #else
        Self.log.notice("S1_PROVIDER_STOPPED")
        completionHandler()
        #endif
    }
    #if VPNSPLITTER_PACKET_FLOW_RUNTIME
    override func sleep(completionHandler: @escaping () -> Void) {
        // No sleep/wake roaming is promised: invalidate and stop; wake never reconnects.
        let reply = ManagedProviderCompletion { _ in completionHandler() }
        Task { @MainActor in
            self.cancelTunnelWithError(NSError(domain: "VPNSplitter.Runtime", code: 2012,
                userInfo: [NSLocalizedDescriptionKey: "Stopped for sleep; reconnect explicitly after waking."]))
            if let session = self.flowSession { session.stop { _ in reply.finish(nil) } }
            else { reply.finish(nil) }
        }
    }
    #endif
}

#if os(macOS)
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
