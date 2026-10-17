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
    /// Rows that are always retained: default via the physical gateway and the LAN parent.
    private func base() throws -> Set<ExternalRoute> {
        [try row("UGSc", prefix: "0.0.0.0/0", gateway: "192.0.2.1", expired: false),
         try row("UCS", prefix: "192.0.2.0/24", gateway: "link#2", expired: false)]
    }
    // ADR-EX-INT-11: cloned neighbor cache churn (the 2026-10-17 sustained-session
    // termination) never changes the epoch, in either direction; raw rows stay untouched.
    func testClonedNeighborCacheChurnDoesNotChangeEpoch() throws {
        let statics = try base()
        let plain = try row(), scoped = try row("UHLWIi")
        let other = try row(prefix: "192.0.2.7/32", gateway: "0:1:2:3:4:9")
        XCTAssertEqual(ExternalRouteEpoch.rows(statics), statics)
        XCTAssertEqual(ExternalRouteEpoch.rows(statics.union([plain])), ExternalRouteEpoch.rows(statics))
        XCTAssertEqual(ExternalRouteEpoch.rows(statics.union([scoped])), ExternalRouteEpoch.rows(statics))
        XCTAssertEqual(ExternalRouteEpoch.rows(statics.union([plain, other])),
                       ExternalRouteEpoch.rows(statics.union([scoped])))
        XCTAssertEqual(plain.flags, "UHLWI")
        XCTAssertEqual(scoped.flags, "UHLWIi")
    }
    // Field changes confined to exempt cache rows are ignored together with the row.
    func testFieldChangesOnCacheRowsAreIgnoredWithTheRow() throws {
        let statics = try base(), original = try row()
        for changed in [try row("UHLWIi"),
                        try row("UHLWIi", gateway: "0:1:2:3:4:6"),
                        try row("UHLWIi", gateway: "(incomplete)"),
                        try row("UHLWIi", interface: "en8"),
                        try row("UHLWIi", expired: false)] {
            XCTAssertEqual(ExternalRouteEpoch.rows(statics.union([original])),
                           ExternalRouteEpoch.rows(statics.union([changed])))
        }
    }
    // Static and owned-shaped (G/S/PROTO2) rows still move the epoch in both directions.
    func testStaticAndOwnedRouteAddRemoveStillChangeEpoch() throws {
        let statics = try base()
        for flags in ["UGHS2", "UGS2", "UGHS", "UGSc", "UGHSI"] {
            let foreign = try row(flags, prefix: "198.51.100.4/32", gateway: "192.0.2.1", expired: false)
            XCTAssertNotEqual(ExternalRouteEpoch.rows(statics), ExternalRouteEpoch.rows(statics.union([foreign])), flags)
        }
        XCTAssertNotEqual(ExternalRouteEpoch.rows(statics), ExternalRouteEpoch.rows([]))
        XCTAssertNotEqual(ExternalRouteEpoch.rows(statics), ExternalRouteEpoch.rows([statics.first!]))
    }
    // Only the exact UHLWI/UHLWIi flag strings at exactly /32 are exempt.
    func testNonExactFlagsOrPrefixRowsAreNotExempt() throws {
        let statics = try base()
        for flags in ["UHLW", "UHL", "UHLWi", "UHLWIr", "UHLWIS", "UHLWIi3", "UHLWIZ", "UHLSI", "uhlwi"] {
            let suspect = try row(flags)
            XCTAssertNotEqual(ExternalRouteEpoch.rows(statics), ExternalRouteEpoch.rows(statics.union([suspect])), flags)
        }
        for prefix in ["192.0.2.0/24", "192.0.2.0/31"] {
            let wide = try row(prefix: prefix), wideScoped = try row("UHLWIi", prefix: prefix)
            XCTAssertNotEqual(ExternalRouteEpoch.rows(statics), ExternalRouteEpoch.rows(statics.union([wide])), prefix)
            XCTAssertNotEqual(ExternalRouteEpoch.rows(statics), ExternalRouteEpoch.rows(statics.union([wideScoped])), prefix)
        }
    }
    // Retained rows keep full field sensitivity, including an IFREF difference on a
    // non-exempt row (the ADR-EX-INT-04 normalization no longer applies anywhere).
    func testSemanticFieldsOnRetainedRowsStillChangeEpoch() throws {
        let original = try row("UHLWIS")
        for changed in [try row("UHLWIS", prefix: "192.0.2.2/32"),
                        try row("UHLWIS", gateway: "0:1:2:3:4:6"),
                        try row("UHLWIS", interface: "en8"),
                        try row("UHLWIS", expired: false),
                        try row("UHLWISi")] {
            XCTAssertNotEqual(ExternalRouteEpoch.rows([original]), ExternalRouteEpoch.rows([changed]))
        }
        XCTAssertNotEqual(ExternalRouteEpoch.rows([original]), ExternalRouteEpoch.rows([]))
    }
    // Ambiguity never widens the exemption: a drop that would empty a non-empty table
    // falls back to the raw set, so cache-only tables stay fully sensitive and
    // distinct rows can never collapse into one comparison key.
    func testDroppingEverythingFallsBackToTheRawSet() throws {
        let original = try row(), other = try row("UHLWIi")
        let cacheOnly: Set<ExternalRoute> = [original, other]
        XCTAssertEqual(ExternalRouteEpoch.rows(cacheOnly), cacheOnly)
        XCTAssertNotEqual(ExternalRouteEpoch.rows(cacheOnly), ExternalRouteEpoch.rows([original]))
        XCTAssertNotEqual(ExternalRouteEpoch.rows([original]), ExternalRouteEpoch.rows([]))
        XCTAssertEqual(ExternalRouteEpoch.rows([]), Set<ExternalRoute>())
        let churned: Set<ExternalRoute> = [try row("UHLWIi", gateway: "0:1:2:3:4:6")]
        XCTAssertNotEqual(ExternalRouteEpoch.rows(cacheOnly), ExternalRouteEpoch.rows(churned))
    }
}
