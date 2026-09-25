// SPDX-License-Identifier: MIT
import XCTest
@testable import PolicyCore

private struct Generator {
    var state: UInt64
    mutating func next() -> UInt32 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt32(truncatingIfNeeded: state >> 32)
    }
}

final class CompilerPropertyTests: XCTestCase {
    func testSeededPoliciesAgainstIndependentInterpreterAndRouteLookup() throws {
        var compared = 0
        for seed in UInt64(1)...64 {
            var generator = Generator(state: seed)
            var rules: [PolicyRule] = []
            for index in 0..<40 {
                let raw = generator.next()
                let clustered = index % 2 == 0
                let address = IPv4Address(rawValue: clustered ? 0x0A000000 | (raw & 0xFFFFFF) : raw)
                let length = clustered ? 8 + Int(generator.next() % 25) : Int(generator.next() % 33)
                let cidr = try IPv4CIDR(address: address, prefixLength: length)
                rules.append(PolicyRule(id: "r-\(index)", match: .ipv4(cidr),
                    action: generator.next() % 2 == 0 ? .direct : .vpn, enabled: generator.next() % 5 != 0))
            }
            let policy = IPv4Policy(defaultAction: seed % 2 == 0 ? .direct : .vpn, rules: rules)
            let plan = try IPv4PolicyCompiler.compile(policy, capabilities: .wireGuard, context: testContext())
            let oracle = try IPv4PolicyInterpreter(policy: policy, capabilities: .wireGuard, context: testContext())
            assertPartition(plan.routes.map(\.cidr), label: "routes seed \(seed)")
            assertPartition(plan.effectiveRegions.map(\.cidr), label: "sources seed \(seed)")

            // Both algorithms are constant between their combined prefix boundaries.
            // Check every such interval, its endpoints, and independent random addresses.
            var boundaries: Set<UInt64> = [0, UInt64(1) << 32]
            let inputCIDRs = rules.compactMap { rule -> IPv4CIDR? in
                if case .ipv4(let cidr) = rule.match { return cidr }; return nil
            }
            for cidr in inputCIDRs + plan.routes.map(\.cidr) + plan.effectiveRegions.map(\.cidr) {
                let start = UInt64(cidr.networkAddress.rawValue)
                boundaries.insert(start); boundaries.insert(start + cidr.addressCount)
            }
            let sorted = boundaries.sorted()
            var samples = Set<UInt32>()
            for index in 0..<(sorted.count - 1) {
                samples.insert(UInt32(sorted[index]))
                samples.insert(UInt32(sorted[index + 1] - 1))
            }
            for _ in 0..<128 { samples.insert(generator.next()) }
            for value in samples.sorted() {
                let address = IPv4Address(rawValue: value)
                let expected = oracle.evaluate(address)
                XCTAssertEqual(plan.decision(for: address), expected, "seed=\(seed), address=\(address)")
                let matches = plan.routes.filter { $0.cidr.contains(address) }
                XCTAssertEqual(matches.count, 1, "seed=\(seed), address=\(address)")
                XCTAssertEqual(matches.first?.action, expected.action, "seed=\(seed), address=\(address)")
                compared += 1
            }
            for (index, evaluation) in plan.ruleEvaluations.enumerated() {
                XCTAssertEqual(evaluation.ruleID, rules[index].id)
                XCTAssertEqual(evaluation.effectiveAddressCount, evaluation.effectiveCIDRs.reduce(0) { $0 + $1.addressCount })
            }
        }
        XCTAssertGreaterThan(compared, 10_000)
        print("PROPERTY_CHECK policies=64 address_comparisons=\(compared) seed_range=1...64")
    }

    func testEveryPrefixWithAnEarlierHostException() throws {
        for prefix in 0...32 {
            let broad = try IPv4CIDR(address: IPv4Address(rawValue: 0xA1234567), prefixLength: prefix)
            let first = broad.networkAddress
            let last = IPv4Address(rawValue: UInt32(UInt64(first.rawValue) + broad.addressCount - 1))
            let rules = try [rule("hole", "\(first)/32", .direct),
                             PolicyRule(id: "wide", match: .ipv4(broad), action: .vpn)]
            let plan = try compile(rules)
            XCTAssertEqual(plan.decision(for: first).action, .direct)
            XCTAssertEqual(plan.decision(for: last).action, prefix == 32 ? .direct : .vpn)
            XCTAssertEqual(plan.ruleEvaluations[1].effectiveAddressCount, broad.addressCount - 1)
            assertPartition(plan.routes.map(\.cidr), label: "prefix \(prefix)")
        }
    }

    func testCompilationIsDeterministicIncludingExplanations() throws {
        let rules = try [rule("hole", "10.42.0.0/16", .direct), rule("broad", "10.0.0.0/8", .vpn),
                         rule("tail", "255.255.255.255/32", .vpn), rule("shadow", "10.42.7.0/24", .vpn)]
        let first = try compile(rules)
        for _ in 0..<10 { XCTAssertEqual(try compile(rules), first) }
    }

    func testSparseInputAtRuleCeilingHitsHardRouteCeiling() throws {
        let rules = try (0..<1000).map { index -> PolicyRule in
            let ip = IPv4Address(rawValue: UInt32(index) &* 4_294_967)
            return try rule("sparse-\(index)", "\(ip)/32", .vpn)
        }
        do { _ = try compile(rules); XCTFail("Must not truncate a fragmented plan") }
        catch let error as PolicyCompilationError {
            XCTAssertEqual(error.diagnostics.map(\.reason), ["compiled_route_limit"])
        }
    }

    private func assertPartition(_ cidrs: [IPv4CIDR], label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        var next: UInt64 = 0
        for cidr in cidrs {
            XCTAssertEqual(UInt64(cidr.networkAddress.rawValue), next, label, file: file, line: line)
            next += cidr.addressCount
        }
        XCTAssertEqual(next, UInt64(1) << 32, label, file: file, line: line)
    }
}
