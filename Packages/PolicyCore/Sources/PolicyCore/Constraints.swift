// SPDX-License-Identifier: MIT

/// Roles describe address-policy requirements, not a mechanism for configuring NE.
/// DIRECT means that these destinations must not enter this managed VPN; it does
/// not instruct the OS to forward loopback/local traffic onto a physical device.
public enum InfrastructureRole: String, Sendable {
    case vpnEndpoint, vpnDNS, physicalGateway, physicalLAN, localAddress, systemReserved

    public var requiredAction: PolicyAction { self == .vpnDNS ? .vpn : .direct }
}

public struct InfrastructureRequirement: Equatable, Sendable {
    public let id: String
    public let role: InfrastructureRole
    public let cidr: IPv4CIDR

    public init(id: String, role: InfrastructureRole, cidr: IPv4CIDR) {
        self.id = id; self.role = role; self.cidr = cidr
    }
}

/// Opaque peer ID only: never pass public/private keys into the policy layer.
/// These are protocol configuration ranges, not user routes or reachability proof.
public struct WireGuardPeerRange: Equatable, Sendable {
    public let id: String
    public let allowedIPs: [IPv4CIDR]

    public init(id: String, allowedIPs: [IPv4CIDR]) {
        self.id = id; self.allowedIPs = allowedIPs
    }
}

/// The caller must supply the topology for exactly this session/generation/epoch.
/// Nil peer ranges means unknown; [] is an explicitly empty WireGuard peer table.
/// No interface/DNS discovery or verification of input completeness happens here.
public struct IPv4ConstraintInput: Equatable, Sendable {
    public let context: PlanContext
    public let infrastructure: [InfrastructureRequirement]
    public let wireGuardPeers: [WireGuardPeerRange]?

    public init(context: PlanContext, infrastructure: [InfrastructureRequirement],
                wireGuardPeers: [WireGuardPeerRange]? = nil) {
        self.context = context; self.infrastructure = infrastructure
        self.wireGuardPeers = wireGuardPeers
    }
}

/// Separate validation budgets. Lower values are allowed; raising the ceilings
/// requires changing this contract and its tests. These are not performance claims.
public struct ConstraintLimits: Equatable, Sendable {
    public static let requirementCeiling = 256
    public static let peerCeiling = 64
    public static let prefixCeiling = 2_048
    public static let explanationCeiling = 16_384
    public let maxRequirements: Int
    public let maxPeers: Int
    public let maxAllowedPrefixes: Int
    public let maxExplanationRegions: Int

    public init(maxRequirements: Int = requirementCeiling, maxPeers: Int = peerCeiling,
                maxAllowedPrefixes: Int = prefixCeiling,
                maxExplanationRegions: Int = explanationCeiling) {
        self.maxRequirements = maxRequirements; self.maxPeers = maxPeers
        self.maxAllowedPrefixes = maxAllowedPrefixes
        self.maxExplanationRegions = maxExplanationRegions
    }
}

public struct ConstrainedIPv4Decision: Equatable, Sendable {
    public let action: PolicyAction
    public let policyDecision: PolicyDecision
    /// Includes every applicable requirement, sorted by opaque ID.
    public let infrastructureIDs: [String]
    public let wireGuardPeerID: String?

    public var changesDefaultAction: Bool { action != policyDecision.action }
}

public struct ConstrainedIPv4Region: Equatable, Sendable {
    public let cidr: IPv4CIDR
    public let decision: ConstrainedIPv4Decision
}

public struct InfrastructureEvaluation: Equatable, Sendable {
    public let requirement: InfrastructureRequirement
    /// Only areas changed from the default, never from an explicit matched rule.
    public let defaultExceptionCIDRs: [IPv4CIDR]
}

public struct WireGuardPeerAssignment: Equatable, Sendable {
    public let cidr: IPv4CIDR
    public let peerID: String
}

public enum ConstraintLimitation: String, Sendable {
    case suppliedTopologyOnly, underlayMechanismNotValidated, reachabilityNotTested
}

/// A second-stage planning result, NOT an executable NE/route-helper plan.
/// The original intent remains intact, and each default exception is attributable.
public struct ConstrainedIPv4PolicyPlan: Equatable, Sendable {
    public let userIntent: IPv4PolicyPlan
    public let input: IPv4ConstraintInput
    public let routes: [CompiledIPv4Route]
    public let effectiveRegions: [ConstrainedIPv4Region]
    public let infrastructureEvaluations: [InfrastructureEvaluation]
    public let peerAssignments: [WireGuardPeerAssignment]
    public let limitations: [ConstraintLimitation]

    public var context: PlanContext { userIntent.context }
    public var overrides: [CompiledIPv4Route] { routes.filter { $0.action != userIntent.defaultAction } }

    public func decision(for address: IPv4Address) -> ConstrainedIPv4Decision {
        var lower = 0
        var upper = effectiveRegions.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if effectiveRegions[middle].cidr.networkAddress <= address { lower = middle + 1 }
            else { upper = middle }
        }
        return effectiveRegions[lower - 1].decision
    }

    public func checkContext(against current: PlanContext) -> ContextCheck {
        context.check(against: current)
    }
}

/// Half-open 64-bit ranges; even /0 is checked without enumerating its addresses.
private struct ConstraintSpan {
    var lower: UInt64
    var upper: UInt64

    init(_ cidr: IPv4CIDR) {
        lower = UInt64(cidr.networkAddress.rawValue); upper = lower + cidr.addressCount
    }
    init(_ lower: UInt64, _ upper: UInt64) { self.lower = lower; self.upper = upper }
    func cidrs() -> [IPv4CIDR] {
        var result: [IPv4CIDR] = []
        var cursor = lower
        while cursor < upper {
            let bits = min(min(32, cursor.trailingZeroBitCount), 63 - (upper - cursor).leadingZeroBitCount)
            result.append(IPv4CIDR(validatedAddress: UInt32(cursor), prefixLength: 32 - bits))
            cursor += UInt64(1) << bits
        }
        return result
    }
}

private struct ConstraintRun {
    var span: ConstraintSpan
    let decision: ConstrainedIPv4Decision
}
private struct PeerPrefix {
    let cidr: IPv4CIDR
    let peerID: String
}

public enum IPv4ConstrainedPolicyCompiler {
    public static func compile(_ policy: IPv4Policy, capabilities: BackendCapabilities,
                               context: PlanContext, constraints: IPv4ConstraintInput,
                               limits: CompilationLimits = .init(),
                               constraintLimits: ConstraintLimits = .init()) throws -> ConstrainedIPv4PolicyPlan {
        let prefixes = try validate(constraints, capabilities: capabilities, context: context, limits: constraintLimits)
        let intent = try IPv4PolicyCompiler.compile(policy, capabilities: capabilities, context: context, limits: limits)
        let requirements = constraints.infrastructure.sorted { $0.id < $1.id }
        var boundaries: Set<UInt64> = [0, UInt64(1) << 32]
        let ranges = intent.effectiveRegions.map(\.cidr) + requirements.map(\.cidr) + prefixes.map(\.cidr)
        for cidr in ranges {
            let span = ConstraintSpan(cidr)
            boundaries.insert(span.lower); boundaries.insert(span.upper)
        }
        let points = boundaries.sorted()
        var runs: [ConstraintRun] = []
        for index in 0..<(points.count - 1) {
            let span = ConstraintSpan(points[index], points[index + 1])
            let address = IPv4Address(rawValue: UInt32(span.lower))
            let original = intent.decision(for: address)
            // Membership and longest-prefix selection are constant within this span.
            let applicable = requirements.filter { $0.cidr.contains(address) }
            if let first = applicable.first,
               let contrary = applicable.first(where: { $0.role.requiredAction != first.role.requiredAction }) {
                throw PolicyCompilationError([
                    .init(.infrastructureConflict, "contradictory_infrastructure", requirementID: first.id),
                    .init(.infrastructureConflict, "contradictory_infrastructure", requirementID: contrary.id)
                ])
            }
            let action = applicable.first?.role.requiredAction ?? original.action
            if action != original.action, case .rule(let ruleID) = original.origin {
                throw PolicyCompilationError([.init(.infrastructureConflict, "explicit_rule_conflicts_with_infrastructure",
                    ruleID: ruleID, requirementID: applicable.first?.id,
                    suggestion: "Resolve the explicit rule and infrastructure requirement; neither is silently overridden.")])
            }
            // External owns only DIRECT exceptions. It must not synthesize new VPN routes.
            if capabilities.kind == .external, action != original.action, action == .vpn {
                throw PolicyCompilationError([.init(.capabilityUnsupported, "external_vpn_override_unavailable")])
            }
            var peerID: String?
            if action == .vpn, capabilities.kind == .wireGuard {
                peerID = prefixes.first(where: { $0.cidr.contains(address) })?.peerID
                guard peerID != nil else {
                    let ruleID: String? = if case .rule(let id) = original.origin { id } else { nil }
                    throw PolicyCompilationError([.init(.peerUnreachableRange, "vpn_region_outside_allowed_ips",
                        ruleID: ruleID, requirementID: applicable.first?.id,
                        suggestion: "Narrow the VPN policy or use a separately authorized peer configuration; AllowedIPs are never expanded.")])
                }
            }
            let decision = ConstrainedIPv4Decision(action: action, policyDecision: original,
                infrastructureIDs: applicable.map(\.id), wireGuardPeerID: peerID)
            if let last = runs.last, last.span.upper == span.lower, last.decision == decision {
                runs[runs.count - 1].span.upper = span.upper
            } else { runs.append(.init(span: span, decision: decision)) }
        }
        // Aggregate only after validation. There is no partial plan on any failure.
        let routes = try makeRoutes(runs, maxRoutes: limits.maxRoutes)
        var regions: [ConstrainedIPv4Region] = []
        for run in runs {
            for cidr in run.span.cidrs() {
                guard regions.count < constraintLimits.maxExplanationRegions else {
                    throw PolicyCompilationError([.init(.limitExceeded, "constraint_explanation_limit")])
                }
                regions.append(.init(cidr: cidr, decision: run.decision))
            }
        }
        var evaluations: [InfrastructureEvaluation] = []
        for requirement in requirements {
            let spans = runs.filter {
                $0.decision.changesDefaultAction && $0.decision.infrastructureIDs.contains(requirement.id)
            }.map(\.span)
            evaluations.append(.init(requirement: requirement, defaultExceptionCIDRs: merge(spans).flatMap { $0.cidrs() }))
        }
        var assignments: [WireGuardPeerAssignment] = []
        // Merge adjacent ranges per peer independently of rule/requirement attribution.
        var peerRuns: [(span: ConstraintSpan, peerID: String)] = []
        for run in runs {
            guard let peerID = run.decision.wireGuardPeerID else { continue }
            if let last = peerRuns.last, last.peerID == peerID, last.span.upper == run.span.lower {
                peerRuns[peerRuns.count - 1].span.upper = run.span.upper
            } else { peerRuns.append((run.span, peerID)) }
        }
        for run in peerRuns {
            for cidr in run.span.cidrs() {
                guard assignments.count < limits.maxRoutes else {
                    throw PolicyCompilationError([.init(.limitExceeded, "peer_assignment_limit")])
                }
                assignments.append(.init(cidr: cidr, peerID: run.peerID))
            }
        }
        return .init(userIntent: intent, input: constraints, routes: routes, effectiveRegions: regions,
            infrastructureEvaluations: evaluations, peerAssignments: assignments,
            limitations: [.suppliedTopologyOnly, .underlayMechanismNotValidated, .reachabilityNotTested])
    }

    private static func validate(_ input: IPv4ConstraintInput, capabilities: BackendCapabilities,
                                 context: PlanContext, limits: ConstraintLimits) throws -> [PeerPrefix] {
        guard (1...ConstraintLimits.requirementCeiling).contains(limits.maxRequirements),
              (1...ConstraintLimits.peerCeiling).contains(limits.maxPeers),
              (1...ConstraintLimits.prefixCeiling).contains(limits.maxAllowedPrefixes),
              (1...ConstraintLimits.explanationCeiling).contains(limits.maxExplanationRegions) else {
            throw PolicyCompilationError([.init(.limitExceeded, "invalid_constraint_limits")])
        }
        let check = input.context.check(against: context)
        guard check == .current else {
            throw PolicyCompilationError([.init(check == .differentNetworkEpoch ? .networkEpochChanged : .ruleUnrepresentable,
                "constraint_context_mismatch")])
        }
        guard input.infrastructure.count <= limits.maxRequirements else {
            throw PolicyCompilationError([.init(.limitExceeded, "infrastructure_count_limit")])
        }
        var requirementIDs = Set<String>()
        for item in input.infrastructure {
            guard validID(item.id) else {
                throw PolicyCompilationError([.init(.ruleUnrepresentable, "invalid_requirement_id")])
            }
            guard requirementIDs.insert(item.id).inserted else {
                throw PolicyCompilationError([.init(.ruleUnrepresentable, "duplicate_requirement_id", requirementID: item.id)])
            }
            // Endpoint, resolver and interface/gateway addresses must be exact hosts.
            switch item.role {
            case .vpnEndpoint, .vpnDNS, .physicalGateway, .localAddress:
                guard item.cidr.prefixLength == 32 else {
                    throw PolicyCompilationError([.init(.ruleUnrepresentable, "infrastructure_host_required", requirementID: item.id)])
                }
            case .physicalLAN, .systemReserved: break
            }
        }
        if capabilities.kind != .wireGuard {
            guard input.wireGuardPeers == nil else {
                throw PolicyCompilationError([.init(.capabilityUnsupported, "peer_ranges_for_non_wireguard")])
            }
            return []
        }
        guard let peers = input.wireGuardPeers else {
            throw PolicyCompilationError([.init(.capabilityUnsupported, "wireguard_peer_ranges_required")])
        }
        guard peers.count <= limits.maxPeers else {
            throw PolicyCompilationError([.init(.limitExceeded, "peer_count_limit")])
        }
        var peerIDs = Set<String>()
        var owners: [IPv4CIDR: String] = [:]
        var prefixCount = 0
        for peer in peers {
            guard validID(peer.id) else {
                throw PolicyCompilationError([.init(.ruleUnrepresentable, "invalid_peer_id")])
            }
            guard peerIDs.insert(peer.id).inserted else {
                throw PolicyCompilationError([.init(.ruleUnrepresentable, "duplicate_peer_id", peerID: peer.id)])
            }
            guard peer.allowedIPs.count <= limits.maxAllowedPrefixes - prefixCount else {
                throw PolicyCompilationError([.init(.limitExceeded, "allowed_prefix_count_limit")])
            }
            prefixCount += peer.allowedIPs.count
            for prefix in peer.allowedIPs {
                if let prior = owners[prefix], prior != peer.id {
                    throw PolicyCompilationError([.init(.ruleUnrepresentable, "ambiguous_peer_prefix", peerID: peer.id,
                        suggestion: "Resolve equal-prefix ownership across peers; configuration order is not used as a tie-breaker.")])
                }
                owners[prefix] = peer.id
            }
        }
        return owners.map { PeerPrefix(cidr: $0.key, peerID: $0.value) }.sorted {
            if $0.cidr.prefixLength != $1.cidr.prefixLength { return $0.cidr.prefixLength > $1.cidr.prefixLength }
            if $0.cidr != $1.cidr { return $0.cidr < $1.cidr }
            return $0.peerID < $1.peerID
        }
    }

    private static func validID(_ id: String) -> Bool {
        let bytes = id.utf8
        return (1...128).contains(bytes.count) && bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func merge(_ spans: [ConstraintSpan]) -> [ConstraintSpan] {
        var result: [ConstraintSpan] = []
        for span in spans {
            if let last = result.last, last.upper == span.lower { result[result.count - 1].upper = span.upper }
            else { result.append(span) }
        }
        return result
    }

    private static func makeRoutes(_ runs: [ConstraintRun], maxRoutes: Int) throws -> [CompiledIPv4Route] {
        var merged: [ConstraintRun] = []
        for run in runs {
            if let last = merged.last, last.span.upper == run.span.lower, last.decision.action == run.decision.action {
                merged[merged.count - 1].span.upper = run.span.upper
            } else { merged.append(run) }
        }
        var result: [CompiledIPv4Route] = []
        for run in merged {
            for cidr in run.span.cidrs() {
                guard result.count < maxRoutes else {
                    throw PolicyCompilationError([.init(.limitExceeded, "constrained_route_limit")])
                }
                result.append(.init(cidr: cidr, action: run.decision.action))
            }
        }
        return result
    }
}
