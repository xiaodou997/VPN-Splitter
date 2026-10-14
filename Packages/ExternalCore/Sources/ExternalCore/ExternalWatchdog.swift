// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

/// Watchdog classification of one observation. `online` only means the routing
/// form matches the same planner decision used by the preview; it never claims
/// vendor, encryption, endpoint or enforcement verification. `unavailable`
/// keeps the exact failure code and never claims the VPN is certainly down.
public enum ExternalVPNHealth: Equatable, Sendable {
    case online(ExternalWatchdogTopology)
    case unavailable(ExternalError)
}

public struct ExternalWatchdogTopology: Equatable, Sendable {
    public let physicalInterface: String
    public let physicalGateway: IPv4Address
    public let tunnelInterface: String
    public let pattern: ExternalRoutingPattern
    public init(physicalInterface: String, physicalGateway: IPv4Address, tunnelInterface: String, pattern: ExternalRoutingPattern) {
        self.physicalInterface = physicalInterface; self.physicalGateway = physicalGateway
        self.tunnelInterface = tunnelInterface; self.pattern = pattern
    }
}

/// Coarse grouping of an `ExternalError` for transition semantics.
public enum ExternalWatchdogCauseKind: String, Sendable {
    /// Capture/parse/freshness problems: the network was not judged at all.
    case observation
    /// Physical service/gateway/link evidence missing or ambiguous.
    case physical
    /// Global tunnel route form missing or ambiguous.
    case tunnel
    /// Default/half-default route set is inconsistent.
    case topology
}

/// State transitions only; steady health produces no event.
public enum ExternalWatchdogEvent: String, Equatable, Sendable {
    case initialOnline, initialUnavailable
    /// Online → tunnel form lost or ambiguous: the original VPN looks down or renegotiating.
    case vpnDisconnected
    /// Online → physical path lost or ambiguous: the underlying network itself changed.
    case physicalPathLost
    /// Online → capture/parse failure: nothing is claimed about the VPN itself.
    case observationFailed
    /// Online → default route set no longer matches a supported form.
    case topologyBecameUnsupported
    /// Unavailable → online again (possibly a different tunnel/physical path).
    case vpnReconnected
    /// Online → online with a different tunnel interface: reconnect with a new utun.
    case tunnelInterfaceChanged
    /// Online → online with a different physical interface or gateway: network switch.
    case physicalPathChanged
    /// Online → online with a different split/replaced default form.
    case routingPatternChanged
}

/// Pure cross-snapshot state machine. No capture, clock, I/O or persistence; the
/// caller feeds observations in capture order and renders/records the result.
public struct ExternalWatchdogTracker: Sendable {
    public private(set) var health: ExternalVPNHealth?
    /// Last confirmed online topology, kept across outages so a reconnect can be
    /// reported against what was there before.
    public private(set) var lastOnline: ExternalWatchdogTopology?
    public init() {}

    public static func classify(_ observation: ExternalObservation) -> ExternalVPNHealth {
        do {
            let topology = try ExternalPlanner.topology(observation, now: observation.capturedAtUptime)
            return .online(.init(physicalInterface: topology.physical.interface,
                                 physicalGateway: topology.physical.gateway,
                                 tunnelInterface: topology.tunnelInterface, pattern: topology.pattern))
        } catch let error as ExternalError {
            return .unavailable(error)
        } catch {
            return .unavailable(.readFailed)
        }
    }

    public static func causeKind(_ error: ExternalError) -> ExternalWatchdogCauseKind {
        switch error {
        case .physicalUnknown, .physicalAmbiguous: return .physical
        case .tunnelUnknown, .tunnelAmbiguous: return .tunnel
        case .unsupportedTopology: return .topology
        default: return .observation
        }
    }

    @discardableResult
    public mutating func ingest(_ observation: ExternalObservation) -> ExternalWatchdogEvent? {
        transition(to: Self.classify(observation))
    }

    /// Feed a capture failure (read/parse) that never produced an observation.
    @discardableResult
    public mutating func ingestFailure(_ error: ExternalError) -> ExternalWatchdogEvent? {
        transition(to: .unavailable(error))
    }

    private mutating func transition(to new: ExternalVPNHealth) -> ExternalWatchdogEvent? {
        let old = health
        health = new
        switch (old, new) {
        case (.none, .online(let topology)):
            lastOnline = topology
            return .initialOnline
        case (.none, .unavailable):
            return .initialUnavailable
        case (.online(let before), .online(let now)):
            lastOnline = now
            if before.tunnelInterface != now.tunnelInterface { return .tunnelInterfaceChanged }
            if before.physicalInterface != now.physicalInterface || before.physicalGateway != now.physicalGateway {
                return .physicalPathChanged
            }
            if before.pattern != now.pattern { return .routingPatternChanged }
            return nil
        case (.online, .unavailable(let error)):
            switch Self.causeKind(error) {
            case .physical: return .physicalPathLost
            case .tunnel: return .vpnDisconnected
            case .topology: return .topologyBecameUnsupported
            case .observation: return .observationFailed
            }
        case (.unavailable, .online(let topology)):
            lastOnline = topology
            return .vpnReconnected
        case (.unavailable, .unavailable):
            return nil
        }
    }
}
