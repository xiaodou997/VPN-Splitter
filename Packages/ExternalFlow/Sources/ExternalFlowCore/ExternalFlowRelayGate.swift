// SPDX-License-Identifier: MIT
import Foundation

/// Pure gate for the relay engine's per-flow decision (ADR-EX-INT-08).
/// `closedPaused` means the engine takes ownership and closes the flow
/// immediately: while paused, DIRECT-matched traffic must NOT fall back to the
/// system path, because a dead VPN would turn that fallback into a silent
/// direct connection. Unmatched flows always pass through to the system/VPN.
public enum ExternalFlowRelayGate {
    public enum Decision: String, Sendable, Equatable {
        case passThrough, relay, closedPaused, refusedInterface
    }
    public static func decide(policy: ExternalFlowPolicy?, paused: Bool,
                              descriptor: ExternalFlowDescriptor, hasInterface: Bool) -> Decision {
        guard let policy else { return .passThrough }
        guard case .direct = policy.evaluate(descriptor) else { return .passThrough }
        if paused { return .closedPaused }
        return hasInterface ? .relay : .refusedInterface
    }
}
