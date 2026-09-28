// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

public enum ExternalRoutingPattern: String, Sendable {
    case splitDefault = "0/1 + 128/1"
    case replacedDefault = "default → tunnel"
}

public struct ExternalTopology: Sendable {
    public let physical: ExternalPhysicalPath
    public let tunnelInterface: String
    public let pattern: ExternalRoutingPattern
}

public struct ExternalRouteProposal: Sendable, Identifiable {
    public enum Disposition: String, Sendable { case wouldAdd, alreadyDirectNoOwnership }
    public var id: String { destination.description }
    public let destination: IPv4CIDR
    public let gateway: IPv4Address
    public let interface: String
    public let disposition: Disposition
}

/// Immutable inspection result. It deliberately cannot authorize a future Helper.
public struct ExternalPreview: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let observationID: UUID
    public let topology: ExternalTopology
    public let proposals: [ExternalRouteProposal]
    public let ruleEvaluations: [RuleEvaluation]
    public var canApply: Bool { false }
    public static let boundary = "只读预览：未验证厂商、隧道加密、VPN 端点、强制策略或实际出口。未写路由、未改 DNS；IPv6 未管理，无 Kill Switch。已有路由不会因此归本应用所有。"
    public var description: String { "ExternalPreview(<redacted>; NOT_APPLIED)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public enum ExternalPlanner {
    /// Use only the unique, currently observed service/router/link combination. No
    /// saved gateway, en0 assumption, vendor lookup or default-as-physical fallback.
    public static func topology(_ observation: ExternalObservation, now: TimeInterval) throws -> ExternalTopology {
        try observation.checkFresh(now: now)
        let interfaces = observation.interfaces.filter(\.isUp)
        let paths = observation.physicalPaths.filter { path in
            guard let interface = interfaces.first(where: { $0.name == path.interface }),
                  !interface.isTunnelCandidate,
                  !path.networks.contains(where: { $0.prefixLength == 0 }),
                  !isReserved(path.gateway),
                  !interface.addresses.contains(path.gateway),
                  path.networks.contains(where: { network in
                      network.prefixLength < 31 && network.contains(path.gateway) &&
                      path.gateway != network.networkAddress &&
                      UInt64(path.gateway.rawValue) != UInt64(network.networkAddress.rawValue) + network.addressCount - 1 &&
                      interface.addresses.contains(where: network.contains)
                  }) else { return false }
            // Connected LAN evidence is distinct from general route eligibility:
            // Darwin cloning parents may show Expire "!". Still require the current
            // physical interface and exact observed LAN, never only a neighbor row.
            return observation.routes.contains { route in
                route.isConnectedLANEvidence && route.interface == path.interface &&
                path.networks.contains(route.destination) && route.destination.contains(path.gateway)
            }
        }
        guard !paths.isEmpty else { throw ExternalError.physicalUnknown }
        guard paths.count == 1 else { throw ExternalError.physicalAmbiguous }
        let names = Set(interfaces.filter(\.isTunnelCandidate).filter { candidate in
            observation.routes.contains { $0.interface == candidate.name && $0.usable && !isReserved($0.destination.networkAddress) }
        }.map(\.name))
        // Include split default at 0/1, whose first address is reserved but whole route is not.
        let globalNames = Set(interfaces.filter(\.isTunnelCandidate).filter { candidate in
            observation.routes.contains { $0.interface == candidate.name && $0.usable && !$0.scoped && $0.destination.prefixLength <= 1 }
        }.map(\.name))
        let tunnels = names.union(globalNames)
        guard !tunnels.isEmpty else { throw ExternalError.tunnelUnknown }
        guard tunnels.count == 1, let tunnel = tunnels.first else { throw ExternalError.tunnelAmbiguous }
        let defaults = observation.routes.filter { !$0.scoped && $0.destination.prefixLength <= 1 }
        guard defaults.allSatisfy(\.usable) else { throw ExternalError.unsupportedTopology }
        let halves = defaults.filter { $0.destination.prefixLength == 1 }
        let pattern: ExternalRoutingPattern
        if !halves.isEmpty {
            guard halves.count == 2, Set(halves.map(\.destination)).count == 2,
                  halves.allSatisfy({ $0.interface == tunnel }),
                  Set(halves.map(\.gateway)).count == 1 else { throw ExternalError.unsupportedTopology }
            pattern = .splitDefault
        } else {
            guard defaults.count == 1, defaults.first?.interface == tunnel else { throw ExternalError.tunnelUnknown }
            pattern = .replacedDefault
        }
        // Under a /1 pair a single physical default is expected; reject foreign or
        // duplicate unscoped defaults instead of interpreting route priority heuristically.
        let zeros = defaults.filter { $0.destination.prefixLength == 0 }
        guard zeros.count <= 1, zeros.allSatisfy({ $0.interface == tunnel ||
            ($0.interface == paths[0].interface && $0.gateway == paths[0].gateway.description) }) else {
            throw ExternalError.unsupportedTopology
        }
        return .init(physical: paths[0], tunnelInterface: tunnel, pattern: pattern)
    }

    public static func preview(_ text: String, observation: ExternalObservation, now: TimeInterval) throws -> ExternalPreview {
        let selected = try topology(observation, now: now)
        guard text.utf8.count <= 16_384 else { throw ExternalError.limitExceeded }
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...64).contains(lines.count) else { throw ExternalError.invalidRules }
        let rules: [PolicyRule]
        do {
            rules = try lines.enumerated().map { index, value in
                PolicyRule(id: "external-direct-\(index + 1)", match: .ipv4(try IPv4CIDR(value.contains("/") ? value : value + "/32")), action: .direct)
            }
        } catch { throw ExternalError.invalidRules }
        let plan: IPv4PolicyPlan
        do {
            plan = try IPv4PolicyCompiler.compile(.init(defaultAction: .vpn, rules: rules), capabilities: .external,
                context: .init(sessionID: observation.id.uuidString, backendID: "external", generation: 1, networkEpoch: 1),
                limits: .init(maxRules: 64))
        } catch { throw ExternalError.invalidRules }
        var protected = try reserved.map(IPv4CIDR.init)
        protected += observation.physicalPaths.flatMap(\.networks)
        protected += try (observation.interfaces.flatMap(\.addresses) + observation.observedDNSServers)
            .map { try IPv4CIDR(address: $0, prefixLength: 32) }
        let proposals = try plan.overrides.map { route -> ExternalRouteProposal in
            let target = route.cidr
            guard !protected.contains(where: { overlaps($0, target) }) else { throw ExternalError.protectedRange }
            let overlapping = observation.routes.filter { overlaps($0.destination, target) }
            var already = false
            for existing in overlapping {
                if existing.scoped {
                    // Broad scoped defaults don't prove the ordinary route lookup, but
                    // an equally/more-specific scoped row makes this proposal ambiguous.
                    if existing.destination.prefixLength >= target.prefixLength { throw ExternalError.scopedRouteConflict }
                    continue
                }
                if existing.destination.prefixLength >= target.prefixLength {
                    if existing.destination == target, existing.usable,
                       existing.interface == selected.physical.interface,
                       existing.gateway == selected.physical.gateway.description,
                       !existing.flags.contains("W"), !existing.flags.contains("L") {
                        already = true
                    } else { throw ExternalError.existingRouteConflict }
                } else if !existing.usable || (existing.destination.prefixLength > 0 && existing.interface != selected.tunnelInterface) {
                    throw ExternalError.existingRouteConflict
                }
            }
            return .init(destination: target, gateway: selected.physical.gateway, interface: selected.physical.interface,
                         disposition: already ? .alreadyDirectNoOwnership : .wouldAdd)
        }
        return .init(observationID: observation.id, topology: selected, proposals: proposals, ruleEvaluations: plan.ruleEvaluations)
    }
    private static let reserved = ["0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/3"]
    private static func isReserved(_ ip: IPv4Address) -> Bool { reserved.contains { (try? IPv4CIDR($0))?.contains(ip) == true } }
    private static func overlaps(_ a: IPv4CIDR, _ b: IPv4CIDR) -> Bool { a.contains(b.networkAddress) || b.contains(a.networkAddress) }
}
