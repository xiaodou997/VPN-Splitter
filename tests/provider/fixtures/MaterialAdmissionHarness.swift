// SPDX-License-Identifier: MIT
// Framework and authenticated-delivery TEST DOUBLES. No native auth or Keychain.
// The harness links the ACTUAL importer, credential validation, policy compiler,
// ManagedLaunch, ManagedWireGuardInput and a test copy of the formal Provider.
import Foundation
import NetworkExtension
import ProviderConfiguration

enum ManagedTransferError: Error { case deliveryMissing }
struct SyntheticReceivedMaterial {
    let configuration: Data
    let policy: Data
    func withContents<T>(_ body: (Data, Data) throws -> T) rethrows -> T {
        try body(configuration, policy)
    }
}
@MainActor
final class ManagedExtensionRuntime {
    static var shared: ManagedExtensionRuntime?
    var material: SyntheticReceivedMaterial?
    var consumed = 0
    func consume(_ launch: CheckedManagedLaunch, ownerUID: UInt32) throws -> SyntheticReceivedMaterial {
        // Merely an injected source, NOT an authentication/replay implementation.
        guard ownerUID == 501, let value = material else { throw ManagedTransferError.deliveryMissing }
        material = nil; consumed += 1
        return value
    }
    func discard() { material = nil }
}

@main
struct MaterialAdmissionHarness {
    @MainActor
    static func main() async throws {
        let profile = try ManagedProfileDescriptor(profileID: UUID(), credentialID: UUID(), policyRevision: UUID(), generation: 1)
        let request = ManagedStartRequest(profile: profile)
        let options = ManagedLaunchContract.startOptions(for: request)
        let privateKey = Data(repeating: 1, count: 32).base64EncodedString()
        let publicKey = Data(repeating: 2, count: 32).base64EncodedString()
        let source = "[Interface]\nPrivateKey = \(privateKey)\nAddress = 10.250.0.2/32\n[Peer]\nPublicKey = \(publicKey)\nEndpoint = 198.51.100.9:51820\nAllowedIPs = 10.20.0.0/16\n"
        let archive = try ManagedWireGuardInput.encodeIncludePolicy("10.20.1.0/24")
        func provider(uid: String = "501") -> PacketTunnelProvider {
            let p = NETunnelProviderProtocol()
            p.providerBundleIdentifier = "test.vpnsplitter.provider"
            p.providerConfiguration = ManagedLaunchContract.providerConfiguration(for: profile)
            p.passwordReference = Data([7, 11, 13]); p.username = uid
            let result = PacketTunnelProvider(); result.protocolConfiguration = p
            return result
        }
        func stage(_ text: String, policy: Data? = nil) {
            let runtime = ManagedExtensionRuntime()
            runtime.material = SyntheticReceivedMaterial(configuration: Data(text.utf8), policy: policy ?? archive)
            ManagedExtensionRuntime.shared = runtime
        }
        func result(_ p: PacketTunnelProvider, options: [String: NSObject]?) async -> NSError {
            await withCheckedContinuation { continuation in
                p.startTunnel(options: options) { error in
                    precondition(error != nil, "No tested path may claim VPN success")
                    continuation.resume(returning: error! as NSError)
                }
            }
        }
        // T-MAI01: real semantic admission succeeds, but engine blocker remains explicit.
        stage(source)
        let first = await result(provider(), options: options)
        precondition(first.code == 2001 && first.domain == "VPNSplitter.Managed")
        precondition(ManagedExtensionRuntime.shared?.consumed == 1)
        // T-MAI02: consumption cannot be replaced by metadata equality alone.
        let again = await result(provider(), options: options)
        precondition(again.code == 2003)
        // T-MAI03: scripts/unknown options/keys are rejected after injected delivery.
        for changed in [source + "PostUp = SYNTHETIC-SENTINEL\n", source + "Table = auto\n",
                        source.replacingOccurrences(of: publicKey, with: "SYNTHETIC-SENTINEL")] {
            stage(changed)
            let failure = await result(provider(), options: options)
            precondition(failure.code == 2004 && !failure.localizedDescription.contains("SYNTHETIC-SENTINEL"))
            precondition(ManagedExtensionRuntime.shared?.material == nil)
        }
        // T-MAI04: valid grammar with wrong protocol coverage still fails in PolicyCore.
        stage(source, policy: try ManagedWireGuardInput.encodeIncludePolicy("10.21.0.0/16"))
        let range = await result(provider(), options: options); precondition(range.code == 2004)
        // T-MAI05: every policy archive is re-decoded at the formal entry.
        stage(source, policy: Data("SYNTHETIC-SENTINEL".utf8))
        let badPolicy = await result(provider(), options: options); precondition(badPolicy.code == 2004)
        // T-MAI06: unsupported DNS is never silently ignored.
        stage(source.replacingOccurrences(of: "Address =", with: "DNS = 10.20.0.53\nAddress ="))
        let dns = await result(provider(), options: options); precondition(dns.code == 2004)
        // T-MAI07: mixed/wrong metadata fails BEFORE accessing the source.
        stage(source)
        let badMetadata = await result(provider(), options: [ManagedLaunchContract.startKey: NSNumber(value: true)])
        precondition(badMetadata.code == 2002 && ManagedExtensionRuntime.shared?.consumed == 0)
        // T-MAI08: missing runtime and unparseable owner fail without source material.
        ManagedExtensionRuntime.shared = nil
        let missing = await result(provider(), options: options); precondition(missing.code == 2003)
        stage(source)
        let noOwner = await result(provider(uid: "0501"), options: options)
        precondition(noOwner.code == 2003 && ManagedExtensionRuntime.shared?.consumed == 0)
        // T-MAI09: old explicit smoke remains distinct; not a credential path.
        let smoke = await result(provider(), options: ["S1SmokeTest": NSNumber(value: true), "S1Attempt": UUID().uuidString as NSString])
        precondition(smoke.code == 1001)
        // T-MAI10: actual stop branch discards unconsumed test material.
        stage(source)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            provider().stopTunnel(with: .userInitiated) { continuation.resume() }
        }
        precondition(ManagedExtensionRuntime.shared?.material == nil)
        print("material-provider-harness=PASS scenarios=10 parser_policy=ACTUAL framework_delivery=TEST_DOUBLES bundle=INJECTED native_auth=NOT_TESTED network=NOT_APPLIED")
    }
}
