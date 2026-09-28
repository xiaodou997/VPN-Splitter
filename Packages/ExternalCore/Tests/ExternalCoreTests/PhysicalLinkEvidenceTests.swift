// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PolicyCore
@testable import ExternalCore

/// Synthetic network input only. No live collector, route socket or network writes.
final class PhysicalLinkEvidenceTests: XCTestCase {
    private let header = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"
    private let base = """
    default 192.168.50.1 UGScg en7
    0/1 10.20.0.1 UGSc utun42
    128.0/1 10.20.0.1 UGSc utun42
    127 127.0.0.1 UCS lo0
    """

    private func observation(lan: String = "192.168.50 link#7 UCS en7 !",
                             extra: String = "", gateway: String = "192.168.50.1",
                             hasService: Bool = true, up: Bool = true, tunnel: Bool = false,
                             physicalName: String = "en7", defaults: String? = nil) throws -> ExternalObservation {
        let path = try ExternalPhysicalPath(service: "synthetic-service", interface: physicalName,
            gateway: IPv4Address(gateway), networks: [IPv4CIDR("192.168.50.0/24")])
        return try .init(capturedAtUptime: 100, interfaces: [
            .init(name: "en7", isUp: up, isTunnelCandidate: tunnel, addresses: [IPv4Address("192.168.50.9")]),
            .init(name: "utun42", isUp: true, isTunnelCandidate: true, addresses: [IPv4Address("10.20.0.2")]),
            .init(name: "lo0", isUp: true, isTunnelCandidate: false, addresses: [IPv4Address("127.0.0.1")])
        ], physicalPaths: hasService ? [path] : [],
            routes: ExternalRouteTable.parseDiagnosing(Data((header + (defaults ?? base) + "\n" + lan + "\n" + extra + "\n").utf8)),
            observedDNSServers: [])
    }
    private func preview(_ observed: ExternalObservation) throws -> ExternalCore.ExternalPreview {
        try ExternalPlanner.preview("203.0.113.7", observation: observed, now: 101)
    }
    private func rejects(_ error: ExternalError, _ observed: ExternalObservation,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try preview(observed), file: file, line: line) {
            XCTAssertEqual($0 as? ExternalError, error, file: file, line: line)
        }
    }

    func testElapsedConnectedParentAllowsPhysicalEvidenceNotExecution() throws {
        let observed = try observation()
        let result = try preview(observed)
        XCTAssertEqual(result.topology.physical.interface, "en7")
        XCTAssertEqual(result.topology.physical.gateway.description, "192.168.50.1")
        XCTAssertEqual(result.topology.pattern, .splitDefault)
        XCTAssertEqual(result.proposals.map { $0.destination.description }, ["203.0.113.7/32"])
        XCTAssertEqual(result.proposals[0].disposition, .wouldAdd)
        XCTAssertFalse(result.canApply)
        let parent = try XCTUnwrap(observed.routes.first { $0.destination.description == "192.168.50.0/24" })
        XCTAssertTrue(parent.isExpired) // The literal marker remains recorded.
        XCTAssertFalse(parent.usable) // No blanket relaxation of general eligibility.
        XCTAssertTrue(parent.isConnectedLANEvidence)
    }

    func testScopedAndNonStaticConnectedParentsStillRequireMatchingLAN() throws {
        for flags in ["UC", "UCS", "UCSI", "UCSIdig"] {
            let result = try preview(observation(lan: "192.168.50 link#7 \(flags) en7 !"))
            XCTAssertEqual(result.topology.physical.interface, "en7")
            XCTAssertFalse(result.canApply)
        }
    }

    func testElapsedNeighborGatewayAndUnsafeFlagsCannotProveLAN() throws {
        for flags in ["CS", "US", "UcS", "UCSR", "UCSB", "UCSW", "UCSL", "UCSG",
                      "UCSX", "UCSY", "UCSD", "UCSM", "UCSm", "UCSb", "UCS1"] {
            rejects(.physicalUnknown, try observation(lan: "192.168.50 link#7 \(flags) en7 !"))
        }
        for gateway in ["192.168.50.1", "aa:bb:cc:dd:ee:ff"] {
            rejects(.physicalUnknown, try observation(lan: "192.168.50 \(gateway) UCS en7 !"))
        }
        for row in ["192.168.50.1 aa:bb:cc:dd:ee:ff UHLWIir en7 !",
                    "192.168.50.1/32 link#7 UCS en7 !",
                    "192.168.50.0/31 link#7 UCS en7 !"] {
            rejects(.physicalUnknown, try observation(lan: row))
        }
    }

    func testDefaultWrongPrefixAndWrongInterfaceCannotReplaceLAN() throws {
        for row in ["default link#7 UCSI en7 !", "192.168/16 link#7 UCS en7 !",
                    "192.168.50.0/25 link#7 UCS en7 !", "192.168.51 link#7 UCS en7 !",
                    "192.168.50 link#42 UCS utun42 !", "192.168.50 link#8 UCS en8 !"] {
            rejects(.physicalUnknown, try observation(lan: row))
        }
        rejects(.physicalUnknown, try observation(lan: "", extra: "192.168.50.1 aa:bb:cc:dd:ee:ff UHLWIir en7 100"))
    }

    func testServiceAndLiveInterfaceCannotBeSynthesizedFromLinkRow() throws {
        rejects(.physicalUnknown, try observation(hasService: false))
        rejects(.physicalUnknown, try observation(up: false))
        rejects(.physicalUnknown, try observation(tunnel: true))
        rejects(.physicalUnknown, try observation(physicalName: "en8"))
    }

    func testRouterMustRemainCurrentOnLinkAndNotLocalOrReserved() throws {
        for gateway in ["198.51.100.1", "192.168.50.0", "192.168.50.255", "192.168.50.9", "127.0.0.1"] {
            rejects(.physicalUnknown, try observation(gateway: gateway))
        }
    }

    func testMatchingTwoPhysicalServicesRemainAmbiguous() throws {
        let original = try observation()
        let first = try XCTUnwrap(original.physicalPaths.first)
        let second = ExternalPhysicalPath(service: "other-synthetic-service", interface: first.interface,
                                          gateway: first.gateway, networks: first.networks)
        let multiple = try ExternalObservation(capturedAtUptime: 100, interfaces: original.interfaces,
            physicalPaths: [first, second], routes: original.routes, observedDNSServers: [])
        rejects(.physicalAmbiguous, multiple)
    }

    func testElapsedVPNOrGatewayRoutesDoNotBecomeGenerallyEligible() throws {
        for old in ["default 192.168.50.1 UGScg en7", "0/1 10.20.0.1 UGSc utun42"] {
            let changed = base.split(separator: "\n").map { String($0) == old ? old + " !" : String($0) }.joined(separator: "\n")
            rejects(.unsupportedTopology, try observation(defaults: changed))
        }
        rejects(.existingRouteConflict, try observation(extra: "203.0.113.7 192.168.50.1 UGHS en7 !"))
        rejects(.existingRouteConflict, try observation(extra: "203.0.113.7 10.20.0.1 UGHS utun42 !"))
    }

    func testScopedConflictsAndBorrowedRoutesKeepTheirOwnershipBoundary() throws {
        rejects(.scopedRouteConflict, try observation(extra: "203.0.113.7 192.168.50.1 UGHWI en7 !"))
        let result = try preview(observation(extra: "203.0.113.7 192.168.50.1 UGHS en7"))
        XCTAssertEqual(result.proposals[0].disposition, .alreadyDirectNoOwnership)
        XCTAssertFalse(result.canApply)
    }

    func testMarkerIsPreservedInSnapshotIdentityAndUnknownExpiryStillFails() throws {
        let elapsed = try observation()
        let blank = try observation(lan: "192.168.50 link#7 UCS en7")
        let countdownA = try observation(lan: "192.168.50 link#7 UCS en7 10")
        let countdownB = try observation(lan: "192.168.50 link#7 UCS en7 9")
        XCTAssertNotEqual(elapsed.routes, blank.routes)
        XCTAssertEqual(countdownA.routes, countdownB.routes)
        XCTAssertEqual(try preview(blank).topology.physical, try preview(elapsed).topology.physical)
        XCTAssertThrowsError(try observation(lan: "192.168.50 link#7 UCS en7 ?")) {
            XCTAssertEqual(($0 as? ExternalRouteParseDiagnostic)?.field, .expiry)
        }
    }

    func testProtectedRangesAndSnapshotFreshnessStillBlock() throws {
        let observed = try observation()
        XCTAssertThrowsError(try ExternalPlanner.preview("192.168.50.20", observation: observed, now: 101)) {
            XCTAssertEqual($0 as? ExternalError, .protectedRange)
        }
        for now in [99.0, 130, .infinity, .nan] {
            XCTAssertThrowsError(try ExternalPlanner.topology(observed, now: now)) {
                XCTAssertEqual($0 as? ExternalError, .expired)
            }
        }
    }

    func testDefaultReplacementAlsoUsesValidatedConnectedParent() throws {
        let defaults = "default 10.20.0.1 UGSc utun42\n127 127.0.0.1 UCS lo0"
        let result = try preview(observation(defaults: defaults))
        XCTAssertEqual(result.topology.pattern, .replacedDefault)
        XCTAssertEqual(result.topology.physical.interface, "en7")
        XCTAssertFalse(result.canApply)
    }
}
