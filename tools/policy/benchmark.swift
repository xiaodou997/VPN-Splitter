// SPDX-License-Identifier: MIT
// Compile together with PolicyCore sources using -O. No network or credentials.
import Foundation

@main struct PolicyBenchmark {
    static func main() throws {
        var seed: UInt64 = 20260930
        var rules: [PolicyRule] = []
        for i in 0..<1000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let offset = (i * 397) % 1000
            let cidr = try IPv4CIDR(address: IPv4Address(rawValue: 0x0A000000 + UInt32(offset * 256)), prefixLength: 24)
            rules.append(.init(id: "synthetic-\(i)", match: .ipv4(cidr), action: seed >> 32 & 1 == 0 ? .direct : .vpn))
        }
        let policy = IPv4Policy(defaultAction: .vpn, rules: rules)
        let context = PlanContext(sessionID: "benchmark", backendID: "external", generation: 1, networkEpoch: 1)
        func compile() throws -> IPv4PolicyPlan {
            try IPv4PolicyCompiler.compile(policy, capabilities: .external, context: context)
        }
        let expected = try compile()
        let oracle = try IPv4PolicyInterpreter(policy: policy, capabilities: .external, context: context)
        for rule in rules {
            if case .ipv4(let cidr) = rule.match {
                precondition(expected.decision(for: cidr.networkAddress) == oracle.evaluate(cidr.networkAddress))
            }
        }
        for _ in 0..<10 { let plan = try compile(); precondition(plan == expected) }
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            let plan = try compile()
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            precondition(plan == expected) // Outside measured interval, consumes output.
            samples.append(Double(elapsed) / 1_000_000)
        }
        samples.sort()
        print("fixture=seed20260930_clustered_permuted_1000_ipv4_24 rules=1000 warmup=10 samples=100")
        print("routes=\(expected.routes.count) regions=\(expected.effectiveRegions.count) correctness=PASS")
        print(String(format: "median_ms=%.3f p95_ms=%.3f max_ms=%.3f", samples[49], samples[94], samples[99]))
        print("p95_target_100ms=\(samples[94] <= 100 ? "PASS" : "FAIL") network=NOT_READ_OR_MODIFIED")
    }
}
