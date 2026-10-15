// SPDX-License-Identifier: MIT
import XCTest
import PolicyCore
import ExternalCore
@testable import ExternalFlowCore

final class ExternalFlowRelayGateTests: XCTestCase {
    private func policy() throws -> ExternalFlowPolicy {
        try ExternalFlowPolicy(profile: .init(name: "flow", rules: [
            ExternalSavedRule(kind: .ipCIDR, target: "198.51.100.0/24")
        ]))
    }
    private func matched() throws -> ExternalFlowDescriptor {
        .init(sourceAppSigningIdentifier: nil, remoteHostname: nil,
              destinationIPv4: try IPv4Address("198.51.100.7"))
    }
    private func unmatched() throws -> ExternalFlowDescriptor {
        .init(sourceAppSigningIdentifier: nil, remoteHostname: nil,
              destinationIPv4: try IPv4Address("203.0.113.9"))
    }

    func testNoPolicyAlwaysPassesThrough() throws {
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: nil, paused: false,
                                                    descriptor: try matched(), hasInterface: true), .passThrough)
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: nil, paused: true,
                                                    descriptor: try matched(), hasInterface: true), .passThrough)
    }
    func testUnmatchedPassesThroughEvenWhenPaused() throws {
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: try policy(), paused: false,
                                                    descriptor: try unmatched(), hasInterface: true), .passThrough)
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: try policy(), paused: true,
                                                    descriptor: try unmatched(), hasInterface: true), .passThrough)
    }
    func testPausedClosesMatchedFlowsInsteadOfRelayOrFallback() throws {
        // Fail-closed (ADR-EX-INT-08): while paused a matched flow must never
        // become .relay (keep splitting) or .passThrough (silent direct when
        // the VPN is dead).
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: try policy(), paused: true,
                                                    descriptor: try matched(), hasInterface: true), .closedPaused)
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: try policy(), paused: true,
                                                    descriptor: try matched(), hasInterface: false), .closedPaused)
    }
    func testRelayRequiresUniqueInterface() throws {
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: try policy(), paused: false,
                                                    descriptor: try matched(), hasInterface: false), .refusedInterface)
        XCTAssertEqual(ExternalFlowRelayGate.decide(policy: try policy(), paused: false,
                                                    descriptor: try matched(), hasInterface: true), .relay)
    }
}
