// SPDX-License-Identifier: MIT
import Testing
import PolicyCore
@testable import ManagedSettings

private let assemblyContext = PlanContext(sessionID: "assembly-test", backendID: "wireguard", generation: 7, networkEpoch: 2)
private func source(addresses: [String] = ["10.8.0.2/24"], dns: [String] = [],
                    search: [String] = [], mtu: Int? = 1420,
                    endpoint: String? = "198.51.100.20:51820",
                    ranges: [String] = ["0.0.0.0/0"],
                    peers: [WireGuardPlanSource.Peer]? = nil) -> WireGuardPlanSource {
    WireGuardPlanSource(addresses: addresses, dnsServers: dns, searchDomains: search, mtu: mtu,
                        peers: peers ?? [.init(endpoint: endpoint, allowedIPs: ranges)])
}
private func rule(_ cidr: String, action: PolicyAction = .vpn, id: String = "target") throws -> PolicyRule {
    PolicyRule(id: id, match: .ipv4(try IPv4CIDR(cidr)), action: action)
}
private func includePolicy() throws -> IPv4Policy {
    try IPv4Policy(defaultAction: .direct, rules: [rule("10.9.0.0/16")])
}
private func emptyUnderlay(_ context: PlanContext = assemblyContext) -> IPv4ConstraintInput {
    .init(context: context, infrastructure: [])
}
private func prepare(_ input: WireGuardPlanSource = source(), policy: IPv4Policy? = nil,
                     underlay: IPv4ConstraintInput = emptyUnderlay(),
                     dns: WireGuardDNSSelection = .keepSystemExplicitly,
                     context: PlanContext = assemblyContext, limits: CompilationLimits = .init()) throws -> PreparedWireGuardPlan {
    try PreparedWireGuardPlan.prepare(source: input, policy: policy ?? includePolicy(), context: context,
                                     underlay: underlay, dnsSelection: dns, limits: limits)
}

@Test func assemblyIncludeRoutesComeFromRulesNotProtocolOrInterfaceSubnet() throws {
    let original = source()
    let value = try prepare(original)
    #expect(value.settings.includedRoutes.map(\.cidr.description) == ["10.9.0.0/16"])
    #expect(value.settings.input.addresses.first?.address.description == "10.8.0.2")
    #expect(value.settings.input.addresses.first?.subnetMask == "255.255.255.0")
    #expect(value.settings.input.protocolPeers.first?.allowedIPs.map(\.description) == ["0.0.0.0/0"])
    #expect(value.source == original)
    #expect(value.constrained.decision(for: try IPv4Address("10.8.0.99")).action == .direct)
    #expect(value.constrained.decision(for: try IPv4Address("10.9.4.5")).wireGuardPeerID == "peer-1")
}

@Test func assemblyBypassKeepsDefaultAndInfrastructureExceptions() throws {
    let policy = try IPv4Policy(defaultAction: .vpn, rules: [rule("203.0.113.0/24", action: .direct)])
    let result = try prepare(policy: policy)
    #expect(result.settings.mode == .bypass)
    #expect(result.settings.includedRoutes.map(\.cidr.description) == ["0.0.0.0/0"])
    for address in ["203.0.113.7", "198.51.100.20", "10.8.0.2"] {
        #expect(result.settings.excludedRoutes.contains { $0.cidr.contains(try! IPv4Address(address)) })
    }
}

@Test func assemblyPreservesFirstMatchRuleOrder() throws {
    let policy = try IPv4Policy(defaultAction: .direct, rules: [rule("10.9.4.0/24", action: .direct, id: "first"),
                                                               rule("10.9.0.0/16", id: "second")])
    let result = try prepare(policy: policy)
    #expect(result.constrained.decision(for: try IPv4Address("10.9.4.5")).action == .direct)
    #expect(result.constrained.decision(for: try IPv4Address("10.9.5.5")).action == .vpn)
}

@Test func assemblyPeerAndPrefixOrderAreNotRewritten() throws {
    let input = source(peers: [.init(endpoint: "198.51.100.20:51820", allowedIPs: ["10.9.0.0/16", "10.10.0.0/16"]),
                               .init(endpoint: "198.51.100.20:51821", allowedIPs: ["10.9.4.0/24"])])
    let result = try prepare(input)
    #expect(result.settings.input.protocolPeers.map(\.id) == ["peer-1", "peer-2"])
    #expect(result.settings.input.protocolPeers[0].allowedIPs.map(\.description) == input.peers[0].allowedIPs)
    #expect(result.constrained.decision(for: try IPv4Address("10.9.4.5")).wireGuardPeerID == "peer-2")
    #expect(result.settings.input.endpoints.count == 2)
}

@Test func assemblyRejectsOutsidePeerAndAmbiguousOwnership() throws {
    #expect(throws: PolicyCompilationError.self) { try prepare(source(ranges: ["10.10.0.0/16"])) }
    #expect(throws: PolicyCompilationError.self) {
        try prepare(source(peers: [.init(endpoint: "198.51.100.20:1", allowedIPs: ["0.0.0.0/0"]),
                                   .init(endpoint: "198.51.100.21:1", allowedIPs: ["0.0.0.0/0"])]))
    }
}

@Test(arguments: ["vpn.example.invalid:51820", "[2001:db8::1]:51820", "198.51.100.20:0",
                  "198.51.100.20:65536", "198.51.100.20:+1", "198.51.100.20: 1",
                  "198.51.100.20:", "198.51.100.20", "198.051.100.20:1", ""])
func assemblyRejectsEndpointWithoutResolvingOrEchoing(_ endpoint: String) {
    #expect(throws: WireGuardAssemblyError.unsupportedEndpoint) { try prepare(source(endpoint: endpoint)) }
}

@Test func assemblyRejectsMissingEndpointAndAcceptsPortBounds() throws {
    #expect(throws: WireGuardAssemblyError.unsupportedEndpoint) { try prepare(source(endpoint: nil)) }
    _ = try prepare(source(endpoint: "198.51.100.20:1"))
    _ = try prepare(source(endpoint: "198.51.100.20:65535"))
}

@Test func assemblyRejectsEveryUncoveredAddressFamilyEvenWithSystemDNS() {
    #expect(throws: WireGuardAssemblyError.unsupportedAddress) { try prepare(source(addresses: ["10.8.0.2/24", "2001:db8::2/64"])) }
    #expect(throws: WireGuardAssemblyError.unsupportedAddress) { try prepare(source(dns: ["2001:db8::53"])) }
    #expect(throws: WireGuardAssemblyError.unsupportedAddress) { try prepare(source(ranges: ["0.0.0.0/0", "::/0"])) }
    #expect(throws: WireGuardAssemblyError.searchDomainsUnsupported) { try prepare(source(search: ["corp.invalid"])) }
}

@Test func assemblyKeepsDNSSelectionSeparateFromResolverAddressProtection() throws {
    let result = try prepare(source(dns: ["10.20.0.53"]))
    #expect(result.settings.input.dns == .keepSystemExplicitly)
    #expect(result.constrained.decision(for: try IPv4Address("10.20.0.53")).action == .vpn)
    #expect(result.constrained.decision(for: try IPv4Address("10.20.0.54")).action == .direct)
    #expect(result.constrained.input.infrastructure.filter { $0.role == .vpnDNS }.count == 1)
}

@Test func assemblyDefaultDNSRequiresExplicitBypassAndConfiguredServers() throws {
    let policy = IPv4Policy(defaultAction: .vpn, rules: [])
    let result = try prepare(source(dns: ["10.9.0.53"]), policy: policy, dns: .useConfigurationAsDefault)
    #expect(result.settings.input.dns == .tunnelDefault(servers: [try IPv4Address("10.9.0.53")]))
    #expect(throws: SettingsError.dnsChoice) { try prepare(source(dns: ["10.9.0.53"]), dns: .useConfigurationAsDefault) }
    #expect(throws: SettingsError.dnsChoice) { try prepare(policy: policy, dns: .useConfigurationAsDefault) }
    #expect(throws: SettingsError.dnsChoice) { try prepare(source(dns: ["10.9.0.53", "10.9.0.53"])) }
}

@Test func assemblyRejectsConflictsInsteadOfOverridingExplicitRules() throws {
    for target in ["198.51.100.20/32", "10.8.0.2/32"] {
        let policy = try IPv4Policy(defaultAction: .direct, rules: [rule(target)])
        #expect(throws: PolicyCompilationError.self) { try prepare(policy: policy) }
    }
    let policy = try IPv4Policy(defaultAction: .vpn, rules: [rule("10.9.0.53/32", action: .direct)])
    #expect(throws: PolicyCompilationError.self) { try prepare(source(dns: ["10.9.0.53"]), policy: policy) }
}

@Test func assemblyPreservesMTUAndHandlesExplicitAutomaticMode() throws {
    for mtu in [576, 1380, 65535] {
        #expect(try prepare(source(mtu: mtu)).settings.input.mtu == .explicit(mtu))
    }
    for mtu: Int? in [nil, 0] {
        #expect(try prepare(source(mtu: mtu)).settings.input.mtu == .automaticOverhead80)
    }
    for mtu in [-1, 575, 65536, Int.max] {
        #expect(throws: SettingsError.invalidMTU) { try prepare(source(mtu: mtu)) }
    }
}

@Test func assemblyRejectsStaleTopologyAndProtocolOwnedTopologyRoles() throws {
    let stale = PlanContext(sessionID: "assembly-test", backendID: "wireguard", generation: 7, networkEpoch: 1)
    #expect(throws: WireGuardAssemblyError.underlayMismatch) { try prepare(underlay: emptyUnderlay(stale)) }
    for role: InfrastructureRole in [.vpnEndpoint, .vpnDNS, .localAddress] {
        let extra = try InfrastructureRequirement(id: "x", role: role, cidr: IPv4CIDR("192.0.2.1/32"))
        #expect(throws: WireGuardAssemblyError.underlayMismatch) { try prepare(underlay: .init(context: assemblyContext, infrastructure: [extra])) }
    }
    #expect(throws: WireGuardAssemblyError.underlayMismatch) {
        try prepare(underlay: .init(context: assemblyContext, infrastructure: [], wireGuardPeers: []))
    }
}

@Test func assemblyJoinsSuppliedUnderlayWithoutTrustingItsIDs() throws {
    let extra = try InfrastructureRequirement(id: "wg-local-1", role: .physicalLAN, cidr: IPv4CIDR("192.0.2.0/24"))
    let result = try prepare(policy: .init(defaultAction: .vpn, rules: []),
                             underlay: .init(context: assemblyContext, infrastructure: [extra]))
    #expect(result.constrained.decision(for: try IPv4Address("192.0.2.50")).action == .direct)
    #expect(result.constrained.decision(for: try IPv4Address("192.0.2.50")).infrastructureIDs == ["underlay-1"])
}

@Test func assemblyRejectsEmptyAndOversizedCollections() {
    for input in [source(addresses: []), source(addresses: Array(repeating: "10.8.0.2/24", count: 65)),
                  source(peers: []), source(peers: Array(repeating: .init(endpoint: "198.51.100.20:1", allowedIPs: []), count: 65)),
                  source(dns: Array(repeating: "10.9.0.53", count: 33)),
                  source(ranges: Array(repeating: "0.0.0.0/0", count: 2049))] {
        #expect(throws: WireGuardAssemblyError.inputLimit) { try prepare(input) }
    }
    #expect(throws: SettingsError.invalidAddress) { try prepare(source(addresses: ["10.8.0.2/24", "10.8.0.2/32"])) }
}

@Test func assemblyCountsCombinedInfrastructureBudget() throws {
    let extra = try InfrastructureRequirement(id: "x", role: .systemReserved, cidr: IPv4CIDR("127.0.0.0/8"))
    #expect(throws: PolicyCompilationError.self) {
        try prepare(underlay: .init(context: assemblyContext, infrastructure: Array(repeating: extra, count: 256)))
    }
}

@Test func assemblyDoesNotSilentlyEnableUnsupportedRulesOrGuarantees() {
    #expect(throws: PolicyCompilationError.self) { try prepare(policy: .init(defaultAction: .direct, rules: [.init(id: "domain", match: .domain("corp.invalid"), action: .vpn)])) }
    #expect(throws: PolicyCompilationError.self) { try prepare(policy: .init(defaultAction: .vpn, rules: [], requiredGuarantees: [.failClosed])) }
    #expect(throws: SettingsError.emptyVPN) { try prepare(policy: .init(defaultAction: .direct, rules: [])) }
    #expect(throws: SettingsError.wrongBackend) { try prepare(context: .init(sessionID: "x", backendID: "openvpn", generation: 1, networkEpoch: 1)) }
}

@Test func assemblyChecksFullSourceRuleAndTopologyNotJustGeneration() throws {
    let result = try prepare()
    try result.check(source: result.source, policy: result.policy, underlay: result.underlay, dnsSelection: result.dnsSelection, context: assemblyContext)
    for changed in [source(mtu: 1380), source(endpoint: "198.51.100.20:51821"), source(dns: ["10.9.0.53"]),
                    source(addresses: ["10.8.0.3/24"]), source(ranges: ["10.9.0.0/16"])] {
        #expect(throws: WireGuardAssemblyError.sourceChanged) {
            try result.check(source: changed, policy: result.policy, underlay: result.underlay, dnsSelection: result.dnsSelection, context: assemblyContext)
        }
    }
    #expect(throws: WireGuardAssemblyError.sourceChanged) {
        try result.check(source: result.source, policy: .init(defaultAction: .vpn, rules: []), underlay: result.underlay, dnsSelection: result.dnsSelection, context: assemblyContext)
    }
    #expect(throws: WireGuardAssemblyError.sourceChanged) {
        try result.check(source: result.source, policy: result.policy, underlay: result.underlay,
                         dnsSelection: .useConfigurationAsDefault, context: assemblyContext)
    }
    #expect(throws: SettingsError.contextChanged) {
        try result.check(source: result.source, policy: result.policy, underlay: result.underlay, dnsSelection: result.dnsSelection,
                         context: .init(sessionID: "assembly-test", backendID: "wireguard", generation: 8, networkEpoch: 2))
    }
}

@Test func assemblyRouteBudgetIsAppliedWithoutTruncation() {
    #expect(throws: (any Error).self) { try prepare(limits: .init(maxRoutes: 1)) }
}
