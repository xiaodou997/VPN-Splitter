// SPDX-License-Identifier: MIT
// Executable integration checks against explicit NE/Logger/PolicyCore test doubles.
import Foundation
import NetworkExtension
import ProviderConfiguration

@main
struct LaunchHarness {
    @MainActor
    static func main() throws {
        let bundleID = "test.vpnsplitter.provider"
        let profile = try ManagedProfileDescriptor(profileID: UUID(), credentialID: UUID(),
                                                    policyRevision: UUID(), generation: 1)
        let reference = Data([7, 11, 13])
        func configuration() -> NETunnelProviderProtocol {
            let result = NETunnelProviderProtocol()
            result.providerBundleIdentifier = bundleID
            result.providerConfiguration = ManagedLaunchContract.providerConfiguration(for: profile)
            result.passwordReference = reference
            return result
        }
        func manager() -> NETunnelProviderManager {
            let result = NETunnelProviderManager()
            result.protocolConfiguration = configuration()
            return result
        }
        func submit(_ client: ManagedTunnelLaunchClient, _ manager: NETunnelProviderManager,
                    expected: Data? = nil) throws -> UUID {
            try client.submitLoadedProfile(manager: manager, expectedProfile: profile,
                    expectedCredentialReference: expected ?? reference,
                    expectedProviderBundleIdentifier: bundleID)
        }
        func expectFailure(_ failure: ManagedTunnelLaunchClient.Failure,
                           _ body: () throws -> Void) {
            do { try body(); fatalError("Expected sanitized failure") }
            catch let observed as ManagedTunnelLaunchClient.Failure { precondition(observed == failure) }
            catch { fatalError("Unexpected error type escaped") }
        }
        func providerResult(_ config: NEVPNProtocol, _ options: [String: NSObject]?) -> NSError {
            let provider = PacketTunnelProvider()
            provider.protocolConfiguration = config
            var completions = 0
            var received: NSError?
            provider.startTunnel(options: options) { error in
                completions += 1; received = error as NSError?
            }
            precondition(completions == 1 && received != nil, "Must reject once, never report connected")
            var stopped = 0
            provider.stopTunnel(with: .userInitiated) { stopped += 1 }
            precondition(stopped == 1)
            return received!
        }
        // T-MLH01: the actual App helper submits matching metadata; never a connected result.
        let validManager = manager()
        let client = ManagedTunnelLaunchClient()
        let attempt = try submit(client, validManager)
        let session = validManager.connection as! NETunnelProviderSession
        let checked = try ManagedLaunchContract.check(providerBundleIdentifier: bundleID,
            expectedProviderBundleIdentifier: bundleID,
            providerConfiguration: configuration().providerConfiguration,
            passwordReference: reference, options: session.submittedOptions)
        precondition(session.submissions == 1 && checked.request.attemptID == attempt)
        // T-MLH02: same client cannot submit twice.
        expectFailure(.alreadyUsed) { _ = try submit(client, validManager) }
        precondition(session.submissions == 1)
        // T-MLH03: not enabled/terminal, wrong connection/protocol never submitted.
        for status in [NEVPNStatus.invalid, .connecting, .connected, .reasserting, .disconnecting] {
            let m = manager(); m.connection.status = status
            expectFailure(.managerNotReady) { _ = try submit(ManagedTunnelLaunchClient(), m) }
            precondition((m.connection as! NETunnelProviderSession).submissions == 0)
        }
        let disabled = manager(); disabled.isEnabled = false
        expectFailure(.managerNotReady) { _ = try submit(ManagedTunnelLaunchClient(), disabled) }
        let automatic = manager(); automatic.isOnDemandEnabled = true
        expectFailure(.managerNotReady) { _ = try submit(ManagedTunnelLaunchClient(), automatic) }
        let wrongConnection = manager(); wrongConnection.connection = NEVPNConnection()
        expectFailure(.managerNotReady) { _ = try submit(ManagedTunnelLaunchClient(), wrongConnection) }
        let wrongProtocol = manager(); wrongProtocol.protocolConfiguration = NEVPNProtocol()
        expectFailure(.managerNotReady) { _ = try submit(ManagedTunnelLaunchClient(), wrongProtocol) }
        // T-MLH04: selected reference mismatch blocks before submitting and consumes client.
        let mismatch = manager(); let rejectedClient = ManagedTunnelLaunchClient()
        expectFailure(.invalidProfile) { _ = try submit(rejectedClient, mismatch, expected: Data([99])) }
        expectFailure(.alreadyUsed) { _ = try submit(rejectedClient, mismatch) }
        precondition((mismatch.connection as! NETunnelProviderSession).submissions == 0)
        // T-MLH05: changed saved generation/provider rejected before submit.
        let stale = manager(); let c = stale.protocolConfiguration as! NETunnelProviderProtocol
        var fields = profile.propertyList; fields["generation"] = "2"
        c.providerConfiguration = [ManagedLaunchContract.profileKey: fields]
        expectFailure(.invalidProfile) { _ = try submit(ManagedTunnelLaunchClient(), stale) }
        let foreign = manager()
        (foreign.protocolConfiguration as! NETunnelProviderProtocol).providerBundleIdentifier = "test.foreign"
        expectFailure(.invalidProfile) { _ = try submit(ManagedTunnelLaunchClient(), foreign) }
        // T-MLH06: native submission errors are sanitized and not implicitly retried.
        let throwing = manager(); let throwingSession = throwing.connection as! NETunnelProviderSession
        throwingSession.failSubmission = true; let failedClient = ManagedTunnelLaunchClient()
        expectFailure(.submissionFailed) { _ = try submit(failedClient, throwing) }
        expectFailure(.alreadyUsed) { _ = try submit(failedClient, throwing) }
        precondition(throwingSession.submissions == 1)
        // T-MLH07: actual Provider entry keeps the explicit legacy smoke behavior.
        precondition(providerResult(configuration(), nil).code == 1002)
        let smoke: [String: NSObject] = ["S1SmokeTest": NSNumber(value: true),
                                         "S1Attempt": UUID().uuidString as NSString]
        precondition(providerResult(configuration(), smoke).code == 1001)
        // T-MLH08: a correctly submitted request reaches the truthful runtime blocker.
        let valid = providerResult(configuration(), session.submittedOptions)
        precondition(valid.domain == "VPNSplitter.Managed" && valid.code == 2001)
        // T-MLH09: mixed smoke options cannot bypass Managed validation.
        var mixed = session.submittedOptions!; mixed.merge(smoke) { _, right in right }
        precondition(providerResult(configuration(), mixed).code == 2002)
        // T-MLH10: malformed outer/inner types, missing reference and wrong provider rejected.
        precondition(providerResult(configuration(), [ManagedLaunchContract.startKey: NSNumber(value: true)]).code == 2002)
        let noReference = configuration(); noReference.passwordReference = nil
        precondition(providerResult(noReference, session.submittedOptions).code == 2002)
        let noProvider = configuration(); noProvider.providerBundleIdentifier = "test.foreign"
        precondition(providerResult(noProvider, session.submittedOptions).code == 2002)
        precondition(providerResult(NEVPNProtocol(), session.submittedOptions).code == 2002)
        // T-MLH11: mismatched revisions and accidental secret fields are rejected by real entry.
        precondition(providerResult(c, session.submittedOptions).code == 2002)
        var extra = checked.request.propertyList; extra["privateKey"] = "synthetic-sentinel"
        let blocked = providerResult(configuration(), [ManagedLaunchContract.startKey: extra as NSDictionary])
        precondition(blocked.code == 2002 && !blocked.localizedDescription.contains("synthetic-sentinel"))
        print("launch-harness=PASS scenarios=11 framework=TEST_DOUBLES bundle=INJECTED network=NOT_APPLIED")
    }
}
