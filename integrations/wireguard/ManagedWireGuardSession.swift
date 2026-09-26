// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import PolicyCore
import ManagedSettings
import ProviderSession
import WireGuardKit

/// One-use IN-PROCESS delivery; not an authorization proof or an IPC format.
/// A trusted source must verify the Keychain record's complete owner, reference and
/// metadata before constructing this object. No production shared-Keychain reader is
/// installed by this file. Swift/Go copies are not guaranteed to be zeroized.
@MainActor
public final class WireGuardConfigurationDelivery: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private let identity: ProviderSessionIdentity
    private var configuration: TunnelConfiguration?

    public init(verifiedFor identity: ProviderSessionIdentity, configuration: TunnelConfiguration) {
        self.identity = identity
        self.configuration = TunnelConfiguration(name: nil, interface: configuration.interface, peers: configuration.peers)
    }
    fileprivate func consume(for requested: ProviderSessionIdentity) throws -> TunnelConfiguration {
        // Even a wrong-owner request consumes/discards the delivery; no second chance.
        let snapshot = configuration; configuration = nil
        guard identity == requested, let snapshot else { throw ProviderSessionFailure.configurationRejected }
        return snapshot
    }
    public func discard() { configuration = nil }
    nonisolated public var description: String { "WireGuardConfigurationDelivery(<redacted>)" }
    nonisolated public var debugDescription: String { description }
    nonisolated public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Connects the tested controller to actual WireGuardAdapter start/stop, not a simulator.
/// Compiled in the isolated probe only; not an enabled or signed PacketTunnelProvider.
@MainActor
public final class ManagedWireGuardSession {
    public typealias CredentialLoader = @MainActor (ProviderSessionIdentity,
        @escaping @MainActor (Result<WireGuardConfigurationDelivery, ProviderSessionFailure>) -> Void) -> Void
    public let controller: ProviderSessionController
    private weak var provider: NEPacketTunnelProvider?
    private let policy: IPv4Policy
    private let underlay: IPv4ConstraintInput
    private let dnsSelection: WireGuardDNSSelection
    private let currentIdentity: @Sendable () -> ProviderSessionIdentity?
    private let descriptor: () throws -> SplitterTunnelDescriptorLease

    public init(provider: NEPacketTunnelProvider, identity: ProviderSessionIdentity,
                policy: IPv4Policy, underlay: IPv4ConstraintInput, dnsSelection: WireGuardDNSSelection,
                currentIdentity: @escaping @Sendable () -> ProviderSessionIdentity?,
                descriptor: @escaping () throws -> SplitterTunnelDescriptorLease,
                timeouts: ProviderSessionTimeouts,
                event: @escaping @MainActor (ProviderSessionEvent) -> Void) {
        self.provider = provider; self.policy = policy; self.underlay = underlay
        self.dnsSelection = dnsSelection; self.currentIdentity = currentIdentity; self.descriptor = descriptor
        controller = ProviderSessionController(identity: identity, currentIdentity: currentIdentity,
                                               timeouts: timeouts, event: event)
    }

    /// Call only after explicit runtime authorization. Keychain I/O belongs on the source's
    /// worker; its completion must return to MainActor. No raw config is sent in NE options,
    /// providerConfiguration, logs, JSON or application messages by this integration.
    public func start(credentials: CredentialLoader, completion: @escaping ProviderSessionController.Completion) {
        controller.start(load: { [weak self] identity, ready in
            var received = false // MainActor-confined, one source completion per attempt.
            credentials(identity) { [weak self] result in
                guard !received else {
                    if case .success(let unused) = result { unused.discard() }
                    return
                }
                received = true
                guard let self, let provider = self.provider,
                      self.controller.phase == .loading, self.currentIdentity() == identity else {
                    if case .success(let unused) = result { unused.discard() }
                    ready(.failure(.staleIdentity)); return
                }
                switch result {
                case .failure(let error): ready(.failure(error))
                case .success(let delivery):
                    do {
                        let snapshot = try delivery.consume(for: identity)
                        let live = self.currentIdentity
                        let revision = Self.revision(identity)
                        let assembly = try ManagedWireGuardAssembly.prepareForIntegration(
                            provider: provider, configuration: snapshot, policy: self.policy,
                            underlay: self.underlay, dnsSelection: self.dnsSelection, revision: revision,
                            currentRevision: {
                                guard live() == identity else { return nil }
                                return revision
                            }, descriptor: self.descriptor)
                        ready(.success(NativeBackend(identity: identity, configuration: snapshot, assembly: assembly)))
                    } catch {
                        delivery.discard()
                        ready(.failure(.configurationRejected)) // No raw framework/config errors cross this boundary.
                    }
                }
            }
        }, completion: completion)
    }

    private static func revision(_ id: ProviderSessionIdentity) -> SplitterRuntimeRevision {
        .init(providerInstance: id.provider, session: id.session, generation: id.generation,
              networkEpoch: id.networkEpoch, credentialBinding: id.credential)
    }

    private final class NativeBackend: PreparedProviderBackend {
        let identity: ProviderSessionIdentity
        private var configuration: TunnelConfiguration?
        private var assembly: ManagedWireGuardAssembly?
        private var startSubmitted = false
        private var stopSubmitted = false

        init(identity: ProviderSessionIdentity, configuration: TunnelConfiguration, assembly: ManagedWireGuardAssembly) {
            self.identity = identity; self.configuration = configuration; self.assembly = assembly
        }
        func start(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
            guard !startSubmitted, let configuration, let assembly else {
                completion(.failure(.invalidState)); return
            }
            startSubmitted = true
            assembly.adapter.start(tunnelConfiguration: configuration) { error in
                completion(error == nil ? .success(()) : .failure(.backendStart))
            }
            self.configuration = nil // Adapter owns its own immutable binding and queued input.
        }
        func invalidate() { assembly?.binding.invalidate() }
        func stop(completion: @escaping @Sendable (Result<Void, ProviderSessionFailure>) -> Void) {
            guard startSubmitted, !stopSubmitted, let assembly else {
                completion(.failure(.backendStop)); return
            }
            stopSubmitted = true
            assembly.adapter.stop { [weak self] error in
                let succeeded = error == nil
                Task { @MainActor in
                    // Do not map providerResetRequired/invalidState to a fake clean stop.
                    if succeeded { self?.assembly = nil; self?.configuration = nil }
                    completion(succeeded ? .success(()) : .failure(.backendStop))
                }
            }
        }
        func discard() {
            guard !startSubmitted else { return }
            invalidate(); configuration = nil; assembly = nil
        }
    }
}
