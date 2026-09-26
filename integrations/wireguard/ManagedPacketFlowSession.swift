// SPDX-License-Identifier: MIT
import Foundation
@preconcurrency import NetworkExtension
import PolicyCore
import ManagedSettings
import ManagedSettingsApple
import ProviderConfiguration
import ProviderSession
import WireGuardKit

/// One live epoch bound to the authenticated connection. This is not a network
/// observer: only ManagedUnderlayMonitor may admit its snapshot or revoke it.
private final class FlowEpoch: @unchecked Sendable {
    let identity: ProviderSessionIdentity
    let authorization: ManagedRunAuthorization
    private let lock = NSLock()
    private var valid = true
    init(identity: ProviderSessionIdentity, authorization: ManagedRunAuthorization) {
        self.identity = identity; self.authorization = authorization
    }
    func current() -> ProviderSessionIdentity? {
        lock.lock(); let permitted = valid; lock.unlock()
        return permitted && authorization.isCurrent() ? identity : nil
    }
    func invalidate() { lock.lock(); valid = false; lock.unlock(); authorization.invalidate() }
}

/// Owns the actual WG-INT-09 backend. All potentially blocking C/Go work is confined
/// to this worker; stop is queued only after start settles. No actor blocks on Go.
private final class FlowEngineWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vpnsplitter.flow-engine")
    private weak var provider: NEPacketTunnelProvider?
    private var configuration: TunnelConfiguration?
    private var backend: SplitterPacketFlowBackend?
    private let mtu: Int
    private let epoch: FlowEpoch
    private let failure: @Sendable () -> Void
    init(provider: NEPacketTunnelProvider, configuration: TunnelConfiguration, mtu: Int,
         epoch: FlowEpoch, failure: @escaping @Sendable () -> Void) {
        self.provider = provider; self.configuration = configuration
        self.mtu = mtu; self.epoch = epoch; self.failure = failure
    }
    func start(_ reply: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        queue.async { [self] in
            guard let provider, let configuration, epoch.current() != nil else {
                self.configuration = nil; reply(.failure(.staleIdentity)); return
            }
            defer { self.configuration = nil }
            do {
                backend = try SplitterPacketFlowBackend.start(provider: provider, configuration: configuration,
                    mtu: mtu, isCurrent: { [epoch] in epoch.current() != nil }, failure: { [failure] _ in failure() })
                reply(.success(()))
            } catch { reply(.failure(.backendStart)) }
        }
    }
    func stop(_ reply: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            backend?.stop(); backend = nil; configuration = nil; reply()
        }
    }
}

@MainActor
private final class FlowPreparedBackend: PreparedProviderBackend {
    let identity: ProviderSessionIdentity
    let epoch: FlowEpoch
    let settings: PacketFlowSettingsGate
    let worker: FlowEngineWorker
    let checkNetwork: () throws -> Void
    init(provider: NEPacketTunnelProvider, configuration: TunnelConfiguration, plan: PreparedWireGuardPlan,
         mtu: Int, epoch: FlowEpoch, checkNetwork: @escaping () throws -> Void,
         event: @escaping (String) -> Void, failed: @escaping @Sendable () -> Void) throws {
        identity = epoch.identity; self.epoch = epoch; self.checkNetwork = checkNetwork
        let settingsObject = try PacketTunnelSettingsFactory.makeForInspection(plan.settings, current: plan.settings.input)
        worker = FlowEngineWorker(provider: provider, configuration: configuration, mtu: mtu, epoch: epoch, failure: failed)
        settings = try PacketFlowSettingsGate(apply: { [weak provider] reply in
            guard epoch.current() != nil, (try? checkNetwork()) != nil, let provider else { reply(false); return }
            provider.setTunnelNetworkSettings(settingsObject) { error in reply(error == nil) }
        }, clear: { [weak provider] reply in
            guard let provider else { reply(false); return }
            provider.setTunnelNetworkSettings(nil) { error in reply(error == nil) }
        }, event: { event("settings_" + $0.rawValue) })
    }
    func start(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        settings.apply { [self] result in
            guard case .success = result else { completion(result); return }
            do {
                try checkNetwork()
                guard epoch.current() == identity else { throw ProviderSessionFailure.staleIdentity }
                worker.start(completion)
            } catch { completion(.failure(.staleIdentity)) }
        }
    }
    func invalidate() { epoch.invalidate(); settings.invalidate() }
    func stop(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
        worker.stop { [self] in Task { @MainActor in settings.remove { completion($0) } } }
    }
    func discard() { invalidate() } // A never-started worker has not opened sockets or read packets.
}

/// Installed only by the explicit integrated Provider build. This reuses WG-INT-07's
/// tested controller rather than introducing a second start/stop state machine.
/// Success means settings ACK + engine startup, NOT handshake or destination reachability.
@MainActor
final class ManagedPacketFlowSession {
    private static var retained: ManagedPacketFlowSession?
    private let monitor = ManagedUnderlayMonitor()
    private let epoch: FlowEpoch
    private weak var provider: NEPacketTunnelProvider?
    private let input: CheckedManagedWireGuardInput
    private let event: (String) -> Void
    private var watchdog: Task<Void, Never>?
    private var started = false
    private var controller: ProviderSessionController!

    private init(provider: NEPacketTunnelProvider, input: CheckedManagedWireGuardInput,
                 received: ManagedReceivedConfiguration, event: @escaping (String) -> Void) throws {
        guard received.purpose == .run, let authorization = received.authorization, authorization.isCurrent() else {
            throw ProviderSessionFailure.credentialUnavailable
        }
        self.provider = provider; self.input = input; self.event = event
        let p = received.request.profile
        let id = ProviderSessionIdentity(provider: UUID(), session: received.request.attemptID,
            profile: p.profileID, credential: p.credentialID, ownershipNonce: p.policyRevision,
            generation: p.generation, networkEpoch: 1)
        epoch = FlowEpoch(identity: id, authorization: authorization)
        controller = ProviderSessionController(identity: id, currentIdentity: { [epoch] in epoch.current() },
            timeouts: try .init(load: .seconds(8), start: .seconds(15), stop: .seconds(10)),
            event: { [weak self] in self?.handle($0) })
    }
    static func make(provider: NEPacketTunnelProvider, input: CheckedManagedWireGuardInput,
                     received: ManagedReceivedConfiguration, event: @escaping (String) -> Void) throws -> ManagedPacketFlowSession {
        guard retained == nil else { throw ProviderSessionFailure.invalidState }
        let session = try ManagedPacketFlowSession(provider: provider, input: input, received: received, event: event)
        retained = session // Retain pending native callbacks and block replacement on uncertainty.
        return session
    }
    func start(completion: @escaping ProviderSessionController.Completion) {
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                if self.epoch.current() == nil { self.invalidate(); return }
            }
        }
        controller.start(load: { [weak self] _, ready in
            guard let self else { ready(.failure(.invalidState)); return }
            self.monitor.start(initial: { [weak self] result in
                guard let self, let provider = self.provider, self.epoch.current() != nil else {
                    ready(.failure(.staleIdentity)); return
                }
                do {
                    let observed = try result.get()
                    let native = try ManagedWireGuardNativeInput(self.input)
                    let configuration = native.makeConfiguration()
                    let mtu = try observed.resolvedMTU(self.input.metadata.mtu)
                    let context = PlanContext(sessionID: self.epoch.identity.session.uuidString,
                        backendID: "wireguard", generation: self.epoch.identity.generation, networkEpoch: self.epoch.identity.networkEpoch)
                    let source = WireGuardPlanSource(addresses: configuration.interface.addresses.map(\.stringRepresentation),
                        dnsServers: [], searchDomains: [], mtu: mtu,
                        peers: configuration.peers.map { .init(endpoint: $0.endpoint?.stringRepresentation,
                                                                allowedIPs: $0.allowedIPs.map(\.stringRepresentation)) })
                    let plan = try PreparedWireGuardPlan.prepare(source: source, policy: native.policy, context: context,
                        underlay: observed.constraints(context: context), dnsSelection: .keepSystemExplicitly)
                    try self.monitor.checkNow()
                    let backend = try FlowPreparedBackend(provider: provider, configuration: configuration, plan: plan,
                        mtu: mtu, epoch: self.epoch, checkNetwork: { [monitor = self.monitor] in try monitor.checkNow() },
                        event: self.event, failed: { [weak self] in Task { @MainActor in self?.invalidate() } })
                    self.event("underlay_observed_epoch_1")
                    ready(.success(backend))
                } catch { ready(.failure(.configurationRejected)) }
            }, changed: { [weak self] in self?.invalidate() })
        }, completion: completion)
    }
    func stop(completion: @escaping ProviderSessionController.Completion) {
        epoch.invalidate(); monitor.stop(); watchdog?.cancel(); watchdog = nil
        controller.stop(completion: completion)
    }
    private func invalidate() {
        epoch.invalidate(); monitor.stop(); watchdog?.cancel(); watchdog = nil
        event("epoch_revoked_no_automatic_rebuild")
        controller.contextChanged()
    }
    private func handle(_ value: ProviderSessionEvent) {
        switch value {
        case .backendReady: started = true; event("engine_ready_handshake_unverified")
        case .failed(let reason):
            event("failed_" + reason.rawValue)
            if started || reason == .cleanupUnconfirmed {
                provider?.cancelTunnelWithError(NSError(domain: "VPNSplitter.Runtime", code: 2011,
                    userInfo: [NSLocalizedDescriptionKey: "Runtime stopped or cleanup is unconfirmed. No automatic reconnect."]))
            }
        case .backendQuiescent:
            epoch.invalidate(); monitor.stop(); watchdog?.cancel(); watchdog = nil
            ManagedExtensionRuntime.shared?.finishRun(epoch.identity.session)
            event("backend_quiescent_network_restore_NOT_OBSERVED")
            if Self.retained === self { Self.retained = nil }
        case .systemTeardownObserved:
            // No caller fabricates this event from a stop callback or nil-settings ACK.
            event("independent_system_teardown_observed")
        }
    }
}
