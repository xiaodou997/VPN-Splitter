// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
import PolicyCore

/// One DOMAIN (exact) or DOMAIN-SUFFIX (apex-only) entry from the execution rules text.
public struct ExternalDomainRule: Equatable, Sendable {
    public let name: String
    public let suffixApex: Bool
    public init(name: String, suffixApex: Bool) {
        self.name = name; self.suffixApex = suffixApex
    }
}

/// Parsed Helper rules text: literal IPv4/CIDR lines stay untouched; bounded
/// DOMAIN/DOMAIN-SUFFIX entries are resolved by the Helper process. A suffix rule
/// can only resolve its apex hostname — subdomains are not enumerable offline.
/// DOMAIN-KEYWORD/APPLICATION and any unknown typed prefix stay refused as a whole.
public struct ExternalDomainRuleSet: Equatable, Sendable {
    /// Bounds worst-case blocking resolver work inside one prepare window.
    public static let maxDomains = 8
    public let staticLines: [String]
    public let domains: [ExternalDomainRule]
    public static func parse(_ text: String) throws -> Self {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var staticLines: [String] = []
        var domains: [ExternalDomainRule] = []
        var seen: Set<String> = []
        for line in lines {
            let suffix = line.hasPrefix("DOMAIN-SUFFIX,")
            let exact = !suffix && line.hasPrefix("DOMAIN,")
            guard suffix || exact else {
                if line.contains(",") { throw ExternalError.invalidRules }
                staticLines.append(line); continue
            }
            let raw = String(line.dropFirst(suffix ? "DOMAIN-SUFFIX,".count : "DOMAIN,".count))
            guard let name = ExternalSavedRule.normalizedDomainValue(raw, suffix: suffix) else {
                throw ExternalError.invalidRules
            }
            if seen.insert(name).inserted {
                domains.append(ExternalDomainRule(name: name, suffixApex: suffix))
                guard domains.count <= maxDomains else { throw ExternalError.limitExceeded }
            }
        }
        return Self(staticLines: staticLines, domains: domains)
    }
}

/// Deterministic domain → /32 expansion. `sources` maps each added CIDR line to its
/// display origin (suffix rules are annotated apex-only) for the confirmation window.
public struct ExternalDomainExpansion: Equatable, Sendable {
    public let lines: [String]
    public let sources: [String: String]
    public let destinations: Set<IPv4CIDR>
    public let truncated: Bool
    public init(lines: [String], sources: [String: String], destinations: Set<IPv4CIDR>, truncated: Bool) {
        self.lines = lines; self.sources = sources; self.destinations = destinations; self.truncated = truncated
    }
}

/// Pure expansion logic; the blocking resolver is injected. Any failing or empty
/// domain rejects the whole set — a partial silent downgrade is never produced.
public enum ExternalDomainResolver {
    public static let perDomainLimit = 8
    public static let totalLimit = 32
    public typealias Resolve = @Sendable (String) throws -> [IPv4Address]
    public static func expand(domains: [ExternalDomainRule], staticLines: [String] = [], budget: Int,
                              resolve: Resolve) throws -> ExternalDomainExpansion {
        guard !domains.isEmpty else { return .init(lines: [], sources: [:], destinations: [], truncated: false) }
        guard budget > 0 else { throw ExternalError.limitExceeded }
        let staticDestinations = Set(staticLines.compactMap { try? IPv4CIDR($0.contains("/") ? $0 : $0 + "/32") })
        let cap = min(budget, totalLimit)
        var lines: [String] = []
        var sources: [String: String] = [:]
        var destinations: Set<IPv4CIDR> = []
        var truncated = false
        for rule in domains {
            let answers: [IPv4Address]
            do { answers = try resolve(rule.name) } catch { throw ExternalError.domainResolutionFailed }
            let usable = Array(Set(answers).filter { !ExternalPlanner.isUnroutableForDirect($0) }.sorted())
            guard !usable.isEmpty else { throw ExternalError.domainResolutionFailed }
            if usable.count > perDomainLimit { truncated = true }
            let origin = rule.suffixApex ? "\(rule.name) 后缀 apex" : rule.name
            for address in usable.prefix(perDomainLimit) {
                guard let cidr = try? IPv4CIDR(address: address, prefixLength: 32) else { continue }
                guard !destinations.contains(cidr), !staticDestinations.contains(cidr) else { continue }
                guard lines.count < cap else { truncated = true; break }
                let line = cidr.description
                lines.append(line); sources[line] = origin; destinations.insert(cidr)
            }
        }
        return .init(lines: lines, sources: sources, destinations: destinations, truncated: truncated)
    }
}

public struct ExternalDomainDiff: Equatable, Sendable {
    public let add: [IPv4CIDR]
    public let remove: [IPv4CIDR]
    public init(add: [IPv4CIDR], remove: [IPv4CIDR]) { self.add = add; self.remove = remove }
    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
}

/// Sustained-session refresh bookkeeping. The blocking re-resolution runs off the
/// caller's context; this value only decides when it is due and diffs the outcome.
/// A failed re-resolution keeps the current set and retries after another interval.
public struct ExternalDomainRefresh: Equatable, Sendable {
    public static let interval: TimeInterval = 60
    public private(set) var applied: Set<IPv4CIDR>
    public private(set) var lastRefresh: TimeInterval
    public private(set) var inFlight = false
    private var beganAt: TimeInterval?
    public init(applied: Set<IPv4CIDR>, startedAt: TimeInterval) {
        self.applied = applied; self.lastRefresh = startedAt
    }
    public func due(at now: TimeInterval) -> Bool {
        !inFlight && now.isFinite && now >= lastRefresh && now - lastRefresh >= Self.interval
    }
    @discardableResult public mutating func begin(at now: TimeInterval) -> Bool {
        guard due(at: now) else { return false }
        inFlight = true; beganAt = now
        return true
    }
    /// `resolved == nil` marks a failed re-resolution: the applied set is kept.
    /// A completion older than its own begin (clock regression) is ignored.
    @discardableResult public mutating func finish(at now: TimeInterval, resolved: Set<IPv4CIDR>?) -> ExternalDomainDiff? {
        guard inFlight, let began = beganAt, now.isFinite, now >= began else { return nil }
        inFlight = false; beganAt = nil; lastRefresh = now
        guard let resolved else { return nil }
        let diff = ExternalDomainDiff(add: resolved.subtracting(applied).sorted(),
                                      remove: applied.subtracting(resolved).sorted())
        applied = resolved
        return diff
    }
}
