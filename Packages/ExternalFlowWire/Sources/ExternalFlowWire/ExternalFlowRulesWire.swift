// SPDX-License-Identifier: MIT
import Foundation

public enum ExternalFlowRuleWireKind: String, Codable, Sendable {
    case ipCIDR, domain, domainSuffix, domainKeyword, application
}

/// Bounded structured rules export carried over the user-local Flow bridge and
/// the providerConfiguration plist. Content is rule definitions only — never
/// credentials, live hostnames, or traffic metadata.
public struct ExternalFlowRuleWire: Codable, Equatable, Sendable {
    public let kind: ExternalFlowRuleWireKind
    public let target: String
    public let applicationIdentifier: String?

    public init(kind: ExternalFlowRuleWireKind, target: String, applicationIdentifier: String? = nil) {
        self.kind = kind
        self.target = target
        self.applicationIdentifier = applicationIdentifier
    }
}

public struct ExternalFlowRulesWire: Codable, Equatable, Sendable {
    public static let schema = "external-flow-rules-v1"
    public static let maxRules = 64
    public static let maxTargetBytes = 512
    public var format = Self.schema
    public let profileName: String
    public let rules: [ExternalFlowRuleWire]

    public init(profileName: String, rules: [ExternalFlowRuleWire]) {
        self.profileName = profileName
        self.rules = rules
    }

    public func validated() throws -> Self {
        guard format == Self.schema else { throw ExternalFlowRulesWireError.unsupportedVersion }
        guard (1...64).contains(profileName.utf8.count),
              profileName.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }),
              (1...Self.maxRules).contains(rules.count),
              rules.allSatisfy({ (1...Self.maxTargetBytes).contains($0.target.utf8.count) }),
              rules.allSatisfy({ rule in
                  guard let identifier = rule.applicationIdentifier else { return true }
                  return (1...255).contains(identifier.utf8.count) && identifier.utf8.allSatisfy { byte in
                      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                          byte == 45 || byte == 46 || byte == 95
                  }
              }) else {
            throw ExternalFlowRulesWireError.invalidRules
        }
        return self
    }
}

public enum ExternalFlowRulesWireError: String, Error, Sendable {
    case unsupportedVersion, invalidRules
}
