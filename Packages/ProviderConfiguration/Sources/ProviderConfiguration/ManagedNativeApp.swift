// SPDX-License-Identifier: MIT
#if os(macOS)
@preconcurrency import Foundation
@preconcurrency import NetworkExtension
import Darwin

// Foundation hands these objects to a callback; they are moved in this box to
// MainActor and used only there. They are not concurrently exposed to UI/other tasks.
private struct ManagedManagerResult: @unchecked Sendable {
    let values: [NETunnelProviderManager]
}

@MainActor
private final class ManagedSystemPreferences: ManagedPreferenceStore {
    let providerID: String
    let ownerUID: UInt32
    private var cached: NETunnelProviderManager?
    private var cachedHandle: ManagedCredentialHandle?
    private var pendingWrite: UUID?
    private var submitted: NETunnelProviderManager?
    init(providerID: String, ownerUID: UInt32) { self.providerID = providerID; self.ownerUID = ownerUID }

    func read() async throws -> ManagedCredentialHandle? {
        guard pendingWrite == nil else { throw ManagedTransferError.publicationUnconfirmed }
        let result: ManagedManagerResult = try await withCheckedThrowingContinuation { continuation in
            let reply = ManagedReply<ManagedManagerResult>(continuation)
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                let value = ManagedManagerResult(values: managers ?? [])
                let failed = error != nil || managers == nil
                Task { @MainActor in
                    reply.finish(failed ? .failure(ManagedTransferError.unavailable) : .success(value))
                }
            }
        }
        guard pendingWrite == nil else { throw ManagedTransferError.publicationUnconfirmed }
        let candidates = result.values.filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
        }
        guard candidates.count <= 1 else { throw ManagedTransferError.selectionChanged }
        guard let manager = candidates.first else { cached = nil; cachedHandle = nil; return nil }
        guard terminal(manager), !manager.isOnDemandEnabled, (manager.onDemandRules ?? []).isEmpty,
              manager.isEnabled,
              let p = manager.protocolConfiguration as? NETunnelProviderProtocol,
              p.username == String(ownerUID), !p.includeAllNetworks, !p.enforceRoutes,
              let fields = p.providerConfiguration, fields.count == 1,
              let descriptor = fields[ManagedLaunchContract.profileKey] as? [String: String],
              let reference = p.passwordReference else { throw ManagedTransferError.selectionChanged }
        // An old smoke/foreign profile is rejected, not overwritten or silently adopted.
        let profile = try ManagedProfileDescriptor(propertyList: descriptor)
        let handle = try ManagedCredentialHandle(profile: profile, ownerUID: ownerUID, persistentReference: reference)
        cached = manager; cachedHandle = handle
        return handle
    }
    func publish(_ new: ManagedCredentialHandle, replacing old: ManagedCredentialHandle?) async throws {
        guard new.ownerUID == ownerUID, try await read() == old else { throw ManagedTransferError.selectionChanged }
        let manager = cached ?? NETunnelProviderManager()
        guard terminal(manager) else { throw ManagedTransferError.busy }
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerID
        configuration.username = String(ownerUID) // Public owner binding, NOT an authentication claim.
        configuration.serverAddress = "managed.invalid" // Placeholder; this milestone does not connect.
        configuration.providerConfiguration = ManagedLaunchContract.providerConfiguration(for: new.profile)
        configuration.passwordReference = new.persistentReference
        configuration.includeAllNetworks = false; configuration.enforceRoutes = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "VPN-Splitter Managed · credential delivery check"
        manager.isEnabled = true; manager.isOnDemandEnabled = false; manager.onDemandRules = []
        let write = UUID(); pendingWrite = write
        // A timeout leaves pendingWrite set until the real callback settles. No read,
        // retry, or deletion can race a known in-flight system preference write.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = ManagedReply<Void>(continuation)
            manager.saveToPreferences { [weak self] error in
                let failed = error != nil
                Task { @MainActor in
                    if self?.pendingWrite == write { self?.pendingWrite = nil }
                    reply.finish(failed ? .failure(ManagedTransferError.publicationUnconfirmed) : .success(()))
                }
            }
        }
    }
    func submit(_ grant: ManagedDeliveryAuthorization) throws {
        guard pendingWrite == nil, cachedHandle == grant.handle, let manager = cached,
              terminal(manager), !manager.isOnDemandEnabled, (manager.onDemandRules ?? []).isEmpty,
              manager.isEnabled, let p = manager.protocolConfiguration as? NETunnelProviderProtocol,
              p.username == String(ownerUID), !p.includeAllNetworks, !p.enforceRoutes,
              let session = manager.connection as? NETunnelProviderSession else { throw ManagedTransferError.selectionChanged }
        let launch = try ManagedLaunchContract.check(providerBundleIdentifier: p.providerBundleIdentifier,
            expectedProviderBundleIdentifier: providerID, providerConfiguration: p.providerConfiguration,
            passwordReference: p.passwordReference, options: ManagedLaunchContract.startOptions(for: grant.request))
        try ManagedLaunchContract.checkExpectedReference(grant.handle.persistentReference, launch: launch)
        do { try session.startTunnel(options: ManagedLaunchContract.startOptions(for: grant.request)) }
        catch { throw ManagedTransferError.unavailable }
        submitted = manager // Submission success is not connection or handshake success.
    }
    func stopSubmitted() {
        submitted?.connection.stopVPNTunnel()
        submitted = nil // A stop request is not proof of system restoration.
    }
    private func terminal(_ manager: NETunnelProviderManager) -> Bool {
        manager.connection.status == .invalid || manager.connection.status == .disconnected
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ManagedClientSlot { var client: ManagedXPCClient? }

/// Formal App entry point used by the new explicit UI actions. Creating this object
/// checks signed role and takes the user-level writer lease; no Keychain/NE save occurs.
/// Saving does not activate an extension; delivery check requires separate user consent.
@available(macOS 26.0, *)
@MainActor
public final class ManagedAppWorkflow {
    private let identity: ManagedNativeIdentity
    private let lease: ManagedAppLease
    private let store: ManagedSystemPreferences
    private let transaction: ManagedSelectionTransaction
    private let slot: ManagedClientSlot
    private init(identity: ManagedNativeIdentity, lease: ManagedAppLease, vault: ManagedCredentialVault) {
        self.identity = identity; self.lease = lease
        let store = ManagedSystemPreferences(providerID: identity.peers.providerID, ownerUID: getuid())
        self.store = store
        let slot = ManagedClientSlot(); self.slot = slot
        transaction = ManagedSelectionTransaction(vault: vault, store: store, invalidateChannel: {
            slot.client?.close(); slot.client = nil
        })
    }
    public static func open() throws -> ManagedAppWorkflow {
        let identity = try ManagedNativeIdentity.current(provider: false)
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let lease = try ManagedAppLease(directory: base.appendingPathComponent(identity.peers.appID + ".managed", isDirectory: true), ownerUID: getuid())
        let vault = try ManagedCredentialVault.forContainingApp(expectedBundleIdentifier: identity.peers.appID)
        return ManagedAppWorkflow(identity: identity, lease: lease, vault: vault)
    }
    public var selectedGeneration: UInt64? { transaction.selected?.profile.generation }
    public var publicationUnconfirmed: Bool { transaction.publicationUnconfirmed }
    public func refresh() async throws { _ = try await transaction.refresh() }
    public func save(configuration: Data, policyArchive: Data) async throws {
        let material = try ManagedCredentialMaterial(configuration: configuration, policyArchive: policyArchive)
        _ = try await transaction.save(material)
    }
    /// Executes authenticated hello -> current-record Keychain read -> one-shot stage
    /// -> fresh preference check -> actual NE submission. Provider still rejects the
    /// missing engine after consuming/discarding the delivery. No secret in NE options.
    public func checkDelivery() async throws -> UUID {
        let grant = try await transaction.authorizeDelivery()
        let client = ManagedXPCClient(identity: identity)
        slot.client = client
        do {
            let challenge = try await client.hello(ownerUID: grant.handle.ownerUID)
            let material = try await transaction.material(for: grant)
            let envelope = try ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material)
            try await client.stage(envelope)
            try await transaction.validateForStart(grant)
            guard slot.client === client else { throw ManagedTransferError.cancelled }
            try store.submit(grant)
            // The server independently expires the connection and any unclaimed payload.
            Task { @MainActor [weak self, weak client] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                client?.close(); self?.transaction.finishDelivery(grant)
            }
            return grant.request.attemptID
        } catch {
            transaction.finishDelivery(grant); client.close()
            throw (error as? ManagedTransferError ?? .unavailable)
        }
    }
    public func cancel() { transaction.cancel(); store.stopSubmitted() }
}
#endif
