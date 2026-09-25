// SPDX-License-Identifier: MIT

public enum PolicyAction: String, Sendable, CaseIterable {
    case direct = "DIRECT", vpn = "VPN", reject = "REJECT"
}

public enum PolicyMode: String, Sendable, Hashable { case include, bypass }
public enum BackendKind: String, Sendable { case wireGuard, openVPN, external }
public enum RuleSource: String, Sendable { case user, imported }

/// Non-IPv4 cases preserve drafts only. No hostname or IPv6 parser is claimed yet.
public enum RuleMatch: Equatable, Sendable {
    case ipv4(IPv4CIDR)
    case domain(String)
    case domainSuffix(String)
    case ipv6CIDR(String)
    case unsupported(type: String, value: String)
}

public struct PolicyRule: Equatable, Sendable {
    public let id: String
    public let name: String
    public let match: RuleMatch
    public let action: PolicyAction
    public let enabled: Bool
    public let source: RuleSource

    public init(id: String, name: String = "", match: RuleMatch, action: PolicyAction,
                enabled: Bool = true, source: RuleSource = .user) {
        self.id = id; self.name = name; self.match = match
        self.action = action; self.enabled = enabled; self.source = source
    }
}

public enum RequiredGuarantee: String, CaseIterable, Hashable, Sendable {
    case failClosed, allAddressFamilies, strictDomainIsolation
}

/// Array order is rule order. MATCH is represented only by defaultAction.
public struct IPv4Policy: Equatable, Sendable {
    public let defaultAction: PolicyAction
    public let rules: [PolicyRule]
    public let requiredGuarantees: Set<RequiredGuarantee>

    public init(defaultAction: PolicyAction, rules: [PolicyRule],
                requiredGuarantees: Set<RequiredGuarantee> = []) {
        self.defaultAction = defaultAction; self.rules = rules
        self.requiredGuarantees = requiredGuarantees
    }
}

/// A caller-supplied planning contract, NOT a runtime compatibility observation.
public struct BackendCapabilities: Equatable, Sendable {
    public let backendID: String
    public let kind: BackendKind
    public let supportsIPv4: Bool
    public let supportedModes: Set<PolicyMode>

    public init(backendID: String, kind: BackendKind, supportsIPv4: Bool = true,
                supportedModes: Set<PolicyMode>) {
        self.backendID = backendID; self.kind = kind
        self.supportsIPv4 = supportsIPv4; self.supportedModes = supportedModes
    }

    public static let wireGuard = Self(backendID: "wireguard", kind: .wireGuard, supportedModes: [.include, .bypass])
    public static let openVPN = Self(backendID: "openvpn", kind: .openVPN, supportedModes: [.include, .bypass])
    public static let external = Self(backendID: "external", kind: .external, supportedModes: [.bypass])
}

public enum ContextCheck: Equatable, Sendable {
    case current, differentSession, differentBackend, differentGeneration, differentNetworkEpoch
}

/// Compare exactly, including future as well as old generations. No global state.
public struct PlanContext: Equatable, Sendable {
    public let sessionID: String
    public let backendID: String
    public let generation: UInt64
    public let networkEpoch: UInt64

    public init(sessionID: String, backendID: String, generation: UInt64, networkEpoch: UInt64) {
        self.sessionID = sessionID; self.backendID = backendID
        self.generation = generation; self.networkEpoch = networkEpoch
    }

    public func check(against current: Self) -> ContextCheck {
        if sessionID != current.sessionID { return .differentSession }
        if backendID != current.backendID { return .differentBackend }
        if generation != current.generation { return .differentGeneration }
        if networkEpoch != current.networkEpoch { return .differentNetworkEpoch }
        return .current
    }
}

public struct CompilationLimits: Equatable, Sendable {
    public static let ruleCeiling = 1_000
    public static let routeCeiling = 2_048
    public let maxRules: Int
    public let maxRoutes: Int

    /// Callers may lower but cannot silently raise the documented design ceilings.
    public init(maxRules: Int = ruleCeiling, maxRoutes: Int = routeCeiling) {
        self.maxRules = maxRules; self.maxRoutes = maxRoutes
    }
}

public enum DiagnosticCode: String, Sendable {
    case capabilityUnsupported = "E_CAPABILITY_UNSUPPORTED"
    case guaranteeUnsupported = "E_GUARANTEE_UNSUPPORTED"
    case ruleUnrepresentable = "E_RULE_UNREPRESENTABLE"
    case limitExceeded = "E_LIMIT_EXCEEDED"
    case infrastructureConflict = "E_INFRASTRUCTURE_CONFLICT"
    case peerUnreachableRange = "E_PEER_UNREACHABLE_RANGE"
    case networkEpochChanged = "E_NETWORK_EPOCH_CHANGED"
}

/// Static reason codes plus opaque rule IDs; never echoes selector contents.
public struct BlockingDiagnostic: Equatable, Sendable {
    public let code: DiagnosticCode
    public let ruleID: String?
    public let requirementID: String?
    public let peerID: String?
    public let reason: String
    public let suggestion: String
    public let retryable: Bool

    internal init(_ code: DiagnosticCode, _ reason: String, ruleID: String? = nil,
                  requirementID: String? = nil, peerID: String? = nil,
                  suggestion: String = "Edit the policy or use a supported backend.") {
        self.code = code; self.ruleID = ruleID; self.reason = reason
        self.requirementID = requirementID; self.peerID = peerID
        self.suggestion = suggestion; self.retryable = false
    }
}

public struct PolicyCompilationError: Error, Equatable, Sendable {
    public let diagnostics: [BlockingDiagnostic]
    internal init(_ diagnostics: [BlockingDiagnostic]) { self.diagnostics = diagnostics }
}

internal enum PolicyValidator {
    static func validate(_ policy: IPv4Policy, capabilities: BackendCapabilities,
                         context: PlanContext, limits: CompilationLimits) throws {
        guard (1...CompilationLimits.ruleCeiling).contains(limits.maxRules),
              (1...CompilationLimits.routeCeiling).contains(limits.maxRoutes) else {
            throw PolicyCompilationError([.init(.limitExceeded, "invalid_limit_configuration")])
        }
        guard policy.rules.count <= limits.maxRules else {
            throw PolicyCompilationError([.init(.limitExceeded, "input_rule_limit")])
        }
        var errors: [BlockingDiagnostic] = []
        if context.sessionID.isEmpty || context.backendID.isEmpty || capabilities.backendID.isEmpty {
            errors.append(.init(.ruleUnrepresentable, "empty_context_identifier"))
        }
        if context.backendID != capabilities.backendID {
            errors.append(.init(.capabilityUnsupported, "backend_context_mismatch"))
        }
        if !capabilities.supportsIPv4 {
            errors.append(.init(.capabilityUnsupported, "ipv4_unavailable"))
        }
        if policy.defaultAction == .reject {
            errors.append(.init(.capabilityUnsupported, "reject_default_unavailable"))
        } else {
            let mode: PolicyMode = policy.defaultAction == .direct ? .include : .bypass
            // A permissive caller cannot accidentally enable External Include.
            if !capabilities.supportedModes.contains(mode) || (capabilities.kind == .external && mode == .include) {
                errors.append(.init(.capabilityUnsupported, "policy_mode_unavailable"))
            }
        }
        for guarantee in RequiredGuarantee.allCases where policy.requiredGuarantees.contains(guarantee) {
            errors.append(.init(.guaranteeUnsupported, guarantee.rawValue))
        }
        var identifiers = Set<String>()
        for rule in policy.rules {
            // Opaque ASCII identifiers keep diagnostics bounded; names are separate.
            let bytes = rule.id.utf8
            let idValid = (1...128).contains(bytes.count) && bytes.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            }
            if !idValid { errors.append(.init(.ruleUnrepresentable, "invalid_rule_id")) }
            if !identifiers.insert(rule.id).inserted {
                errors.append(.init(.ruleUnrepresentable, "duplicate_rule_id", ruleID: idValid ? rule.id : nil))
            }
            guard rule.enabled else { continue }
            if rule.action == .reject {
                errors.append(.init(.capabilityUnsupported, "reject_action_unavailable", ruleID: idValid ? rule.id : nil))
            }
            switch rule.match {
            case .ipv4: break
            case .domain: errors.append(.init(.capabilityUnsupported, "domain_requires_s2", ruleID: idValid ? rule.id : nil))
            case .domainSuffix: errors.append(.init(.capabilityUnsupported, "suffix_requires_s2", ruleID: idValid ? rule.id : nil))
            case .ipv6CIDR: errors.append(.init(.capabilityUnsupported, "ipv6_unavailable", ruleID: idValid ? rule.id : nil))
            case .unsupported: errors.append(.init(.capabilityUnsupported, "unknown_rule_type", ruleID: idValid ? rule.id : nil))
            }
        }
        if !errors.isEmpty { throw PolicyCompilationError(errors) }
    }
}
