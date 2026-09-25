// SPDX-License-Identifier: MIT
// macOS SDK object tests only. No extension loading or network settings application.
import Foundation
import NetworkExtension
import Testing
import PolicyCore
import ManagedSettings
import ManagedSettingsApple

private func specimen(bypass: Bool = false, dns: Bool = false, automaticMTU: Bool = false) throws -> ManagedSettingsDraft {
    let ctx = PlanContext(sessionID: "native-object-test", backendID: "wireguard", generation: 1, networkEpoch: 1)
    let peers = [WireGuardPeerRange(id: "peer-1", allowedIPs: [try IPv4CIDR("0.0.0.0/0")])]
    var infrastructure = [
        InfrastructureRequirement(id: "endpoint", role: .vpnEndpoint, cidr: try IPv4CIDR("203.0.113.9/32")),
        InfrastructureRequirement(id: "local", role: .localAddress, cidr: try IPv4CIDR("10.8.0.2/32"))
    ]
    if dns { infrastructure.append(.init(id: "dns", role: .vpnDNS, cidr: try IPv4CIDR("10.9.0.53/32"))) }
    let input = SettingsInput(context: ctx, addresses: [try TunnelIPv4Address("10.8.0.2/24")],
        endpoints: [try IPv4Address("203.0.113.9")], protocolPeers: peers,
        dns: dns ? .tunnelDefault(servers: [try IPv4Address("10.9.0.53")]) : .keepSystemExplicitly,
        mtu: automaticMTU ? .automaticOverhead80 : .explicit(1380))
    let policy = IPv4Policy(defaultAction: bypass ? .vpn : .direct,
        rules: [.init(id: "corp", match: .ipv4(try IPv4CIDR("10.9.0.0/16")), action: .vpn)])
    let plan = try IPv4ConstrainedPolicyCompiler.compile(policy, capabilities: .wireGuard, context: ctx,
        constraints: .init(context: ctx, infrastructure: infrastructure, wireGuardPeers: peers))
    return try ManagedSettingsDraft.prepare(plan, input: input)
}

@Test func nativeIPv4ObjectsMatchEveryPreparedRoute() throws {
    let draft = try specimen()
    let object = try PacketTunnelSettingsFactory.makeForInspection(draft, current: draft.input)
    let ipv4 = try #require(object.ipv4Settings)
    #expect(object.tunnelRemoteAddress == "203.0.113.9")
    #expect(ipv4.addresses == ["10.8.0.2"] && ipv4.subnetMasks == ["255.255.255.0"])
    #expect(ipv4.includedRoutes?.map(\.destinationAddress) == draft.includedRoutes.map(\.destination))
    #expect(ipv4.includedRoutes?.map(\.destinationSubnetMask) == draft.includedRoutes.map(\.subnetMask))
    #expect(ipv4.excludedRoutes?.map(\.destinationAddress) == draft.excludedRoutes.map(\.destination))
    #expect(ipv4.excludedRoutes?.map(\.destinationSubnetMask) == draft.excludedRoutes.map(\.subnetMask))
    #expect(ipv4.includedRoutes?.allSatisfy { $0.gatewayAddress == nil } == true)
    #expect(ipv4.excludedRoutes?.allSatisfy { $0.gatewayAddress == nil } == true)
    #expect(object.ipv6Settings == nil && object.dnsSettings == nil && object.proxySettings == nil)
    #expect(object.mtu?.intValue == 1380 && object.tunnelOverheadBytes == nil)
}

@Test func nativeDefaultDNSIsExplicitAndDoesNotAddSearchDomains() throws {
    let draft = try specimen(bypass: true, dns: true, automaticMTU: true)
    let object = try PacketTunnelSettingsFactory.makeForInspection(draft, current: draft.input)
    #expect(object.ipv4Settings?.includedRoutes?.first?.destinationSubnetMask == "0.0.0.0")
    let dns = try #require(object.dnsSettings)
    #expect(dns.servers == ["10.9.0.53"] && dns.matchDomains == [""])
    #expect(dns.matchDomainsNoSearch && dns.searchDomains == [])
    #expect(object.mtu == nil && object.tunnelOverheadBytes?.intValue == 80)
}

@Test func nativeAllocationDoesNotShareMutableSettingsOrChangeTheRecipe() throws {
    let draft = try specimen()
    let first = try PacketTunnelSettingsFactory.makeForInspection(draft, current: draft.input)
    first.ipv4Settings?.includedRoutes = []
    let second = try PacketTunnelSettingsFactory.makeForInspection(draft, current: draft.input)
    #expect(first !== second)
    #expect(second.ipv4Settings?.includedRoutes?.count == draft.includedRoutes.count)
    #expect(second.ipv4Settings?.includedRoutes?.isEmpty == false)
}

@Test func nativeFactoryRechecksTheCompleteInputSnapshot() throws {
    let draft = try specimen()
    let old = draft.input
    let changed = SettingsInput(context: .init(sessionID: old.context.sessionID, backendID: old.context.backendID,
        generation: old.context.generation, networkEpoch: old.context.networkEpoch + 1), addresses: old.addresses,
        endpoints: old.endpoints, protocolPeers: old.protocolPeers, dns: old.dns, mtu: old.mtu)
    #expect(throws: SettingsError.contextChanged) { try PacketTunnelSettingsFactory.makeForInspection(draft, current: changed) }
}
