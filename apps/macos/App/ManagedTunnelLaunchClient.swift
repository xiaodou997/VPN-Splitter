// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import ProviderConfiguration

/// One explicit submission from an already reloaded, user-selected manager.
/// The future real connection UI must reload preferences first and observe NE status
/// afterwards. A returned attempt ID means SUBMITTED, never connected/handshaken.
/// No LocalDev credential is read, copied, migrated or granted additional access.
@MainActor
final class ManagedTunnelLaunchClient {
    enum Failure: String, Error {
        case alreadyUsed, managerNotReady, invalidProfile, submissionFailed
    }
    private var used = false

    /// Terminal even on failure: a retry needs a new client after the caller has
    /// established terminal NE state. This is not a global multi-manager lock.
    func submitLoadedProfile(manager: NETunnelProviderManager,
                             expectedProfile: ManagedProfileDescriptor,
                             expectedCredentialReference: Data,
                             expectedProviderBundleIdentifier: String) throws -> UUID {
        guard !used else { throw Failure.alreadyUsed }
        used = true
        guard manager.isEnabled, !manager.isOnDemandEnabled, manager.connection.status == .disconnected,
              let session = manager.connection as? NETunnelProviderSession,
              let configuration = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw Failure.managerNotReady
        }
        let request = ManagedStartRequest(profile: expectedProfile)
        let options = ManagedLaunchContract.startOptions(for: request)
        do {
            let checked = try ManagedLaunchContract.check(
                providerBundleIdentifier: configuration.providerBundleIdentifier,
                expectedProviderBundleIdentifier: expectedProviderBundleIdentifier,
                providerConfiguration: configuration.providerConfiguration,
                passwordReference: configuration.passwordReference, options: options)
            try ManagedLaunchContract.checkExpectedReference(expectedCredentialReference, launch: checked)
        } catch {
            throw Failure.invalidProfile // Never propagate raw config/framework errors.
        }
        do { try session.startTunnel(options: options) }
        catch { throw Failure.submissionFailed }
        return request.attemptID
    }
}
