// SPDX-License-Identifier: MIT
import Foundation

/// Pure decision core of the isolation guard (ADR-EX-INT-09). No I/O, no clock,
/// no NetworkExtension: the caller feeds route-form availability and probe
/// results in order and executes the returned action via the existing bounded
/// provider verbs (relay-pause-v1 / relay-resume-v1).
///
/// Pause semantics: matched DIRECT flows are closed (fail-closed), so rule
/// covered connections lose public connectivity while the VPN is unhealthy.
/// Only a pause this guard issued is auto-resumed; a manual pause is untouched.
public struct ExternalFlowGuardLogic: Sendable, Equatable {
    public enum PauseReason: String, Sendable {
        /// Tunnel route form lost / physical path lost / unsupported topology.
        case routeFormLost
        /// Route form looks online but the VPN path repeatedly failed probing.
        case vpnPathDead
    }
    public enum Action: String, Sendable, Equatable {
        case stay, pauseRouteFormLost, pauseVPNPathDead, resume
    }
    public static let failureThreshold = 2

    public private(set) var paused: PauseReason?
    private var consecutiveVPNFailures = 0
    /// The pause cleared by the most recent resume action, kept so a failed
    /// actuation can be rolled back and re-emitted on the next cycle.
    private var resumedFrom: PauseReason?
    public init() {}

    /// Route-form verdict from the watchdog tracker. `false` pauses
    /// immediately; recovery only clears a route-form pause (probe pauses are
    /// re-evaluated by the next probe cycle).
    @discardableResult
    public mutating func onRouteForm(available: Bool) -> Action {
        if available {
            guard paused == .routeFormLost else { return .stay }
            resumedFrom = paused
            paused = nil
            return .resume
        }
        consecutiveVPNFailures = 0
        guard paused != .routeFormLost else { return .stay }
        paused = .routeFormLost
        return .pauseRouteFormLost
    }

    /// One probing cycle. Only the VPN-path verdict drives state; the caller
    /// uses the physical result purely for display. Call only while the route
    /// form is online.
    @discardableResult
    public mutating func onProbe(vpnPathOK: Bool) -> Action {
        if vpnPathOK {
            consecutiveVPNFailures = 0
            guard paused == .vpnPathDead else { return .stay }
            resumedFrom = paused
            paused = nil
            return .resume
        }
        consecutiveVPNFailures += 1
        guard consecutiveVPNFailures >= Self.failureThreshold, paused == nil else { return .stay }
        paused = .vpnPathDead
        return .pauseVPNPathDead
    }

    /// The pause actuation did not reach the provider: roll back so the next
    /// cycles re-derive and re-emit the pause.
    public mutating func undoPause() {
        paused = nil; consecutiveVPNFailures = 0; resumedFrom = nil
    }

    /// The resume actuation did not reach the provider: restore the cleared
    /// pause so the next cycle re-emits the resume.
    public mutating func undoResume() {
        guard let resumedFrom else { return }
        paused = resumedFrom; self.resumedFrom = nil
    }
}
