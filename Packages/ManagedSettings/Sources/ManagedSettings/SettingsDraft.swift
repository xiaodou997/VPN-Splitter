// SPDX-License-Identifier: MIT
import PolicyCore

public struct IPv4RouteDescriptor: Equatable, Sendable {
    public let cidr: IPv4CIDR
    public var destination: String { cidr.networkAddress.description }
    public var subnetMask: String { TunnelIPv4Address.mask(cidr.prefixLength) }
    init(_ cidr: IPv4CIDR) { self.cidr = cidr }
}

public enum SettingsLimitation: String, Sendable, CaseIterable {
    case inspectionOnly, suppliedTopologyOnly, nativeRoutingUnverified
    case protocolEngineNotLinked, ipv6Unmanaged, noSystemKillSwitch
}

/// An inspectable object recipe, not permission or a transaction to apply it.
/// Public callers cannot construct arbitrary route arrays or alter a prepared draft.
public struct ManagedSettingsDraft: Equatable, Sendable {
    public let input: SettingsInput
    public let mode: PolicyMode
    public let includedRoutes: [IPv4RouteDescriptor]
    public let excludedRoutes: [IPv4RouteDescriptor]
    public let limitations: [SettingsLimitation]

    public var context: PlanContext { input.context }

    /// A second freshness check immediately before native object construction.
    /// This comparison is not a runtime epoch detector or a TOCTOU guarantee.
    public func check(against current: SettingsInput) throws {
        guard input.context.check(against: current.context) == .current else { throw SettingsError.contextChanged }
        guard input == current else { throw SettingsError.infrastructureMismatch }
    }

    public static func prepare(_ plan: ConstrainedIPv4PolicyPlan, input: SettingsInput,
                               maxRoutes: Int = CompilationLimits.routeCeiling) throws -> Self {
        guard plan.context.check(against: input.context) == .current,
              plan.input.context.check(against: input.context) == .current else { throw SettingsError.contextChanged }
        guard input.context.backendID == BackendCapabilities.wireGuard.backendID else { throw SettingsError.wrongBackend }
        guard (1...64).contains(input.addresses.count), (1...64).contains(input.endpoints.count),
              (1...64).contains(input.protocolPeers.count) else { throw SettingsError.inputLimit }
        guard Set(input.addresses.map(\.address)).count == input.addresses.count else { throw SettingsError.invalidAddress }
        if case .explicit(let value) = input.mtu, !(576...65535).contains(value) { throw SettingsError.invalidMTU }
        guard plan.input.wireGuardPeers == input.protocolPeers else { throw SettingsError.peerMismatch }
        // Reject unprotected endpoints/addresses AND stale extra entries of these roles.
        let declared = plan.input.infrastructure
        let expectedEndpoints = Set(input.endpoints)
        let expectedAddresses = Set(input.addresses.map(\.address))
        guard Set(declared.filter { $0.role == .vpnEndpoint }.map { $0.cidr.networkAddress }) == expectedEndpoints,
              Set(declared.filter { $0.role == .localAddress }.map { $0.cidr.networkAddress }) == expectedAddresses else {
            throw SettingsError.infrastructureMismatch
        }
        // The constrained compiler already rejects explicit contrary user rules.
        for host in expectedEndpoints.union(expectedAddresses) {
            guard plan.decision(for: host).action == .direct else { throw SettingsError.infrastructureMismatch }
        }
        let mode: PolicyMode = plan.userIntent.defaultAction == .direct ? .include : .bypass
        switch input.dns {
        case .keepSystemExplicitly: break
        case .tunnelDefault(let servers):
            // Bypass has an explicit default route; Include must not accidentally take all DNS.
            guard mode == .bypass, !servers.isEmpty, servers.count <= 32,
                  Set(servers).count == servers.count else { throw SettingsError.dnsChoice }
            let declaredDNS = Set(declared.filter { $0.role == .vpnDNS }.map { $0.cidr.networkAddress })
            guard declaredDNS == Set(servers) else { throw SettingsError.dnsRoute }
            guard servers.allSatisfy({ plan.decision(for: $0).action == .vpn }) else { throw SettingsError.dnsRoute }
        }
        let vpn = plan.routes.filter { $0.action == .vpn }.map(\.cidr)
        let direct = plan.routes.filter { $0.action == .direct }.map(\.cidr)
        guard !vpn.isEmpty else { throw SettingsError.emptyVPN }
        // Include uses the compiler's VPN partition, never peer AllowedIPs or interface CIDRs.
        // Bypass uses /0 plus the compiler's disjoint DIRECT partition as explicit exclusions.
        let included = try mode == .include ? vpn : [IPv4CIDR("0.0.0.0/0")]
        // Excluding all DIRECT regions also makes the intended treatment of connected
        // interface prefixes explicit. Actual NE connected-route precedence is still unverified.
        guard (1...CompilationLimits.routeCeiling).contains(maxRoutes),
              included.count <= maxRoutes, direct.count <= maxRoutes - included.count else {
            throw SettingsError.routeLimit
        }
        return Self(input: input, mode: mode, includedRoutes: included.map(IPv4RouteDescriptor.init),
                    excludedRoutes: direct.map(IPv4RouteDescriptor.init), limitations: SettingsLimitation.allCases)
    }
}
