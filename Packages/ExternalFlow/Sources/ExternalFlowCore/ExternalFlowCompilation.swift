// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
import ExternalFlowWire
import PolicyCore

public extension ExternalFlowDescriptor {
    /// `remoteEndpointHost` is the host part of the flow's remote endpoint
    /// (usually a literal IPv4 for transparent proxy TCP flows). Non-IPv4
    /// values yield a nil destination so only hostname/application rules apply.
    init(sourceAppSigningIdentifier: String?, remoteHostname: String?, remoteEndpointHost: String?) {
        let host = remoteEndpointHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(sourceAppSigningIdentifier: sourceAppSigningIdentifier,
                  remoteHostname: remoteHostname,
                  destinationIPv4: host.flatMap { try? IPv4Address($0) })
    }
}

public extension ExternalFlowPolicy {
    /// Compiles a bounded wire export into an executable policy. The whole set
    /// is rejected on any invalid or unresolved rule; there is no partial
    /// policy.
    init(rulesWire: ExternalFlowRulesWire) throws {
        let wire = try rulesWire.validated()
        let rules: [ExternalSavedRule] = try wire.rules.map { rule in
            let kind: ExternalSavedRuleKind
            switch rule.kind {
            case .ipCIDR: kind = .ipCIDR
            case .domain: kind = .domain
            case .domainSuffix: kind = .domainSuffix
            case .domainKeyword: kind = .domainKeyword
            case .application: kind = .application
            }
            return try ExternalSavedRule(kind: kind, target: rule.target,
                                         applicationIdentifier: rule.applicationIdentifier,
                                         enabled: true).validated()
        }
        let profile = try ExternalSavedProfile(name: wire.profileName, rules: rules).validated()
        try self.init(profile: profile)
    }
}
