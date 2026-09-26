// SPDX-License-Identifier: MIT
import PolicyCore

/// Keys never cross this boundary. The native adapter projects every network field,
/// including unsupported address families, rather than silently filtering them out.
public struct WireGuardPlanSource: Equatable, Sendable {
    public struct Peer: Equatable, Sendable {
        public let endpoint: String?
        public let allowedIPs: [String]
        public init(endpoint: String?, allowedIPs: [String]) {
            self.endpoint = endpoint; self.allowedIPs = allowedIPs
        }
    }
    public let addresses: [String]
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let mtu: Int?
    public let peers: [Peer]

    public init(addresses: [String], dnsServers: [String], searchDomains: [String],
                mtu: Int?, peers: [Peer]) {
        self.addresses = addresses; self.dnsServers = dnsServers
        self.searchDomains = searchDomains; self.mtu = mtu; self.peers = peers
    }
}

/// No default: importing DNS fields does not authorize taking over DNS.
public enum WireGuardDNSSelection: Equatable, Sendable {
    case keepSystemExplicitly
    case useConfigurationAsDefault
}

public enum WireGuardAssemblyError: String, Error, Sendable {
    case unsupportedAddress = "E_WG_ASSEMBLY_ADDRESS"
    case unsupportedEndpoint = "E_WG_ASSEMBLY_ENDPOINT"
    case searchDomainsUnsupported = "E_WG_ASSEMBLY_SEARCH_DOMAINS"
    case inputLimit = "E_WG_ASSEMBLY_LIMIT"
    case underlayMismatch = "E_WG_ASSEMBLY_UNDERLAY"
    case sourceChanged = "E_WG_ASSEMBLY_SOURCE_CHANGED"
}

/// Joins protocol-derived network values, user intent and supplied underlay facts.
/// This is still planning/inspection only, not a permission to apply system settings.
/// The native controller must supply and invalidate its live generation/epoch.
public struct PreparedWireGuardPlan: Equatable, Sendable {
    public let source: WireGuardPlanSource
    public let policy: IPv4Policy
    public let underlay: IPv4ConstraintInput
    public let dnsSelection: WireGuardDNSSelection
    public let constrained: ConstrainedIPv4PolicyPlan
    public let settings: ManagedSettingsDraft

    public func check(source currentSource: WireGuardPlanSource, policy currentPolicy: IPv4Policy,
                      underlay currentUnderlay: IPv4ConstraintInput, dnsSelection currentSelection: WireGuardDNSSelection,
                      context: PlanContext) throws {
        guard settings.context.check(against: context) == .current else { throw SettingsError.contextChanged }
        guard source == currentSource, policy == currentPolicy, underlay == currentUnderlay,
              dnsSelection == currentSelection else {
            throw WireGuardAssemblyError.sourceChanged
        }
    }

    public static func prepare(source: WireGuardPlanSource, policy: IPv4Policy,
                               context: PlanContext, underlay: IPv4ConstraintInput,
                               dnsSelection: WireGuardDNSSelection,
                               limits: CompilationLimits = .init()) throws -> Self {
        guard context.backendID == BackendCapabilities.wireGuard.backendID else { throw SettingsError.wrongBackend }
        // Require an explicit topology snapshot, even when its contents are unobserved/empty.
        // It cannot inject conflicting peer or protocol-owned requirements.
        guard context.check(against: underlay.context) == .current, underlay.wireGuardPeers == nil,
              underlay.infrastructure.allSatisfy({
                  $0.role == .physicalGateway || $0.role == .physicalLAN || $0.role == .systemReserved
              }) else { throw WireGuardAssemblyError.underlayMismatch }
        guard (1...64).contains(source.addresses.count), (1...64).contains(source.peers.count),
              source.dnsServers.count <= 32,
              underlay.infrastructure.count <= ConstraintLimits.requirementCeiling else {
            throw WireGuardAssemblyError.inputLimit
        }
        guard source.searchDomains.isEmpty else { throw WireGuardAssemblyError.searchDomainsUnsupported }
        var prefixCount = 0
        for peer in source.peers {
            guard peer.allowedIPs.count <= ConstraintLimits.prefixCeiling - prefixCount else {
                throw WireGuardAssemblyError.inputLimit
            }
            prefixCount += peer.allowedIPs.count
        }
        let addresses: [TunnelIPv4Address]
        let dnsServers: [IPv4Address]
        let peers: [WireGuardPeerRange]
        do {
            addresses = try source.addresses.map(TunnelIPv4Address.init)
            dnsServers = try source.dnsServers.map(IPv4Address.init)
            peers = try source.peers.enumerated().map { index, peer in
                WireGuardPeerRange(id: "peer-\(index + 1)", allowedIPs: try peer.allowedIPs.map(IPv4CIDR.init))
            }
        } catch { throw WireGuardAssemblyError.unsupportedAddress }
        guard Set(dnsServers).count == dnsServers.count else { throw SettingsError.dnsChoice }
        let endpoints = try source.peers.map { try endpointAddress($0.endpoint) }
        let dns: ManagedDNSChoice
        switch dnsSelection {
        case .keepSystemExplicitly: dns = .keepSystemExplicitly
        case .useConfigurationAsDefault:
            guard policy.defaultAction == .vpn, !dnsServers.isEmpty else { throw SettingsError.dnsChoice }
            dns = .tunnelDefault(servers: dnsServers)
        }
        let mtu: ManagedMTU
        if let value = source.mtu, value != 0 {
            guard (576...65535).contains(value) else { throw SettingsError.invalidMTU }
            mtu = .explicit(value)
        } else { mtu = .automaticOverhead80 }

        // Generate identifiers from positions, never from keys, hostnames or interface names.
        var requirements = try addresses.enumerated().map { index, address in
            InfrastructureRequirement(id: "wg-local-\(index + 1)", role: .localAddress,
                                      cidr: try IPv4CIDR(address: address.address, prefixLength: 32))
        }
        requirements += try endpoints.enumerated().map { index, endpoint in
            InfrastructureRequirement(id: "wg-endpoint-\(index + 1)", role: .vpnEndpoint,
                                      cidr: try IPv4CIDR(address: endpoint, prefixLength: 32))
        }
        // Retain protection of every configured VPN DNS address, matching AppCore planning.
        // Resolver selection is independent: keepSystem does not install a DNS resolver.
        requirements += try dnsServers.enumerated().map { index, server in
            InfrastructureRequirement(id: "wg-dns-\(index + 1)", role: .vpnDNS,
                                      cidr: try IPv4CIDR(address: server, prefixLength: 32))
        }
        requirements += underlay.infrastructure.enumerated().map { index, requirement in
            InfrastructureRequirement(id: "underlay-\(index + 1)", role: requirement.role, cidr: requirement.cidr)
        }
        let input = SettingsInput(context: context, addresses: addresses, endpoints: endpoints,
                                  protocolPeers: peers, dns: dns, mtu: mtu)
        let constrained = try IPv4ConstrainedPolicyCompiler.compile(policy, capabilities: .wireGuard,
            context: context, constraints: .init(context: context, infrastructure: requirements, wireGuardPeers: peers),
            limits: limits)
        let settings = try ManagedSettingsDraft.prepare(constrained, input: input, maxRoutes: limits.maxRoutes)
        return Self(source: source, policy: policy, underlay: underlay, dnsSelection: dnsSelection,
                    constrained: constrained, settings: settings)
    }

    private static func endpointAddress(_ endpoint: String?) throws -> IPv4Address {
        guard let endpoint, (9...21).contains(endpoint.utf8.count) else {
            throw WireGuardAssemblyError.unsupportedEndpoint
        }
        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...5).contains(parts[1].utf8.count),
              parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(parts[1]), port > 0 else {
            throw WireGuardAssemblyError.unsupportedEndpoint
        }
        do { return try IPv4Address(String(parts[0])) }
        catch { throw WireGuardAssemblyError.unsupportedEndpoint }
    }
}
