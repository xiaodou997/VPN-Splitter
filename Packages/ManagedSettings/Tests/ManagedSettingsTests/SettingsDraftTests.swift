// SPDX-License-Identifier: MIT
import Testing
import PolicyCore
import ManagedSettings

private func context(session: String = "test", backend: String = "wireguard", generation: UInt64 = 3,
                     epoch: UInt64 = 5) -> PlanContext {
    .init(sessionID: session, backendID: backend, generation: generation, networkEpoch: epoch)
}
private func rule(_ id: String, _ cidr: String, _ action: PolicyAction, enabled: Bool = true) throws -> PolicyRule {
    .init(id: id, match: .ipv4(try IPv4CIDR(cidr)), action: action, enabled: enabled)
}
private func peers(_ cidrs: [String] = ["0.0.0.0/0"]) throws -> [WireGuardPeerRange] {
    [.init(id: "peer-1", allowedIPs: try cidrs.map(IPv4CIDR.init))]
}
private func input(ctx: PlanContext = context(), dns: ManagedDNSChoice = .keepSystemExplicitly,
                   peerTable: [WireGuardPeerRange]? = nil, mtu: ManagedMTU = .explicit(1420),
                   addresses: [TunnelIPv4Address]? = nil, endpoints: [IPv4Address]? = nil) throws -> SettingsInput {
    .init(context: ctx, addresses: try addresses ?? [TunnelIPv4Address("10.8.0.2/24")],
          endpoints: try endpoints ?? [IPv4Address("203.0.113.9")], protocolPeers: try peerTable ?? peers(),
          dns: dns, mtu: mtu)
}
private func requirements(_ input: SettingsInput) throws -> [InfrastructureRequirement] {
    var result: [InfrastructureRequirement] = []
    for (i, host) in input.endpoints.enumerated() {
        result.append(.init(id: "endpoint-\(i)", role: .vpnEndpoint, cidr: try IPv4CIDR("\(host)/32")))
    }
    for (i, host) in input.addresses.enumerated() {
        result.append(.init(id: "address-\(i)", role: .localAddress, cidr: try IPv4CIDR("\(host.address)/32")))
    }
    if case .tunnelDefault(let servers) = input.dns {
        for (i, host) in servers.enumerated() {
            result.append(.init(id: "dns-\(i)", role: .vpnDNS, cidr: try IPv4CIDR("\(host)/32")))
        }
    }
    return result
}
private func plan(_ input: SettingsInput, defaultAction: PolicyAction = .direct,
                  rules: [PolicyRule] = [], declared: [InfrastructureRequirement]? = nil) throws -> ConstrainedIPv4PolicyPlan {
    try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: defaultAction, rules: rules),
        capabilities: .wireGuard, context: input.context,
        constraints: .init(context: input.context, infrastructure: try declared ?? requirements(input),
                           wireGuardPeers: input.protocolPeers))
}
// Independent interpretation of the emitted route representation, NOT an OS probe.
private func representedAction(_ draft: ManagedSettingsDraft, _ address: IPv4Address) -> PolicyAction {
    if draft.excludedRoutes.contains(where: { $0.cidr.contains(address) }) { return .direct }
    return draft.includedRoutes.contains(where: { $0.cidr.contains(address) }) ? .vpn : .direct
}

@Test func fullProtocolAllowedIPsDoNotBecomeSystemDefaultRouteInInclude() throws {
    let input = try input()
    let original = input.protocolPeers
    let plan = try plan(input, rules: [rule("corp", "10.9.0.0/16", .vpn)])
    let draft = try ManagedSettingsDraft.prepare(plan, input: input)
    #expect(draft.mode == .include)
    #expect(draft.includedRoutes.map(\.destination) == ["10.9.0.0"])
    #expect(draft.includedRoutes.map(\.subnetMask) == ["255.255.0.0"])
    #expect(draft.input.protocolPeers == original && plan.input.wireGuardPeers == original)
    #expect(!draft.includedRoutes.contains { $0.cidr.prefixLength == 0 })
    #expect(try representedAction(draft, IPv4Address("198.51.100.7")) == .direct)
}

@Test func interfaceHostAndMaskSurviveWithoutIncludingTheWholeConnectedSubnet() throws {
    let input = try input()
    let draft = try ManagedSettingsDraft.prepare(plan(input, rules: [rule("corp", "10.9.0.0/16", .vpn)]), input: input)
    #expect(draft.input.addresses[0].address.description == "10.8.0.2")
    #expect(draft.input.addresses[0].subnetMask == "255.255.255.0")
    #expect(try representedAction(draft, IPv4Address("10.8.0.99")) == .direct)
    #expect(draft.excludedRoutes.contains { $0.cidr.contains(input.addresses[0].address) })
}

@Test(arguments: ["10.8.0.2", "10.8.0.02/24", "10.8/24", "10.8.0.2/33", "::1/128", "secret.example/24", "10.8.0.2/024"])
func malformedInterfaceDoesNotLeakOrResolve(_ value: String) {
    #expect(throws: SettingsError.invalidAddress) { try TunnelIPv4Address(value) }
    #expect(!SettingsError.invalidAddress.rawValue.contains(value))
}

@Test func interfaceEdgeMasks() throws {
    #expect(try TunnelIPv4Address("10.8.0.2/0").subnetMask == "0.0.0.0")
    #expect(try TunnelIPv4Address("10.8.0.2/32").subnetMask == "255.255.255.255")
}

@Test func bypassUsesDefaultPlusExactDirectPartition() throws {
    let input = try input()
    let plan = try plan(input, defaultAction: .vpn, rules: [rule("exception", "198.51.100.7/32", .direct)])
    let draft = try ManagedSettingsDraft.prepare(plan, input: input)
    #expect(draft.mode == .bypass)
    #expect(draft.includedRoutes.map { $0.cidr.description } == ["0.0.0.0/0"])
    #expect(draft.excludedRoutes.map(\.cidr) == plan.routes.filter { $0.action == .direct }.map(\.cidr))
    for host in ["198.51.100.7", "203.0.113.9", "10.8.0.2"] {
        #expect(try representedAction(draft, IPv4Address(host)) == .direct)
    }
    #expect(try representedAction(draft, IPv4Address("198.51.100.8")) == .vpn)
}

@Test func firstMatchIsNotReplacedByRawLongestPrefixOrdering() throws {
    let input = try input()
    var rules = try [rule("wide", "198.51.100.0/24", .vpn), rule("host", "198.51.100.7/32", .direct)]
    var draft = try ManagedSettingsDraft.prepare(plan(input, rules: rules), input: input)
    #expect(try representedAction(draft, IPv4Address("198.51.100.7")) == .vpn)
    rules.reverse()
    draft = try ManagedSettingsDraft.prepare(plan(input, rules: rules), input: input)
    #expect(try representedAction(draft, IPv4Address("198.51.100.7")) == .direct)
    #expect(try representedAction(draft, IPv4Address("198.51.100.8")) == .vpn)
}

@Test func disabledRulesStayOutsideTheCompiledRepresentation() throws {
    let input = try input()
    let draft = try ManagedSettingsDraft.prepare(plan(input, rules: [
        rule("off", "10.0.0.0/8", .vpn, enabled: false), rule("on", "198.51.100.7/32", .vpn)
    ]), input: input)
    #expect(try representedAction(draft, IPv4Address("10.1.1.1")) == .direct)
}

@Test func explicitInfrastructureConflictAndUnreachablePeerNeverMakeADraft() throws {
    let input = try input(peerTable: peers(["10.9.0.0/16"]))
    #expect(throws: PolicyCompilationError.self) {
        try ManagedSettingsDraft.prepare(plan(input, rules: [rule("endpoint-vpn", "203.0.113.9/32", .vpn)]), input: input)
    }
    #expect(throws: PolicyCompilationError.self) {
        try ManagedSettingsDraft.prepare(plan(input, rules: [rule("outside", "198.51.100.7/32", .vpn)]), input: input)
    }
}

@Test func protocolPeerIdentityAndOrderMustMatchTheCompiledInput() throws {
    let original = try input()
    let plan = try plan(original, rules: [rule("corp", "10.9.0.0/16", .vpn)])
    for table in [try peers(["10.9.0.0/16"]), [.init(id: "different-peer", allowedIPs: [try IPv4CIDR("0.0.0.0/0")])]] {
        #expect(throws: SettingsError.peerMismatch) { try ManagedSettingsDraft.prepare(plan, input: input(peerTable: table)) }
    }
}

@Test func everyContextComponentIsRechecked() throws {
    let original = try input()
    let plan = try plan(original, rules: [rule("corp", "10.9.0.0/16", .vpn)])
    let draft = try ManagedSettingsDraft.prepare(plan, input: original)
    let changes = [context(session: "other"), context(backend: "other"), context(generation: 4),
                   context(generation: 2), context(epoch: 6), context(epoch: 4)]
    for ctx in changes {
        let changed = try input(ctx: ctx)
        #expect(throws: SettingsError.contextChanged) { try ManagedSettingsDraft.prepare(plan, input: changed) }
        #expect(throws: SettingsError.contextChanged) { try draft.check(against: changed) }
    }
    try draft.check(against: original)
}

@Test func sameContextDoesNotPermitChangedMTUDNSOrProtocolInputs() throws {
    let original = try input()
    let draft = try ManagedSettingsDraft.prepare(plan(original, rules: [rule("corp", "10.9.0.0/16", .vpn)]), input: original)
    let changed = try [input(mtu: .explicit(1380)), input(mtu: .automaticOverhead80),
        input(endpoints: [IPv4Address("203.0.113.10")]), input(addresses: [TunnelIPv4Address("10.8.0.7/24")]),
        input(peerTable: peers(["10.9.0.0/16"])), input(dns: .tunnelDefault(servers: [IPv4Address("10.9.0.53")]))]
    for value in changed {
        #expect(throws: SettingsError.infrastructureMismatch) { try draft.check(against: value) }
    }
}

@Test func noExtraOrMissingEndpointAndLocalAddressRequirements() throws {
    let input = try input()
    let required = try requirements(input)
    for role in [InfrastructureRole.vpnEndpoint, .localAddress] {
        let missing = required.filter { $0.role != role }
        #expect(throws: SettingsError.infrastructureMismatch) {
            try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn, declared: missing), input: input)
        }
        var extra = required
        extra.append(.init(id: "extra", role: role, cidr: try IPv4CIDR("203.0.113.222/32")))
        #expect(throws: SettingsError.infrastructureMismatch) {
            try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn, declared: extra), input: input)
        }
    }
}

@Test func allKnownEndpointsAreExcludedNotOnlyDisplayEndpoint() throws {
    let input = try input(endpoints: [IPv4Address("203.0.113.9"), IPv4Address("203.0.113.10")])
    let draft = try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input)
    for address in input.endpoints { #expect(representedAction(draft, address) == .direct) }
}

@Test(arguments: [575, 65536, -1, 0, Int.max])
func invalidMTURejected(_ value: Int) throws {
    let input = try input(mtu: .explicit(value))
    #expect(throws: SettingsError.invalidMTU) { try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input) }
}

@Test(arguments: [576, 1280, 1380, 1420, 65535])
func explicitMTUIsNotSilentlyClamped(_ value: Int) throws {
    let input = try input(mtu: .explicit(value))
    let draft = try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input)
    #expect(draft.input.mtu == .explicit(value))
}

@Test func automaticMTURemainsAnExplicitCandidateChoice() throws {
    let input = try input(mtu: .automaticOverhead80)
    #expect(try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input).input.mtu == .automaticOverhead80)
}

@Test func emptyTunnelIsNotConvertedIntoFullTunnel() throws {
    let input = try input()
    #expect(throws: SettingsError.emptyVPN) { try ManagedSettingsDraft.prepare(plan(input), input: input) }
}

@Test func DNSDefaultOnlyInBypassWithExactProtectedVPNResolvers() throws {
    let server = try IPv4Address("10.9.0.53")
    let input = try input(dns: .tunnelDefault(servers: [server]))
    let draft = try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input)
    #expect(draft.input.dns == .tunnelDefault(servers: [server]))
    #expect(representedAction(draft, server) == .vpn)
    #expect(throws: SettingsError.dnsChoice) {
        try ManagedSettingsDraft.prepare(plan(input, rules: [rule("corp", "10.9.0.0/16", .vpn)]), input: input)
    }
    let missing = try requirements(input).filter { $0.role != .vpnDNS }
    #expect(throws: SettingsError.dnsRoute) {
        try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn, declared: missing), input: input)
    }
}

@Test func noDNSServerOrDuplicateServersCannotMeanAnImplicitFallback() throws {
    let server = try IPv4Address("10.9.0.53")
    for servers in [[], [server, server], Array(repeating: server, count: 33)] {
        let input = try input(dns: .tunnelDefault(servers: servers))
        #expect(throws: SettingsError.dnsChoice) {
            try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input)
        }
    }
}

@Test func keepSystemDNSChoiceCanRetainUnusedConfiguredDNSRoutesButDoesNotAssignResolver() throws {
    let input = try input()
    var declared = try requirements(input)
    declared.append(.init(id: "dns", role: .vpnDNS, cidr: try IPv4CIDR("10.9.0.53/32")))
    let draft = try ManagedSettingsDraft.prepare(plan(input, declared: declared), input: input)
    #expect(draft.input.dns == .keepSystemExplicitly)
    #expect(try representedAction(draft, IPv4Address("10.9.0.53")) == .vpn)
}

@Test func budgetsIncludeBothIncludedAndExcludedRoutes() throws {
    let input = try input()
    let plan = try plan(input, defaultAction: .vpn)
    let draft = try ManagedSettingsDraft.prepare(plan, input: input)
    let count = draft.includedRoutes.count + draft.excludedRoutes.count
    #expect(try ManagedSettingsDraft.prepare(plan, input: input, maxRoutes: count) == draft)
    for limit in [0, -1, count - 1, CompilationLimits.routeCeiling + 1] {
        #expect(throws: SettingsError.routeLimit) { try ManagedSettingsDraft.prepare(plan, input: input, maxRoutes: limit) }
    }
}

@Test func emptyInputsDuplicateAddressAndNonWireGuardBackendAreRejected() throws {
    let normal = try input()
    let plan = try plan(normal, defaultAction: .vpn)
    #expect(throws: SettingsError.inputLimit) { try ManagedSettingsDraft.prepare(plan, input: input(addresses: [])) }
    #expect(throws: SettingsError.inputLimit) { try ManagedSettingsDraft.prepare(plan, input: input(endpoints: [])) }
    #expect(throws: SettingsError.inputLimit) { try ManagedSettingsDraft.prepare(plan, input: input(peerTable: [])) }
    #expect(throws: SettingsError.invalidAddress) {
        try ManagedSettingsDraft.prepare(plan, input: input(addresses: [TunnelIPv4Address("10.8.0.2/24"), TunnelIPv4Address("10.8.0.2/32")]))
    }
    let other = context(backend: "openvpn")
    let otherPlan = try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: .vpn, rules: []), capabilities: .openVPN,
        context: other, constraints: .init(context: other, infrastructure: []))
    #expect(throws: SettingsError.wrongBackend) { try ManagedSettingsDraft.prepare(otherPlan, input: input(ctx: other)) }
}

@Test func compilerUnsupportedRulesAndGuaranteesStillBlockBeforePreparation() throws {
    let input = try input()
    let constraints = try IPv4ConstraintInput(context: input.context, infrastructure: requirements(input), wireGuardPeers: input.protocolPeers)
    for match in [RuleMatch.domain("synthetic.invalid"), .ipv6CIDR("::/0")] {
        #expect(throws: PolicyCompilationError.self) {
            try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: .vpn, rules: [.init(id: "blocked", match: match, action: .vpn)]),
                capabilities: .wireGuard, context: input.context, constraints: constraints)
        }
    }
    for guarantee in RequiredGuarantee.allCases {
        #expect(throws: PolicyCompilationError.self) {
            try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: .vpn, rules: [], requiredGuarantees: [guarantee]),
                capabilities: .wireGuard, context: input.context, constraints: constraints)
        }
    }
}

@Test func limitationsNeverClaimNetworkOrProtocolSuccess() throws {
    let input = try input()
    let draft = try ManagedSettingsDraft.prepare(plan(input, defaultAction: .vpn), input: input)
    #expect(draft.limitations == SettingsLimitation.allCases)
    #expect(draft.limitations.contains(.inspectionOnly))
    #expect(draft.limitations.contains(.protocolEngineNotLinked))
}

@Test func seededRepresentationMatchesEveryPartitionBoundaryAndRandomAddresses() throws {
    var seed: UInt64 = 0x5E771A65
    func next() -> UInt32 { seed = seed &* 6364136223846793005 &+ 1; return UInt32(truncatingIfNeeded: seed >> 24) }
    let input = try input()
    for trial in 0..<80 {
        let rules = try (0..<24).map { index in
            // Documentation prefixes keep synthetic rules disjoint from the infrastructure.
            let host = "198.51.100.\(next() & 255)"
            let prefix = 24 + Int(next() % 9)
            return try rule("r\(index)", "\(host)/\(prefix)", next() & 1 == 0 ? .direct : .vpn)
        } + [try rule("ensure-vpn", "192.0.2.7/32", .vpn)]
        let compiled = try plan(input, defaultAction: trial & 1 == 0 ? .direct : .vpn, rules: rules)
        let draft = try ManagedSettingsDraft.prepare(compiled, input: input)
        var samples = compiled.routes.flatMap { route -> [IPv4Address] in
            let first = route.cidr.networkAddress.rawValue
            let last = UInt32(UInt64(first) + route.cidr.addressCount - 1)
            return [IPv4Address(rawValue: first), IPv4Address(rawValue: last)]
        }
        samples += (0..<100).map { _ in IPv4Address(rawValue: next()) }
        for address in samples { #expect(representedAction(draft, address) == compiled.decision(for: address).action) }
        #expect(draft.input.protocolPeers == input.protocolPeers)
    }
}

@Test func multiplePeersKeepLongestPrefixAttributionAndRejectReorderedInput() throws {
    let table = [WireGuardPeerRange(id: "wide", allowedIPs: [try IPv4CIDR("0.0.0.0/0")]),
                 WireGuardPeerRange(id: "narrow", allowedIPs: [try IPv4CIDR("10.9.0.0/16")])]
    let original = try input(peerTable: table)
    let compiled = try plan(original, rules: [rule("corp", "10.9.0.0/16", .vpn)])
    let draft = try ManagedSettingsDraft.prepare(compiled, input: original)
    #expect(draft.input.protocolPeers == table)
    #expect(compiled.peerAssignments.allSatisfy { $0.peerID == "narrow" })
    #expect(throws: SettingsError.peerMismatch) {
        try ManagedSettingsDraft.prepare(compiled, input: input(peerTable: table.reversed()))
    }
    let tooManyAddresses = try input(addresses: Array(repeating: TunnelIPv4Address("10.8.0.2/24"), count: 65))
    let tooManyEndpoints = try input(endpoints: Array(repeating: IPv4Address("203.0.113.9"), count: 65))
    let tooManyPeers = try input(peerTable: Array(repeating: table[0], count: 65))
    for oversized in [tooManyAddresses, tooManyEndpoints, tooManyPeers] {
        #expect(throws: SettingsError.inputLimit) { try ManagedSettingsDraft.prepare(compiled, input: oversized) }
    }
}
