// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
import PolicyCore
import ExternalFlowWire

public enum ExternalFlowCompileError: Error, Equatable, Sendable {
    case invalidProfile
    case duplicateApplicationBinding
    case unresolvedApplication(UUID)
    case invalidSigningIdentifier(UUID)
}

public struct ExternalApplicationBinding: Equatable, Sendable {
    public let ruleID: UUID
    public let signingIdentifier: String
    public init(ruleID: UUID, signingIdentifier: String) {
        self.ruleID = ruleID; self.signingIdentifier = signingIdentifier
    }
}

public struct ExternalFlowDescriptor: Equatable, Sendable {
    public let sourceAppSigningIdentifier: String?
    public let remoteHostname: String?
    public let destinationIPv4: IPv4Address?
    public init(sourceAppSigningIdentifier: String?, remoteHostname: String?, destinationIPv4: IPv4Address?) {
        self.sourceAppSigningIdentifier = sourceAppSigningIdentifier
        self.remoteHostname = remoteHostname
        self.destinationIPv4 = destinationIPv4
    }
}

public enum ExternalFlowDecision: Equatable, Sendable {
    case direct(ruleID: UUID)
    case systemDefault
}

public struct ExternalFlowPolicy: Sendable {
    private enum Matcher: Sendable {
        case ip(IPv4CIDR)
        case domain(String)
        case suffix(String)
        case keyword(String)
        case application(String)
    }
    private struct Rule: Sendable {
        let id: UUID
        let matcher: Matcher
    }
    private let rules: [Rule]

    public init(profile: ExternalSavedProfile, applicationBindings: [ExternalApplicationBinding] = []) throws {
        let profile = try profile.validated()
        var bindings: [UUID: String] = [:]
        for binding in applicationBindings {
            guard bindings[binding.ruleID] == nil else { throw ExternalFlowCompileError.duplicateApplicationBinding }
            let value = binding.signingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.validSigningIdentifier(value) else {
                throw ExternalFlowCompileError.invalidSigningIdentifier(binding.ruleID)
            }
            bindings[binding.ruleID] = value
        }
        var compiled: [Rule] = []
        for rule in profile.rules where rule.enabled {
            switch rule.kind {
            case .ipCIDR:
                guard let cidr = try? IPv4CIDR(rule.target) else { throw ExternalFlowCompileError.invalidProfile }
                compiled.append(.init(id: rule.id, matcher: .ip(cidr)))
            case .domain:
                compiled.append(.init(id: rule.id, matcher: .domain(rule.target)))
            case .domainSuffix:
                compiled.append(.init(id: rule.id, matcher: .suffix(rule.target)))
            case .domainKeyword:
                compiled.append(.init(id: rule.id, matcher: .keyword(rule.target)))
            case .application:
                let signing = rule.applicationIdentifier ?? bindings[rule.id]
                guard let signing else { throw ExternalFlowCompileError.unresolvedApplication(rule.id) }
                guard Self.validSigningIdentifier(signing) else {
                    throw ExternalFlowCompileError.invalidSigningIdentifier(rule.id)
                }
                compiled.append(.init(id: rule.id, matcher: .application(signing)))
            }
        }
        self.rules = compiled
    }

    public func evaluate(_ flow: ExternalFlowDescriptor) -> ExternalFlowDecision {
        let host = Self.normalizedObservedHostname(flow.remoteHostname)
        for rule in rules {
            let matched: Bool
            switch rule.matcher {
            case .ip(let cidr):
                matched = flow.destinationIPv4.map(cidr.contains) ?? false
            case .domain(let value):
                matched = host == value
            case .suffix(let value):
                matched = host == value || host.map { $0.hasSuffix("." + value) } == true
            case .keyword(let value):
                matched = host?.contains(value) == true
            case .application(let signing):
                matched = flow.sourceAppSigningIdentifier == signing
            }
            if matched { return .direct(ruleID: rule.id) }
        }
        return .systemDefault
    }

    private static func normalizedObservedHostname(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.utf8.count <= 253 else { return nil }
        return value
    }
    private static func validSigningIdentifier(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }
}
