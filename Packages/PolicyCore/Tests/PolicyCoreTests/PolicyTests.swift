// SPDX-License-Identifier: MIT
import XCTest
@testable import PolicyCore

func testContext(_ backendID: String = "wireguard", generation: UInt64 = 7,
                 epoch: UInt64 = 3, session: String = "test-session") -> PlanContext {
    PlanContext(sessionID: session, backendID: backendID, generation: generation, networkEpoch: epoch)
}

func rule(_ id: String, _ cidr: String, _ action: PolicyAction, enabled: Bool = true) throws -> PolicyRule {
    try PolicyRule(id: id, match: .ipv4(IPv4CIDR(cidr)), action: action, enabled: enabled)
}

func compile(_ rules: [PolicyRule], defaultAction: PolicyAction = .direct,
             capabilities: BackendCapabilities = .wireGuard,
             limits: CompilationLimits = .init()) throws -> IPv4PolicyPlan {
    try IPv4PolicyCompiler.compile(IPv4Policy(defaultAction: defaultAction, rules: rules),
        capabilities: capabilities, context: testContext(capabilities.backendID), limits: limits)
}

final class PolicyTests: XCTestCase {
    func testEmptyIncludeAndBypassPolicies() throws {
        for action in [PolicyAction.direct, .vpn] {
            let plan = try compile([], defaultAction: action)
            XCTAssertEqual(plan.routes.count, 1)
            XCTAssertEqual(plan.routes[0].cidr.description, "0.0.0.0/0")
            XCTAssertEqual(plan.routes[0].action, action)
            XCTAssertTrue(plan.overrides.isEmpty)
            XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: .max)).origin, .defaultPolicy)
        }
    }

    func testFirstLargeRuleShadowsLaterMoreSpecificRule() throws {
        let plan = try compile([rule("broad", "10.0.0.0/8", .direct), rule("narrow", "10.42.0.0/16", .vpn)])
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.42.1.2")).action, .direct)
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.42.1.2")).origin, .rule("broad"))
        XCTAssertEqual(plan.ruleEvaluations[1].effect, .fullyShadowed)
        XCTAssertEqual(plan.ruleEvaluations[1].effectiveAddressCount, 0)
        XCTAssertTrue(plan.overrides.isEmpty)
    }

    func testReversingOrderChangesMeaning() throws {
        let plan = try compile([rule("narrow", "10.42.0.0/16", .vpn), rule("broad", "10.0.0.0/8", .direct)])
        XCTAssertEqual(plan.overrides.map(\.cidr.description), ["10.42.0.0/16"])
        XCTAssertEqual(plan.ruleEvaluations[1].effect, .partiallyShadowed)
        XCTAssertEqual(plan.ruleEvaluations[1].effectiveAddressCount, 16_777_216 - 65_536)
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.43.0.1")).origin, .rule("broad"))
    }

    func testEarlierDirectHoleCannotBeOverriddenByBroadVPN() throws {
        let plan = try compile([rule("hole", "10.42.0.0/16", .direct), rule("vpn", "10.0.0.0/8", .vpn)])
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.42.0.1")).action, .direct)
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.43.0.1")).action, .vpn)
        XCTAssertEqual(plan.overrides.reduce(UInt64(0)) { $0 + $1.cidr.addressCount }, 16_777_216 - 65_536)
    }

    func testDisabledRuleDoesNotShadow() throws {
        let plan = try compile([rule("off", "0.0.0.0/0", .direct, enabled: false), rule("on", "10.0.0.0/8", .vpn)])
        XCTAssertEqual(plan.ruleEvaluations[0].effect, .disabled)
        XCTAssertEqual(plan.overrides.map(\.cidr.description), ["10.0.0.0/8"])
    }

    func testMergePreservesDistinctRuleProvenance() throws {
        let plan = try compile([rule("left", "10.0.0.0/9", .vpn), rule("right", "10.128.0.0/9", .vpn)])
        XCTAssertEqual(plan.overrides.map(\.cidr.description), ["10.0.0.0/8"])
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.1.0.1")).origin, .rule("left"))
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.129.0.1")).origin, .rule("right"))
    }

    func testSameAsDefaultRetainsAttribution() throws {
        let plan = try compile([rule("explicit", "10.0.0.0/8", .direct)])
        XCTAssertEqual(plan.routes.count, 1)
        XCTAssertEqual(plan.ruleEvaluations[0].effect, .effective)
        XCTAssertEqual(plan.decision(for: try IPv4Address("10.1.2.3")).origin, .rule("explicit"))
        XCTAssertEqual(plan.decision(for: try IPv4Address("11.1.2.3")).origin, .defaultPolicy)
    }

    func testSlashZeroShadowsEverythingLater() throws {
        let plan = try compile([rule("all", "0.0.0.0/0", .vpn), rule("last", "255.255.255.255/32", .direct)])
        XCTAssertEqual(plan.routes.count, 1)
        XCTAssertEqual(plan.ruleEvaluations[0].effectiveAddressCount, 4_294_967_296)
        XCTAssertEqual(plan.ruleEvaluations[1].effect, .fullyShadowed)
    }

    func testEndpointsOfEntireIPv4Space() throws {
        let plan = try compile([rule("zero", "0.0.0.0/32", .vpn), rule("last", "255.255.255.255/32", .vpn)])
        XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: 0)).origin, .rule("zero"))
        XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: .max)).origin, .rule("last"))
        XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: 1)).action, .direct)
        XCTAssertEqual(plan.decision(for: IPv4Address(rawValue: .max - 1)).action, .direct)
    }

    func testManagedBackendsShareSemantics() throws {
        let rules = try [rule("corp", "10.42.0.0/16", .vpn)]
        let wg = try compile(rules)
        let ov = try compile(rules, capabilities: .openVPN)
        XCTAssertEqual(wg.routes, ov.routes)
        XCTAssertEqual(wg.effectiveRegions, ov.effectiveRegions)
    }

    func testExternalBypassHasOnlyDirectOverrides() throws {
        let plan = try compile([rule("exception", "198.51.100.7/32", .direct)],
                               defaultAction: .vpn, capabilities: .external)
        XCTAssertEqual(plan.overrides.count, 1)
        XCTAssertEqual(plan.overrides[0].action, .direct)
        XCTAssertEqual(plan.decision(for: try IPv4Address("203.0.113.7")).action, .vpn)
    }

    func testExternalIncludeCannotBeGrantedByCaller() {
        let custom = BackendCapabilities(backendID: "external", kind: .external, supportedModes: [.include, .bypass])
        assertFailure("policy_mode_unavailable") { _ = try compile([], capabilities: custom) }
    }

    func testMissingIPv4AndModeCapabilities() {
        let noIPv4 = BackendCapabilities(backendID: "wireguard", kind: .wireGuard, supportsIPv4: false, supportedModes: [.include])
        assertFailure("ipv4_unavailable") { _ = try compile([], capabilities: noIPv4) }
        let noModes = BackendCapabilities(backendID: "wireguard", kind: .wireGuard, supportedModes: [])
        assertFailure("policy_mode_unavailable") { _ = try compile([], capabilities: noModes) }
    }

    func testEveryUnsupportedActiveMatcherBlocksWholePlan() throws {
        let cases: [(RuleMatch, String)] = [(.domain("secret.example"), "domain_requires_s2"),
            (.domainSuffix("secret.example"), "suffix_requires_s2"), (.ipv6CIDR("::/0"), "ipv6_unavailable"),
            (.unsupported(type: "PROCESS", value: "secret"), "unknown_rule_type")]
        for (match, reason) in cases {
            let rules = try [rule("all", "0.0.0.0/0", .vpn), PolicyRule(id: "unsupported", match: match, action: .direct)]
            assertFailure(reason) { _ = try compile(rules) }
            XCTAssertThrowsError(try IPv4PolicyInterpreter(policy: .init(defaultAction: .direct, rules: rules),
                capabilities: .wireGuard, context: testContext()))
        }
    }

    func testDisabledDraftMatchersAndRejectAreRetainedButIgnored() throws {
        let rule = PolicyRule(id: "draft", match: .domain("not yet normalized"), action: .reject, enabled: false)
        let plan = try compile([rule])
        XCTAssertEqual(plan.ruleEvaluations[0].effect, .disabled)
        XCTAssertTrue(plan.overrides.isEmpty)
    }

    func testRejectRuleAndDefaultCannotBeActivated() throws {
        assertFailure("reject_default_unavailable") { _ = try compile([], defaultAction: .reject) }
        assertFailure("reject_action_unavailable") { _ = try compile([rule("deny", "10.0.0.0/8", .reject)]) }
    }

    func testUnsupportedGuaranteesInStableOrder() throws {
        let policy = IPv4Policy(defaultAction: .direct, rules: [], requiredGuarantees: Set(RequiredGuarantee.allCases))
        do {
            _ = try IPv4PolicyCompiler.compile(policy, capabilities: .wireGuard, context: testContext())
            XCTFail("Expected guarantee rejection")
        } catch let error as PolicyCompilationError {
            XCTAssertEqual(error.diagnostics.map(\.reason), RequiredGuarantee.allCases.map(\.rawValue))
            XCTAssertTrue(error.diagnostics.allSatisfy { $0.code == .guaranteeUnsupported && !$0.retryable })
        }
    }

    func testInvalidAndDuplicateIdentifiers() throws {
        for id in ["", "space id", "secret.example", "id\n", String(repeating: "a", count: 129)] {
            assertFailure("invalid_rule_id") { _ = try compile([rule(id, "10.0.0.0/8", .vpn)]) }
        }
        let disabled = try rule("duplicate", "10.0.0.0/8", .vpn, enabled: false)
        assertFailure("duplicate_rule_id") { _ = try compile([disabled, disabled]) }
    }

    func testDiagnosticsDoNotEchoSelectorOrDisplayName() throws {
        let input = PolicyRule(id: "opaque-id", name: "Sensitive display name",
                               match: .domain("private.secret.example"), action: .vpn)
        do { _ = try compile([input]); XCTFail("Expected rejection") }
        catch let error as PolicyCompilationError {
            let text = String(describing: error)
            XCTAssertFalse(text.contains("private.secret.example"))
            XCTAssertFalse(text.contains("Sensitive display name"))
            XCTAssertEqual(error.diagnostics[0].ruleID, "opaque-id")
        }
    }

    func testContextMustMatchBackendAndHaveIdentifiers() {
        let policy = IPv4Policy(defaultAction: .direct, rules: [])
        assertFailure("backend_context_mismatch") {
            _ = try IPv4PolicyCompiler.compile(policy, capabilities: .wireGuard, context: testContext("other"))
        }
        assertFailure("empty_context_identifier") {
            _ = try IPv4PolicyCompiler.compile(policy, capabilities: .wireGuard, context: testContext(session: ""))
        }
    }

    func testInputLimitIncludesDisabledDrafts() throws {
        let rules = try (0..<1001).map { try rule("r-\($0)", "0.0.0.0/0", .direct, enabled: false) }
        assertFailure("input_rule_limit") { _ = try compile(rules) }
    }

    func testThousandRulesAtDesignCeiling() throws {
        let rules = try (0..<1000).map { try rule("r-\($0)", "0.0.0.0/0", .vpn) }
        let plan = try compile(rules)
        XCTAssertEqual(plan.routes.count, 1)
        XCTAssertEqual(plan.ruleEvaluations.filter { $0.effect == .fullyShadowed }.count, 999)
    }

    func testInvalidLimitSettingsAndUnapprovedIncreases() {
        for limits in [CompilationLimits(maxRules: 0), .init(maxRules: -1), .init(maxRules: 1001),
                       .init(maxRoutes: 0), .init(maxRoutes: -1), .init(maxRoutes: 2049)] {
            assertFailure("invalid_limit_configuration") { _ = try compile([], limits: limits) }
        }
    }

    func testRouteLimitNeverTruncatesPlan() throws {
        let rules = try [rule("host", "198.51.100.7/32", .vpn)]
        let plan = try compile(rules)
        XCTAssertEqual(plan.routes.count, 33)
        XCTAssertEqual(try compile(rules, limits: .init(maxRoutes: 33)).routes, plan.routes)
        assertFailure("compiled_route_limit") { _ = try compile(rules, limits: .init(maxRoutes: 32)) }
    }

    func testMergingHappensBeforeRouteLimit() throws {
        let plan = try compile([rule("left", "0.0.0.0/1", .vpn), rule("right", "128.0.0.0/1", .vpn)],
                               limits: .init(maxRoutes: 1))
        XCTAssertEqual(plan.routes.map(\.cidr.description), ["0.0.0.0/0"])
    }

    func testContextRejectsStaleFutureAndForeignPlans() throws {
        let plan = try compile([])
        XCTAssertEqual(plan.checkContext(against: testContext()), .current)
        XCTAssertEqual(plan.checkContext(against: testContext(session: "another")), .differentSession)
        XCTAssertEqual(plan.checkContext(against: testContext("openvpn")), .differentBackend)
        XCTAssertEqual(plan.checkContext(against: testContext(generation: 6)), .differentGeneration)
        XCTAssertEqual(plan.checkContext(against: testContext(generation: 8)), .differentGeneration)
        XCTAssertEqual(plan.checkContext(against: testContext(epoch: 4)), .differentNetworkEpoch)
    }

    func testContextCountersAtUInt64MaxDoNotWrap() throws {
        let context = testContext(generation: .max, epoch: .max)
        let plan = try IPv4PolicyCompiler.compile(.init(defaultAction: .direct, rules: []), capabilities: .wireGuard, context: context)
        XCTAssertEqual(plan.checkContext(against: context), .current)
        XCTAssertEqual(plan.checkContext(against: testContext(generation: 0, epoch: .max)), .differentGeneration)
    }

    func testWarningsAndDraftMetadataAreExplicit() throws {
        let rule = try PolicyRule(id: "r", name: "Office", match: .ipv4(IPv4CIDR("10.0.0.0/8")), action: .vpn, source: .imported)
        let plan = try compile([rule])
        XCTAssertEqual(rule.name, "Office")
        XCTAssertEqual(rule.source, .imported)
        XCTAssertEqual(plan.limitations, [.planningOnly, .ipv6Unmanaged, .noSystemKillSwitch])
    }

    private func assertFailure(_ reason: String, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () throws -> Void) {
        do { try operation(); XCTFail("Expected rejection: \(reason)", file: file, line: line) }
        catch let error as PolicyCompilationError {
            XCTAssertTrue(error.diagnostics.contains { $0.reason == reason }, "\(error)", file: file, line: line)
        } catch { XCTFail("Wrong error type: \(error)", file: file, line: line) }
    }
}
