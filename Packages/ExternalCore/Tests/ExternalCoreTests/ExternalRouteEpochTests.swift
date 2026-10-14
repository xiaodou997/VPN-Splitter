// SPDX-License-Identifier: MIT
import XCTest
import PolicyCore
@testable import ExternalCore

final class ExternalRouteEpochTests: XCTestCase {
    private func row(_ flags: String = "UHLWI", prefix: String = "192.0.2.1/32",
                     gateway: String = "0:1:2:3:4:5", interface: String = "en7",
                     expired: Bool = true) throws -> ExternalRoute {
        .init(destination: try IPv4CIDR(prefix), gateway: gateway, interface: interface,
              flags: flags, isExpired: expired)
    }
    func testNeighborReferenceBitOnlyIsExcludedFromEpochNotRawRows() throws {
        let before = try row(), after = try row("UHLWIi")
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(ExternalRouteEpoch.rows([before]), ExternalRouteEpoch.rows([after]))
        XCTAssertEqual(after.flags, "UHLWIi")
        // Scope is independent of whether an interface is selected for DIRECT.
        let bridge = try row(interface: "bridge100"), referenced = try row("UHLWIi", interface: "bridge100")
        XCTAssertEqual(ExternalRouteEpoch.rows([bridge]), ExternalRouteEpoch.rows([referenced]))
    }
    func testOtherFlagsPrefixesAndOwnedRoutesRemainExact() throws {
        for flags in ["UHLW", "UHL", "UHLWIr", "UHLWIS", "UGHS2", "UGSc", "UHLWIZ"] {
            let before = try row(flags), after = try row(flags + "i")
            XCTAssertNotEqual(ExternalRouteEpoch.rows([before]), ExternalRouteEpoch.rows([after]))
        }
        XCTAssertNotEqual(ExternalRouteEpoch.rows([try row(prefix: "192.0.2.0/24")]),
                          ExternalRouteEpoch.rows([try row("UHLWIi", prefix: "192.0.2.0/24")]))
    }
    func testSemanticFieldsAndRowPresenceStillChangeEpoch() throws {
        let original = try row()
        for changed in [try row("UHLWIi", prefix: "192.0.2.2/32"),
                        try row("UHLWIi", gateway: "0:1:2:3:4:6"),
                        try row("UHLWIi", gateway: "(incomplete)"),
                        try row("UHLWIi", interface: "en8"),
                        try row("UHLWIi", expired: false)] {
            XCTAssertNotEqual(ExternalRouteEpoch.rows([original]), ExternalRouteEpoch.rows([changed]))
        }
        XCTAssertNotEqual(ExternalRouteEpoch.rows([original]), ExternalRouteEpoch.rows([]))
    }
    func testDuplicateNormalizationKeysAreNotCollapsed() throws {
        let original = try row(), other = try row("UHLWIi")
        let duplicate: Set<ExternalRoute> = [original, other]
        XCTAssertEqual(ExternalRouteEpoch.rows(duplicate), duplicate)
        XCTAssertNotEqual(ExternalRouteEpoch.rows(duplicate), ExternalRouteEpoch.rows([original]))
    }
}
