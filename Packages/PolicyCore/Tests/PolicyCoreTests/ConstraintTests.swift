// SPDX-License-Identifier: MIT
import XCTest
@testable import PolicyCore

private func requirement(_ id: String, _ role: InfrastructureRole, _ cidr: String) throws -> InfrastructureRequirement {
    try .init(id: id, role: role, cidr: IPv4CIDR(cidr))
}
private func peer(_ id: String = "peer-1", _ cidrs: [String] = ["0.0.0.0/0"]) throws -> WireGuardPeerRange {
    try .init(id: id, allowedIPs: cidrs.map(IPv4CIDR.init))
}
private func constrained(_ rules: [PolicyRule] = [], defaultAction: PolicyAction = .direct,
                         requirements: [InfrastructureRequirement] = [],
                         peers: [WireGuardPeerRange]? = nil,
                         backend: BackendCapabilities = .wireGuard,
                         limits: CompilationLimits = .init(), budget: ConstraintLimits = .init()) throws -> ConstrainedIPv4PolicyPlan {
    let ranges = try peers ?? (backend.kind == .wireGuard ? [peer()] : [])
    let context = testContext(backend.backendID)
    return try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: defaultAction, rules: rules),
        capabilities: backend, context: context,
        constraints: .init(context: context, infrastructure: requirements,
            wireGuardPeers: backend.kind == .wireGuard ? ranges : peers),
        limits: limits, constraintLimits: budget)
}

final class ConstraintTests: XCTestCase {
    func testEndpointDefaultVPNBecomesVisibleDirectException() throws {
        let r = try requirement("endpoint", .vpnEndpoint, "198.51.100.11/32")
        let plan = try constrained(defaultAction: .vpn, requirements: [r])
        let d = plan.decision(for: try IPv4Address("198.51.100.11"))
        XCTAssertEqual(d.action, .direct)
        XCTAssertEqual(d.policyDecision.action, .vpn)
        XCTAssertEqual(d.policyDecision.origin, .defaultPolicy)
        XCTAssertTrue(d.changesDefaultAction)
        XCTAssertEqual(d.infrastructureIDs, ["endpoint"])
        XCTAssertNil(d.wireGuardPeerID)
        XCTAssertEqual(plan.infrastructureEvaluations[0].defaultExceptionCIDRs, [r.cidr])
        XCTAssertEqual(plan.userIntent.routes.map(\.action), [.vpn])
    }

    func testExplicitVPNEndpointRuleIsNotSilentlyOverridden() throws {
        for cidr in ["198.51.100.11/32", "198.51.100.0/24", "0.0.0.0/0"] {
            assertRejection(.infrastructureConflict, "explicit_rule_conflicts_with_infrastructure", ruleID: "user-route") {
                _ = try constrained([rule("user-route", cidr, .vpn)], requirements: [requirement("endpoint", .vpnEndpoint, "198.51.100.11/32")])
            }
        }
    }

    func testVPNDNSAddedFromDefaultDirectAndCoveredByPeer() throws {
        let dns = try requirement("resolver", .vpnDNS, "10.42.0.53/32")
        let plan = try constrained(requirements: [dns], peers: [peer("corp", ["10.42.0.0/16"])])
        let d = plan.decision(for: try IPv4Address("10.42.0.53"))
        XCTAssertEqual(d.action, .vpn)
        XCTAssertTrue(d.changesDefaultAction)
        XCTAssertEqual(d.infrastructureIDs, ["resolver"])
        XCTAssertEqual(d.wireGuardPeerID, "corp")
        XCTAssertEqual(plan.overrides.map(\.cidr), [dns.cidr])
    }

    func testExplicitDirectDNSRuleRejectedEvenIfBroad() throws {
        assertRejection(.infrastructureConflict, "explicit_rule_conflicts_with_infrastructure", ruleID: "local") {
            _ = try constrained([rule("local", "10.0.0.0/8", .direct)],
                requirements: [requirement("resolver", .vpnDNS, "10.42.0.53/32")])
        }
    }

    func testInfrastructureDNSMustAlsoBeWithinAllowedIPs() throws {
        assertRejection(.peerUnreachableRange, "vpn_region_outside_allowed_ips", requirementID: "resolver") {
            _ = try constrained(requirements: [requirement("resolver", .vpnDNS, "10.43.0.53/32")],
                peers: [peer("corp", ["10.42.0.0/16"])])
        }
    }

    func testMatchingExplicitRuleKeepsSourceWithoutInventingException() throws {
        let dns = try requirement("resolver", .vpnDNS, "10.42.0.53/32")
        let plan = try constrained([rule("corp", "10.42.0.0/16", .vpn)], requirements: [dns])
        let d = plan.decision(for: try IPv4Address("10.42.0.53"))
        XCTAssertEqual(d.policyDecision.origin, .rule("corp"))
        XCTAssertFalse(d.changesDefaultAction)
        XCTAssertTrue(plan.infrastructureEvaluations[0].defaultExceptionCIDRs.isEmpty)
    }

    func testGatewayLANAndLocalSystemAddressesGetNamedDefaultExceptions() throws {
        let requirements = try [requirement("gateway", .physicalGateway, "192.0.2.1/32"),
            requirement("lan", .physicalLAN, "192.0.2.0/24"), requirement("local", .localAddress, "192.0.2.20/32"),
            requirement("loopback", .systemReserved, "127.0.0.0/8")]
        let plan = try constrained(defaultAction: .vpn, requirements: requirements)
        XCTAssertEqual(plan.overrides.map(\.cidr.description), ["127.0.0.0/8", "192.0.2.0/24"])
        XCTAssertEqual(plan.decision(for: try IPv4Address("192.0.2.1")).infrastructureIDs, ["gateway", "lan"])
        XCTAssertEqual(plan.decision(for: try IPv4Address("192.0.2.20")).infrastructureIDs, ["lan", "local"])
        XCTAssertEqual(plan.infrastructureEvaluations.map(\.requirement.id), ["gateway", "lan", "local", "loopback"])
    }

    func testPhysicalLANAndCorporateVPNOverlapRejected() throws {
        assertRejection(.infrastructureConflict, "explicit_rule_conflicts_with_infrastructure", ruleID: "corp") {
            _ = try constrained([rule("corp", "10.0.0.0/8", .vpn)],
                requirements: [requirement("local-lan", .physicalLAN, "10.42.0.0/16")])
        }
    }

    func testOppositeInfrastructureRequirementsRejected() throws {
        assertRejection(.infrastructureConflict, "contradictory_infrastructure") {
            _ = try constrained(requirements: [requirement("a-endpoint", .vpnEndpoint, "10.42.0.53/32"),
                requirement("b-resolver", .vpnDNS, "10.42.0.53/32")])
        }
        assertRejection(.infrastructureConflict, "contradictory_infrastructure") {
            _ = try constrained(requirements: [requirement("lan", .physicalLAN, "10.42.0.0/16"),
                requirement("resolver", .vpnDNS, "10.42.0.53/32")])
        }
    }

    func testDisabledOrShadowedConflictDoesNotOverrideFirstMatch() throws {
        let req = try requirement("endpoint", .vpnEndpoint, "198.51.100.11/32")
        let plan = try constrained([rule("allow", "198.51.100.0/24", .direct),
            rule("shadowed", "198.51.100.11/32", .vpn), rule("disabled", "0.0.0.0/0", .vpn, enabled: false)],
            defaultAction: .vpn, requirements: [req])
        XCTAssertEqual(plan.decision(for: try IPv4Address("198.51.100.11")).policyDecision.origin, .rule("allow"))
        XCTAssertEqual(plan.userIntent.ruleEvaluations[1].effect, .fullyShadowed)
        XCTAssertTrue(plan.infrastructureEvaluations[0].defaultExceptionCIDRs.isEmpty)
    }

    func testExactPeerCoverageAndUnchangedInput() throws {
        let input = try [peer("corp", ["10.42.0.0/16"])]
        let plan = try constrained([rule("corp-rule", "10.42.0.0/16", .vpn)], peers: input)
        XCTAssertEqual(plan.input.wireGuardPeers, input)
        XCTAssertEqual(plan.peerAssignments, [.init(cidr: try IPv4CIDR("10.42.0.0/16"), peerID: "corp")])
    }

    func testPartialAndCompletelyMissingPeerCoverageRejected() throws {
        for ranges in [["10.42.0.0/17"], ["10.43.0.0/16"], []] {
            assertRejection(.peerUnreachableRange, "vpn_region_outside_allowed_ips", ruleID: "corp") {
                _ = try constrained([rule("corp", "10.42.0.0/16", .vpn)], peers: [peer("p", ranges)])
            }
        }
    }

    func testCoverageMayBeUnionAcrossPrefixesAndPeers() throws {
        let plan = try constrained([rule("corp", "10.42.0.0/16", .vpn)],
            peers: [peer("left", ["10.42.0.0/17"]), peer("right", ["10.42.128.0/17"])])
        XCTAssertEqual(plan.peerAssignments.map(\.peerID), ["left", "right"])
        XCTAssertEqual(plan.peerAssignments.reduce(UInt64(0)) { $0 + $1.cidr.addressCount }, 65_536)
    }

    func testOneAddressHoleInAllowedIPsIsDetected() throws {
        assertRejection(.peerUnreachableRange, "vpn_region_outside_allowed_ips") {
            _ = try constrained([rule("net", "10.42.0.0/30", .vpn)], peers: [peer("p", ["10.42.0.0/31", "10.42.0.2/32"])])
        }
    }

    func testPeerSelectionUsesLongestPrefixNotArrayOrder() throws {
        let broad = try peer("wide", ["10.0.0.0/8"])
        let narrow = try peer("specific", ["10.42.0.0/16"])
        let rules = try [rule("first", "10.0.0.0/8", .vpn), rule("shadowed", "10.42.0.0/16", .direct)]
        for input in [[broad, narrow], [narrow, broad]] {
            let plan = try constrained(rules, peers: input)
            let d = plan.decision(for: try IPv4Address("10.42.0.1"))
            XCTAssertEqual(d.policyDecision.origin, .rule("first"))
            XCTAssertEqual(d.wireGuardPeerID, "specific")
            XCTAssertEqual(plan.decision(for: try IPv4Address("10.43.0.1")).wireGuardPeerID, "wide")
        }
    }

    func testEqualPrefixAcrossPeersRejectedWithoutLastWriterWins() throws {
        assertRejection(.ruleUnrepresentable, "ambiguous_peer_prefix") {
            _ = try constrained(peers: [peer("one", ["10.42.0.0/16"]), peer("two", ["10.42.7.8/16"])])
        }
    }

    func testDuplicatePrefixWithinSamePeerIsHarmlessButPreserved() throws {
        let input = try [peer("p", ["10.42.0.0/16", "10.42.3.4/16"])]
        let plan = try constrained([rule("corp", "10.42.0.0/16", .vpn)], peers: input)
        XCTAssertEqual(plan.input.wireGuardPeers, input)
        XCTAssertEqual(plan.peerAssignments.count, 1)
    }

    func testShadowedOutOfPeerRangeDoesNotFailEffectiveCoverage() throws {
        let plan = try constrained([rule("direct", "10.0.0.0/8", .direct), rule("shadowed", "10.43.0.0/16", .vpn)],
            peers: [peer("p", ["10.42.0.0/16"])])
        XCTAssertTrue(plan.peerAssignments.isEmpty)
    }

    func testDefaultVPNRequiresCoverageOfDefaultRegions() throws {
        assertRejection(.peerUnreachableRange, "vpn_region_outside_allowed_ips") {
            _ = try constrained(defaultAction: .vpn, peers: [peer("p", ["10.42.0.0/16"])])
        }
        let plan = try constrained(defaultAction: .vpn, peers: [peer()])
        XCTAssertEqual(plan.peerAssignments[0].cidr.description, "0.0.0.0/0")
    }

    func testExplicitDirectHoleNeedNotHavePeer() throws {
        let plan = try constrained([rule("hole", "128.0.0.0/1", .direct)], defaultAction: .vpn,
            peers: [peer("half", ["0.0.0.0/1"])])
        XCTAssertEqual(plan.peerAssignments.map(\.cidr.description), ["0.0.0.0/1"])
        XCTAssertNil(plan.decision(for: IPv4Address(rawValue: .max)).wireGuardPeerID)
    }

    func testEmptyPeersValidOnlyWhenNoEffectiveVPNDestinations() throws {
        XCTAssertTrue(try constrained(peers: []).peerAssignments.isEmpty)
        assertRejection(.peerUnreachableRange, "vpn_region_outside_allowed_ips") {
            _ = try constrained(defaultAction: .vpn, peers: [])
        }
    }

    func testUnknownPeerInputCannotSkipWireGuardValidation() throws {
        assertRejection(.capabilityUnsupported, "wireguard_peer_ranges_required") {
            _ = try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: .direct, rules: []), capabilities: .wireGuard,
                context: testContext(), constraints: .init(context: testContext(), infrastructure: []))
        }
    }

    func testOpenVPNAndExternalDoNotAssumeWireGuardCoverage() throws {
        for backend in [BackendCapabilities.openVPN, .external] {
            let plan = try constrained(defaultAction: .vpn, requirements: [requirement("endpoint", .vpnEndpoint, "198.51.100.11/32")], backend: backend)
            XCTAssertTrue(plan.peerAssignments.isEmpty)
            XCTAssertEqual(plan.overrides.map(\.action), [.direct])
            assertRejection(.capabilityUnsupported, "peer_ranges_for_non_wireguard") {
                _ = try constrained(defaultAction: .vpn, peers: [peer()], backend: backend)
            }
        }
    }

    func testMissingOrAmbiguousIdentifiersRejectedWithoutEcho() throws {
        for id in ["", "not an id", "private.example", "a\n", String(repeating: "x", count: 129)] {
            assertRejection(.ruleUnrepresentable, "invalid_requirement_id") {
                _ = try constrained(requirements: [requirement(id, .physicalLAN, "10.0.0.0/8")])
            }
            assertRejection(.ruleUnrepresentable, "invalid_peer_id") { _ = try constrained(peers: [peer(id)]) }
        }
        let r = try requirement("r", .physicalLAN, "10.0.0.0/8")
        assertRejection(.ruleUnrepresentable, "duplicate_requirement_id") { _ = try constrained(requirements: [r, r]) }
        assertRejection(.ruleUnrepresentable, "duplicate_peer_id") { _ = try constrained(peers: [peer(), peer()]) }
    }

    func testHostInfrastructureRejectsNetworkPrefixes() throws {
        for role in [InfrastructureRole.vpnEndpoint, .vpnDNS, .physicalGateway, .localAddress] {
            assertRejection(.ruleUnrepresentable, "infrastructure_host_required") {
                _ = try constrained(requirements: [requirement("r", role, "10.0.0.0/8")])
            }
        }
    }

    func testStaleFutureSessionBackendAndEpochRejected() throws {
        let variants = [testContext(session: "other"), testContext("openvpn"), testContext(generation: 6),
                        testContext(generation: 8), testContext(epoch: 2), testContext(epoch: 4)]
        for candidate in variants {
            let expected: DiagnosticCode = candidate.networkEpoch != testContext().networkEpoch ? .networkEpochChanged : .ruleUnrepresentable
            assertRejection(expected, "constraint_context_mismatch") {
                _ = try IPv4ConstrainedPolicyCompiler.compile(.init(defaultAction: .direct, rules: []), capabilities: .wireGuard,
                    context: testContext(), constraints: .init(context: candidate, infrastructure: [], wireGuardPeers: []))
            }
        }
    }

    func testContextAndLimitationsRemainExplicitInResult() throws {
        let plan = try constrained()
        XCTAssertEqual(plan.checkContext(against: testContext()), .current)
        XCTAssertEqual(plan.checkContext(against: testContext(epoch: 4)), .differentNetworkEpoch)
        XCTAssertTrue(plan.userIntent.limitations.contains(.planningOnly))
        XCTAssertEqual(plan.limitations, [.suppliedTopologyOnly, .underlayMechanismNotValidated, .reachabilityNotTested])
    }

    func testLimitsRejectInputsAndUnapprovedIncreases() throws {
        let r = try requirement("r", .physicalLAN, "10.0.0.0/8")
        assertRejection(.limitExceeded, "infrastructure_count_limit") {
            _ = try constrained(requirements: [r, requirement("r2", .physicalLAN, "11.0.0.0/8")], budget: .init(maxRequirements: 1))
        }
        assertRejection(.limitExceeded, "peer_count_limit") {
            _ = try constrained(peers: [peer("one"), peer("two")], budget: .init(maxPeers: 1))
        }
        assertRejection(.limitExceeded, "allowed_prefix_count_limit") {
            _ = try constrained(peers: [peer("one", ["0.0.0.0/1", "128.0.0.0/1"])], budget: .init(maxAllowedPrefixes: 1))
        }
        for budget in [ConstraintLimits(maxRequirements: 0), .init(maxRequirements: 257), .init(maxPeers: -1),
                       .init(maxPeers: 65), .init(maxAllowedPrefixes: 0), .init(maxAllowedPrefixes: 2049),
                       .init(maxExplanationRegions: 0), .init(maxExplanationRegions: 16385)] {
            assertRejection(.limitExceeded, "invalid_constraint_limits") { _ = try constrained(budget: budget) }
        }
    }

    func testInfrastructureAddedRoutesMustFitFinalBudget() throws {
        let r = try requirement("dns", .vpnDNS, "10.42.0.53/32")
        XCTAssertEqual(try constrained(requirements: [r], limits: .init(maxRoutes: 33)).routes.count, 33)
        assertRejection(.limitExceeded, "constrained_route_limit") {
            _ = try constrained(requirements: [r], limits: .init(maxRoutes: 32))
        }
    }

    func testPeerAssignmentsAndExplanationsHaveIndependentBudgets() throws {
        assertRejection(.limitExceeded, "peer_assignment_limit") {
            _ = try constrained(defaultAction: .vpn, peers: [peer("all"), peer("specific", ["10.42.0.53/32"])], limits: .init(maxRoutes: 1))
        }
        assertRejection(.limitExceeded, "constraint_explanation_limit") {
            _ = try constrained(requirements: [requirement("host", .localAddress, "10.42.0.53/32")], budget: .init(maxExplanationRegions: 1))
        }
    }

    func testExtremalAddressesAndWholeSpaceRequirements() throws {
        let reqs = try [requirement("zero", .localAddress, "0.0.0.0/32"),
                        requirement("last", .localAddress, "255.255.255.255/32")]
        let plan = try constrained(defaultAction: .vpn, requirements: reqs)
        XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: 0)).action, .direct)
        XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: .max)).action, .direct)
        XCTAssertEqual(plan.routes.reduce(UInt64(0)) { $0 + $1.cidr.addressCount }, UInt64(1) << 32)
        let whole = try constrained(defaultAction: .vpn, requirements: [requirement("all", .systemReserved, "0.0.0.0/0")])
        XCTAssertEqual(whole.routes.map(\.cidr.description), ["0.0.0.0/0"])
        XCTAssertEqual(whole.routes[0].action, .direct)
        XCTAssertEqual(whole.infrastructureEvaluations[0].defaultExceptionCIDRs[0].addressCount, UInt64(1) << 32)
    }

    func testDiagnosticsDoNotRevealRawTopologyValues() throws {
        do {
            _ = try constrained([rule("opaque-rule", "198.51.100.11/32", .vpn)],
                requirements: [requirement("opaque-requirement", .vpnEndpoint, "198.51.100.11/32")])
            XCTFail("Expected conflict")
        } catch let error as PolicyCompilationError {
            let description = String(describing: error)
            XCTAssertFalse(description.contains("198.51.100.11"))
            XCTAssertEqual(error.diagnostics[0].requirementID, "opaque-requirement")
            XCTAssertFalse(error.diagnostics[0].retryable)
        }
    }

    func testDeterministicOrderAndAdjacentPeersDoNotChangeUserRoutes() throws {
        let a = try peer("a", ["0.0.0.0/1"])
        let b = try peer("b", ["128.0.0.0/1"])
        let first = try constrained(defaultAction: .vpn, peers: [a, b])
        let second = try constrained(defaultAction: .vpn, peers: [b, a])
        XCTAssertEqual(first.routes, second.routes)
        XCTAssertEqual(first.effectiveRegions, second.effectiveRegions)
        XCTAssertEqual(first.peerAssignments, second.peerAssignments)
        XCTAssertEqual(first.routes.map(\.cidr.description), ["0.0.0.0/0"])
        XCTAssertEqual(first.peerAssignments.count, 2)
    }

    func testExhaustiveSmallNetworkAgainstIndependentReference() throws {
        let start = try IPv4Address("10.42.0.0").rawValue
        var comparisons = 0
        for seed in 0..<32 {
            let requirements = try (0..<8).map { n in
                try requirement("infra-\(n)", n.isMultiple(of: 2) ? .vpnDNS : .localAddress,
                    "10.42.0.\((seed * 7 + n * 29) % 256)/32")
            }
            let peers = try [peer("base", ["10.42.0.0/24"]), peer("left", ["10.42.0.0/25"]),
                             peer("tiny", ["10.42.0.192/27"])]
            let rules = try [rule("irrelevant", "192.0.2.0/24", .direct)]
            let plan = try constrained(rules, requirements: requirements, peers: peers)
            for offset in 0..<256 {
                let address = IPv4Address(rawValue: start + UInt32(offset))
                let refs = requirements.filter { $0.cidr.contains(address) }
                let action = refs.first?.role.requiredAction ?? .direct
                let expectedPeer = action == .vpn ? peers.flatMap { p in
                    p.allowedIPs.filter { $0.contains(address) }.map { (p.id, $0.prefixLength) }
                }.max(by: { $0.1 < $1.1 })?.0 : nil
                let decision = plan.decision(for: address)
                XCTAssertEqual(decision.action, action)
                XCTAssertEqual(decision.wireGuardPeerID, expectedPeer)
                XCTAssertEqual(decision.infrastructureIDs, refs.map(\.id).sorted())
                XCTAssertEqual(plan.routes.filter { $0.cidr.contains(address) }.count, 1)
                XCTAssertEqual(plan.routes.first { $0.cidr.contains(address) }?.action, action)
                comparisons += 1
            }
            var next: UInt64 = 0
            for region in plan.effectiveRegions {
                XCTAssertEqual(UInt64(region.cidr.networkAddress.rawValue), next)
                next += region.cidr.addressCount
            }
            XCTAssertEqual(next, UInt64(1) << 32)
        }
        XCTAssertEqual(comparisons, 8_192)
        print("T-P10 exhaustive reference: 32 cases, \(comparisons) address comparisons")
    }

    func testDefaultExceptionOnlyIncludesPreviouslyUnmatchedPart() throws {
        let plan = try constrained([rule("explicit-direct", "192.0.2.0/25", .direct)], defaultAction: .vpn,
            requirements: [requirement("lan", .physicalLAN, "192.0.2.0/24")])
        XCTAssertEqual(plan.infrastructureEvaluations[0].defaultExceptionCIDRs.map(\.description), ["192.0.2.128/25"])
        XCTAssertFalse(plan.decision(for: try IPv4Address("192.0.2.1")).changesDefaultAction)
        XCTAssertTrue(plan.decision(for: try IPv4Address("192.0.2.129")).changesDefaultAction)
    }

    func testPeerAssignmentsNeverMergeAcrossDirectHole() throws {
        let plan = try constrained([rule("corp", "10.42.0.0/24", .vpn)],
            requirements: [requirement("dns", .vpnDNS, "10.42.0.53/32")], peers: [peer("p", ["10.42.0.0/24"])])
        // Same-peer ranges with distinct requirement provenance do merge.
        XCTAssertEqual(plan.peerAssignments.map(\.cidr.description), ["10.42.0.0/24"])
        let hole = try constrained([rule("hole", "10.42.0.128/26", .direct), rule("corp", "10.42.0.0/24", .vpn)],
            peers: [peer("p", ["10.42.0.0/24"])])
        XCTAssertEqual(hole.peerAssignments.reduce(UInt64(0)) { $0 + $1.cidr.addressCount }, 192)
        let excluded = try IPv4Address("10.42.0.130")
        XCTAssertTrue(hole.peerAssignments.allSatisfy { !$0.cidr.contains(excluded) })
    }

    func testRequirementsMayHaveSameIDAsUserRuleWithoutProvenanceCollision() throws {
        let plan = try constrained([rule("same", "10.42.0.0/16", .vpn)],
            requirements: [requirement("same", .vpnDNS, "10.42.0.53/32")])
        let decision = plan.decision(for: try IPv4Address("10.42.0.53"))
        XCTAssertEqual(decision.policyDecision.origin, .rule("same"))
        XCTAssertEqual(decision.infrastructureIDs, ["same"])
    }

    private func assertRejection(_ code: DiagnosticCode, _ reason: String, ruleID: String? = nil,
                                 requirementID: String? = nil, file: StaticString = #filePath, line: UInt = #line,
                                 _ operation: () throws -> Void) {
        do { try operation(); XCTFail("Expected rejection: \(reason)", file: file, line: line) }
        catch let error as PolicyCompilationError {
            XCTAssertTrue(error.diagnostics.contains { $0.code == code && $0.reason == reason }, "\(error)", file: file, line: line)
            if let ruleID { XCTAssertTrue(error.diagnostics.contains { $0.ruleID == ruleID }, file: file, line: line) }
            if let requirementID { XCTAssertTrue(error.diagnostics.contains { $0.requirementID == requirementID }, file: file, line: line) }
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
}
