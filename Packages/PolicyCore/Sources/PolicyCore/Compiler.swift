// SPDX-License-Identifier: MIT

public enum RuleOrigin: Equatable, Sendable { case rule(String), defaultPolicy }
public struct PolicyDecision: Equatable, Sendable {
    public let action: PolicyAction
    public let origin: RuleOrigin
    internal init(_ action: PolicyAction, _ origin: RuleOrigin) {
        self.action = action; self.origin = origin
    }
}

public enum RuleEffect: String, Sendable { case disabled, fullyShadowed, partiallyShadowed, effective }
public struct RuleEvaluation: Equatable, Sendable {
    public let ruleID: String
    public let effect: RuleEffect
    public let effectiveAddressCount: UInt64
    public let effectiveCIDRs: [IPv4CIDR]
}

public struct CompiledIPv4Route: Equatable, Sendable {
    public let cidr: IPv4CIDR
    public let action: PolicyAction
}

/// Attribution remains separate when equivalent routes from different rules merge.
public struct EffectiveIPv4Region: Equatable, Sendable {
    public let cidr: IPv4CIDR
    public let decision: PolicyDecision
}

public enum PlanLimitation: String, Sendable {
    case planningOnly, ipv6Unmanaged, noSystemKillSwitch
}

/// Pure IPv4 address plan, NOT the full executable PolicyPlan from the design.
/// Routes partition the entire IPv4 space without overlap. No system writes occur.
public struct IPv4PolicyPlan: Equatable, Sendable {
    public let context: PlanContext
    public let defaultAction: PolicyAction
    public let routes: [CompiledIPv4Route]
    public let effectiveRegions: [EffectiveIPv4Region]
    public let ruleEvaluations: [RuleEvaluation]
    public let limitations: [PlanLimitation]

    public var overrides: [CompiledIPv4Route] { routes.filter { $0.action != defaultAction } }

    /// This is a compiled intention, not an observed egress or permission to apply.
    public func decision(for address: IPv4Address) -> PolicyDecision {
        // Effective regions are a nonempty, sorted, complete partition by construction.
        var lower = 0
        var upper = effectiveRegions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if effectiveRegions[middle].cidr.networkAddress <= address { lower = middle + 1 }
            else { upper = middle }
        }
        return effectiveRegions[lower - 1].decision
    }

    public func checkContext(against current: PlanContext) -> ContextCheck { context.check(against: current) }
}

/// Reference interpreter: scans the original list using masks, not interval subtraction.
/// Shared validation prevents unsupported rules from being silently short-circuited.
public struct IPv4PolicyInterpreter: Sendable {
    private let policy: IPv4Policy

    public init(policy: IPv4Policy, capabilities: BackendCapabilities, context: PlanContext,
                limits: CompilationLimits = .init()) throws {
        try PolicyValidator.validate(policy, capabilities: capabilities, context: context, limits: limits)
        self.policy = policy
    }

    public func evaluate(_ address: IPv4Address) -> PolicyDecision {
        for rule in policy.rules where rule.enabled {
            if case .ipv4(let cidr) = rule.match, cidr.contains(address) {
                return PolicyDecision(rule.action, .rule(rule.id))
            }
        }
        return PolicyDecision(policy.defaultAction, .defaultPolicy)
    }
}

// Half-open UInt64 intervals represent 2^32 without overflow. Never enumerate IPs.
private struct Interval {
    let lower: UInt64
    let upper: UInt64
    var count: UInt64 { upper - lower }

    init(_ lower: UInt64, _ upper: UInt64) { self.lower = lower; self.upper = upper }
    init(_ cidr: IPv4CIDR) {
        self.lower = UInt64(cidr.networkAddress.rawValue)
        self.upper = lower + cidr.addressCount
    }

    func cidrs() -> [IPv4CIDR] {
        var result: [IPv4CIDR] = []
        var cursor = lower
        while cursor < upper {
            let alignment = min(32, cursor.trailingZeroBitCount)
            let fit = 63 - (upper - cursor).leadingZeroBitCount
            let bits = min(alignment, fit)
            result.append(IPv4CIDR(validatedAddress: UInt32(cursor), prefixLength: 32 - bits))
            cursor += UInt64(1) << bits
        }
        return result
    }
}

private struct AssignedInterval {
    let interval: Interval
    let decision: PolicyDecision
}

public enum IPv4PolicyCompiler {
    public static func compile(_ policy: IPv4Policy, capabilities: BackendCapabilities,
                               context: PlanContext, limits: CompilationLimits = .init()) throws -> IPv4PolicyPlan {
        try PolicyValidator.validate(policy, capabilities: capabilities, context: context, limits: limits)
        var covered: [Interval] = []
        var assigned: [AssignedInterval] = []
        var evaluations: [RuleEvaluation] = []
        for rule in policy.rules {
            guard rule.enabled else {
                evaluations.append(.init(ruleID: rule.id, effect: .disabled, effectiveAddressCount: 0, effectiveCIDRs: []))
                continue
            }
            guard case .ipv4(let cidr) = rule.match else {
                // Defensive invariant: no future matcher may silently disappear here.
                throw PolicyCompilationError([.init(.capabilityUnsupported, "unhandled_matcher", ruleID: rule.id)])
            }
            let interval = Interval(cidr)
            let remaining = subtract(interval, covered: covered)
            let count = remaining.reduce(UInt64(0)) { $0 + $1.count }
            let effect: RuleEffect = count == 0 ? .fullyShadowed : (count == interval.count ? .effective : .partiallyShadowed)
            let decision = PolicyDecision(rule.action, .rule(rule.id))
            assigned.append(contentsOf: remaining.map { AssignedInterval(interval: $0, decision: decision) })
            evaluations.append(.init(ruleID: rule.id, effect: effect, effectiveAddressCount: count,
                                     effectiveCIDRs: remaining.flatMap { $0.cidrs() }))
            covered = union(covered + [interval])
        }
        let fallback = PolicyDecision(policy.defaultAction, .defaultPolicy)
        assigned.append(contentsOf: subtract(Interval(0, UInt64(1) << 32), covered: covered)
            .map { AssignedInterval(interval: $0, decision: fallback) })
        assigned.sort { $0.interval.lower < $1.interval.lower }

        // Merge by action for compact routes, retaining distinct rule provenance below.
        var runs: [AssignedInterval] = []
        for item in assigned {
            if let last = runs.last, last.interval.upper == item.interval.lower,
               last.decision.action == item.decision.action {
                runs[runs.count - 1] = AssignedInterval(
                    interval: Interval(last.interval.lower, item.interval.upper), decision: last.decision)
            } else { runs.append(item) }
        }
        var routes: [CompiledIPv4Route] = []
        for run in runs {
            for cidr in run.interval.cidrs() {
                guard routes.count < limits.maxRoutes else {
                    throw PolicyCompilationError([.init(.limitExceeded, "compiled_route_limit",
                        suggestion: "Reduce route fragmentation or simplify the policy.")])
                }
                routes.append(.init(cidr: cidr, action: run.decision.action))
            }
        }
        let regions = assigned.flatMap { item in
            item.interval.cidrs().map { EffectiveIPv4Region(cidr: $0, decision: item.decision) }
        }
        return IPv4PolicyPlan(context: context, defaultAction: policy.defaultAction, routes: routes,
            effectiveRegions: regions, ruleEvaluations: evaluations,
            limitations: [.planningOnly, .ipv6Unmanaged, .noSystemKillSwitch])
    }

    /// Remove the already assigned union; later specificity never overrides earlier rules.
    private static func subtract(_ input: Interval, covered: [Interval]) -> [Interval] {
        var result: [Interval] = []
        var cursor = input.lower
        for prior in covered {
            if prior.upper <= cursor { continue }
            if prior.lower >= input.upper { break }
            if prior.lower > cursor { result.append(Interval(cursor, min(prior.lower, input.upper))) }
            cursor = max(cursor, prior.upper)
            if cursor >= input.upper { break }
        }
        if cursor < input.upper { result.append(Interval(cursor, input.upper)) }
        return result
    }

    private static func union(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted {
            $0.lower == $1.lower ? $0.upper < $1.upper : $0.lower < $1.lower
        }
        var result: [Interval] = []
        for next in sorted {
            if let last = result.last, next.lower <= last.upper {
                result[result.count - 1] = Interval(last.lower, max(last.upper, next.upper))
            } else { result.append(next) }
        }
        return result
    }
}
