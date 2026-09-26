// SPDX-License-Identifier: MIT
import Foundation
import Network
import NetworkExtension
import PolicyCore
import ManagedSettings
import ManagedSettingsApple
import WireGuardKit

/// Native configuration -> PolicyCore -> NE object factory -> mandatory Adapter binding.
/// Compiled into the isolated probe, not yet installed in the S1 Provider target.
/// Constructing this object does not start the adapter or apply network settings.
public final class ManagedWireGuardAssembly: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let plan: PreparedWireGuardPlan
    public let binding: SplitterWireGuardBinding
    public let adapter: WireGuardAdapter

    private init(plan: PreparedWireGuardPlan, binding: SplitterWireGuardBinding,
                 adapter: WireGuardAdapter) {
        self.plan = plan; self.binding = binding; self.adapter = adapter
    }

    /// Caller must serialize the initial configuration snapshot, provide observed underlay
    /// facts for this epoch and a thread-safe currentRevision source. Changing policy,
    /// topology or credential ownership MUST revoke/increment that live revision.
    /// The descriptor callback must derive its descriptor/name from the same Provider.
    /// This assembly neither discovers a descriptor nor proves its authority.
    public static func prepareForIntegration(
        provider: NEPacketTunnelProvider, configuration: TunnelConfiguration,
        policy: IPv4Policy, underlay: IPv4ConstraintInput, dnsSelection: WireGuardDNSSelection,
        revision: SplitterRuntimeRevision, currentRevision: @escaping () -> SplitterRuntimeRevision?,
        descriptor: @escaping () throws -> SplitterTunnelDescriptorLease
    ) throws -> ManagedWireGuardAssembly {
        let gate = SplitterRevisionGate(expected: revision)
        try gate.check(current: currentRevision())
        // Upstream configuration is a mutable reference; never capture the caller's object.
        let snapshot = TunnelConfiguration(name: nil, interface: configuration.interface, peers: configuration.peers)
        let context = PlanContext(sessionID: revision.session.uuidString,
            backendID: BackendCapabilities.wireGuard.backendID,
            generation: revision.generation, networkEpoch: revision.networkEpoch)
        let plan = try PreparedWireGuardPlan.prepare(source: project(snapshot), policy: policy,
            context: context, underlay: underlay, dnsSelection: dnsSelection)
        try gate.check(current: currentRevision())
        let binding = SplitterWireGuardBinding(configuration: snapshot, revision: revision,
                                              currentRevision: currentRevision)
        let adapter = WireGuardAdapter(with: provider, runtimeBinding: binding,
            tunnelDescriptorProvider: descriptor, networkSettingsProvider: { request in
                // Adapter checks the complete protocol snapshot (including keys) around this
                // callback. Re-project the actual request rather than trust an unrelated draft.
                do {
                    try gate.check(current: currentRevision())
                    let projected = try project(request)
                    try plan.check(source: projected, policy: policy, underlay: underlay,
                                   dnsSelection: dnsSelection, context: context)
                    let settings = try PacketTunnelSettingsFactory.makeForInspection(plan.settings, current: plan.settings.input)
                    try gate.check(current: currentRevision())
                    return settings
                } catch {
                    binding.invalidate()
                    // Do not propagate framework errors or configuration values into diagnostics.
                    throw SplitterAdmissionError.configurationChanged
                }
            }, logHandler: { _, _ in
                // Drop raw upstream strings. Typed/redacted Provider diagnostics are separate.
            })
        return ManagedWireGuardAssembly(plan: plan, binding: binding, adapter: adapter)
    }

    /// Every address family is checked before conversion. No keys, UAPI, parsing of
    /// credential files, hostname lookup or mutation of AllowedIPs belongs here.
    public static func project(_ configuration: TunnelConfiguration) throws -> WireGuardPlanSource {
        guard (1...64).contains(configuration.interface.addresses.count),
              configuration.interface.dns.count <= 32,
              (1...64).contains(configuration.peers.count) else { throw WireGuardAssemblyError.inputLimit }
        guard configuration.interface.addresses.allSatisfy({ $0.address is Network.IPv4Address }),
              configuration.interface.dns.allSatisfy({ $0.address is Network.IPv4Address }) else {
            throw WireGuardAssemblyError.unsupportedAddress
        }
        var prefixCount = 0
        let peers = try configuration.peers.map { peer -> WireGuardPlanSource.Peer in
            guard peer.allowedIPs.count <= ConstraintLimits.prefixCeiling - prefixCount else {
                throw WireGuardAssemblyError.inputLimit
            }
            prefixCount += peer.allowedIPs.count
            guard peer.allowedIPs.allSatisfy({ $0.address is Network.IPv4Address }) else {
                throw WireGuardAssemblyError.unsupportedAddress
            }
            guard let endpoint = peer.endpoint, case .ipv4 = endpoint.host, endpoint.port.rawValue > 0 else {
                throw WireGuardAssemblyError.unsupportedEndpoint
            }
            return .init(endpoint: endpoint.stringRepresentation, allowedIPs: peer.allowedIPs.map(\.stringRepresentation))
        }
        return WireGuardPlanSource(addresses: configuration.interface.addresses.map(\.stringRepresentation),
            dnsServers: configuration.interface.dns.map(\.stringRepresentation),
            searchDomains: configuration.interface.dnsSearch,
            mtu: configuration.interface.mtu.map(Int.init), peers: peers)
    }

    public var description: String { "ManagedWireGuardAssembly(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
