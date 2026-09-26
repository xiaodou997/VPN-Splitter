// SPDX-License-Identifier: MIT
import Foundation

public enum ManagedTransferError: String, Error, Sendable {
    case busy, cancelled, selectionChanged, selectionMissing, publicationUnconfirmed
    case cleanupUnconfirmed, unavailable, invalidIdentity, invalidMessage, expired
    case connectionClosed, replay, capacity, deliveryMissing
}

/// The native implementation serializes one user-owned NETunnelProviderManager.
/// read() must re-load system preferences and reject ambiguous/foreign/active profiles.
/// publish() must compare the fresh selection before saving; it is NOT an OS CAS API.
@MainActor
protocol ManagedPreferenceStore: AnyObject {
    func read() async throws -> ManagedCredentialHandle?
    func publish(_ new: ManagedCredentialHandle, replacing old: ManagedCredentialHandle?) async throws
}

/// Issued by the coordinator, never constructed from an IPC-supplied reference.
struct ManagedDeliveryAuthorization: Sendable {
    let id: UUID
    let handle: ManagedCredentialHandle
    let request: ManagedStartRequest
}

/// A single selected formal configuration, not LocalDev's workspace. The Keychain
/// record is immutable; preferences contain only its descriptor and opaque reference.
/// Older records are retained, not swept. A crash can leave an orphan, never an
/// authorization: only the subsequently re-loaded selected reference may be delivered.
@MainActor
final class ManagedSelectionTransaction {
    private let vault: ManagedCredentialVault
    private let store: any ManagedPreferenceStore
    private let invalidateChannel: @MainActor () -> Void
    private(set) var selected: ManagedCredentialHandle?
    private(set) var publicationUnconfirmed = false
    private var loaded = false
    private var busy = false
    private var cancellation = UUID()
    private var authorization: ManagedDeliveryAuthorization?
    private var materialWasRead = false

    init(vault: ManagedCredentialVault, store: any ManagedPreferenceStore,
         invalidateChannel: @escaping @MainActor () -> Void = {}) {
        self.vault = vault; self.store = store; self.invalidateChannel = invalidateChannel
    }

    func cancel() {
        cancellation = UUID()
        authorization = nil; materialWasRead = false
        invalidateChannel()
    }

    @discardableResult
    func refresh() async throws -> ManagedCredentialHandle? {
        guard !busy else { throw ManagedTransferError.busy }
        busy = true; defer { busy = false }
        cancel()
        let mark = cancellation
        do {
            let current = try await store.read()
            try check(mark)
            selected = current; loaded = true; publicationUnconfirmed = false
            return current
        } catch {
            loaded = false
            throw sanitized(error)
        }
    }

    @discardableResult
    func save(_ material: ManagedCredentialMaterial) async throws -> ManagedCredentialHandle {
        guard !busy else { throw ManagedTransferError.busy }
        guard loaded, !publicationUnconfirmed else { throw ManagedTransferError.selectionMissing }
        busy = true; defer { busy = false }
        cancel()
        let mark = cancellation
        let previous = selected
        var prepared: ManagedCredentialHandle?
        var submitted = false
        do {
            guard try await store.read() == previous else { throw ManagedTransferError.selectionChanged }
            try check(mark)
            guard (previous?.profile.generation ?? 0) < UInt64.max else { throw ManagedTransferError.capacity }
            let profile = try ManagedProfileDescriptor(
                profileID: previous?.profile.profileID ?? UUID(), credentialID: UUID(),
                policyRevision: UUID(), generation: (previous?.profile.generation ?? 0) + 1)
            let candidate = try await vault.prepare(profile: profile, material: material)
            prepared = candidate
            try check(mark)
            // A second read covers changes that arrived while Keychain work suspended.
            guard try await store.read() == previous else { throw ManagedTransferError.selectionChanged }
            try check(mark)
            submitted = true
            try await store.publish(candidate, replacing: previous)
            guard try await store.read() == candidate else { throw ManagedTransferError.publicationUnconfirmed }
            // Even cancellation after save must retain the now-published credential.
            selected = candidate; loaded = true
            try check(mark)
            return candidate
        } catch {
            if submitted {
                publicationUnconfirmed = true; loaded = false
                // Never delete a candidate that a late OS save may still reference.
                throw ManagedTransferError.publicationUnconfirmed
            }
            if let prepared {
                do { try await vault.revoke(prepared) }
                catch { throw ManagedTransferError.cleanupUnconfirmed }
            }
            throw sanitized(error)
        }
    }

    func authorizeDelivery() async throws -> ManagedDeliveryAuthorization {
        guard authorization == nil else { throw ManagedTransferError.busy }
        guard !busy else { throw ManagedTransferError.busy }
        guard loaded, !publicationUnconfirmed, let selected else { throw ManagedTransferError.selectionMissing }
        busy = true; defer { busy = false }
        cancel()
        let mark = cancellation
        guard try await store.read() == selected else { throw ManagedTransferError.selectionChanged }
        try check(mark)
        let grant = ManagedDeliveryAuthorization(id: UUID(), handle: selected,
                                                request: ManagedStartRequest(profile: selected.profile))
        authorization = grant
        return grant
    }

    /// Called only after the native client has completed its authenticated XPC hello.
    /// An authorization is reserved BEFORE the first await, so concurrent requests
    /// cannot read twice. A denied read consumes it; there is no transparent retry.
    func material(for grant: ManagedDeliveryAuthorization) async throws -> ManagedCredentialMaterial {
        guard !busy else { throw ManagedTransferError.busy }
        try validate(grant)
        guard !materialWasRead else { throw ManagedTransferError.replay }
        busy = true; materialWasRead = true
        defer { busy = false }
        do {
            guard try await store.read() == grant.handle else { throw ManagedTransferError.selectionChanged }
            try validate(grant)
            let material = try await vault.load(grant.handle)
            try validate(grant)
            guard try await store.read() == grant.handle else { throw ManagedTransferError.selectionChanged }
            try validate(grant)
            return material
        } catch {
            cancel()
            throw sanitized(error)
        }
    }

    func validateForStart(_ grant: ManagedDeliveryAuthorization) async throws {
        guard !busy else { throw ManagedTransferError.busy }
        busy = true; defer { busy = false }
        do {
            try validate(grant)
            guard materialWasRead, try await store.read() == grant.handle else {
                throw ManagedTransferError.selectionChanged
            }
            try validate(grant)
        } catch {
            cancel(); throw sanitized(error)
        }
    }

    func finishDelivery(_ grant: ManagedDeliveryAuthorization) {
        guard authorization?.id == grant.id else { return }
        cancel()
    }

    private func check(_ mark: UUID) throws {
        guard !Task.isCancelled, mark == cancellation else { throw ManagedTransferError.cancelled }
    }
    private func validate(_ grant: ManagedDeliveryAuthorization) throws {
        guard !Task.isCancelled, loaded, !publicationUnconfirmed,
              authorization?.id == grant.id, selected == grant.handle else {
            throw ManagedTransferError.cancelled
        }
    }
    private func sanitized(_ error: Error) -> ManagedTransferError {
        if let known = error as? ManagedTransferError { return known }
        if let known = error as? ManagedCredentialError, known.cleanup == .unconfirmed { return .cleanupUnconfirmed }
        return Task.isCancelled ? .cancelled : .unavailable
    }
}
