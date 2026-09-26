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
        configuration.serverAddress = "managed.invalid" // Display-only. The authenticated configuration supplies the real endpoint.
        configuration.providerConfiguration = ManagedLaunchContract.providerConfiguration(for: new.profile)
        configuration.passwordReference = new.persistentReference
        configuration.includeAllNetworks = false; configuration.enforceRoutes = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "VPN-Splitter Managed · IPv4 preview"
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
        // Keep the manager for status observation; a request is not restoration.
    }
    var submittedStatus: NEVPNStatus { submitted?.connection.status ?? .invalid }
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
        // Reject before Keychain preparation or preference publication, not just in UI.
        let checked = try ManagedWireGuardInput.prepare(configuration: configuration, policyArchive: policyArchive)
        let material = try checked.withValidatedSource {
            try ManagedCredentialMaterial(configuration: $0, policyArchive: $1)
        }
        _ = try await transaction.save(material)
    }
    public var runtimeAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "VPNPacketFlowRuntime") as? Bool == true }
    public var connectionStateText: String {
        switch store.submittedStatus {
        case .connected: return "系统报告已连接；握手与分流出口尚未验证"
        case .connecting: return "连接中：等待设置与引擎启动"
        case .disconnecting: return "断开中：不能视为系统已恢复"
        case .reasserting: return "系统重新协调中：本版本不会自动重连"
        default: return "未连接；路由与 DNS 恢复未独立核查"
        }
    }
    /// Old callers remain check-only. Only the distinct explicit action sends run-v2.
    public func checkDelivery() async throws -> UUID { try await deliver(purpose: .check) }
    public func connect() async throws -> UUID {
        guard runtimeAvailable else { throw ManagedTransferError.unavailable }
        return try await deliver(purpose: .run)
    }
    private func deliver(purpose: ManagedDeliveryPurpose) async throws -> UUID {
        let grant = try await transaction.authorizeDelivery()
        let client = ManagedXPCClient(identity: identity)
        slot.client = client
        do {
            let challenge = try await client.hello(ownerUID: grant.handle.ownerUID)
            let loaded = try await transaction.material(for: grant)
            // Old 08C records are rechecked; stored revisions are not semantic validation.
            let checked = try loaded.withContents {
                try ManagedWireGuardInput.prepare(configuration: $0, policyArchive: $1)
            }
            let material = try checked.withValidatedSource {
                try ManagedCredentialMaterial(configuration: $0, policyArchive: $1)
            }
            let envelope = try ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material, purpose: purpose)
            try await client.stage(envelope)
            try await transaction.validateForStart(grant)
            guard slot.client === client else { throw ManagedTransferError.cancelled }
            try store.submit(grant)
            // An unconsumed stage still expires server-side. A consumed run keeps the
            // authenticated channel until explicit cancel/exit or terminal system state.
            Task { @MainActor [weak self, weak client] in
                if purpose == .check {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                } else {
                    let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                    var sawActive = false
                    while let self, self.slot.client === client {
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                        let status = self.store.submittedStatus
                        if status != .invalid && status != .disconnected { sawActive = true }
                        if status == .invalid || status == .disconnected {
                            if sawActive || ContinuousClock.now >= deadline { break }
                        } else if status != .connected && ContinuousClock.now >= deadline { break }
                    }
                }
                client?.close(); self?.transaction.finishDelivery(grant)
            }
            return grant.request.attemptID
        } catch {
            transaction.finishDelivery(grant); client.close()
            if let admission = error as? ManagedWireGuardInputError { throw admission }
            throw (error as? ManagedTransferError ?? .unavailable)
        }
    }
    public func cancel() { transaction.cancel(); store.stopSubmitted() }
}
#endif
