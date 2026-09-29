// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ExternalFlowWire

final class ExternalFlowWireTests: XCTestCase, @unchecked Sendable {
    func testReportBoundsAndSnapshotValidation() throws {
        var report = ExternalFlowProbeReport()
        report.total = 4; report.tcp = 4
        report.withSourceSigningIdentifier = 3
        report.withRemoteHostname = 2
        XCTAssertNoThrow(try report.validated())
        report.withRemoteHostname = 5
        XCTAssertThrowsError(try report.validated())

        let snapshot = ExternalFlowProbeSnapshot(configurationCount: 1,
            configurationEnabled: true, connectionStatus: "connected", providerReport: nil)
        XCTAssertNoThrow(try snapshot.validated())
        XCTAssertThrowsError(try ExternalFlowProbeSnapshot(configurationCount: 9,
            configurationEnabled: false, connectionStatus: "invalid status", providerReport: nil).validated())
    }

    func testRoundtripStoreUsesCountsOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "flow-wire-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExternalFlowProbeSnapshotStore(directory: root.appendingPathComponent("bridge"))
        XCTAssertNil(try await store.load())
        var report = ExternalFlowProbeReport(); report.total = 2; report.tcp = 2
        report.withRemoteHostname = 1
        let value = ExternalFlowProbeSnapshot(configurationCount: 1, configurationEnabled: true,
                                               connectionStatus: "connected", providerReport: report)
        try await store.save(value)
        let loaded = try XCTUnwrap(try await store.load())
        XCTAssertEqual(loaded, value)
        let data = try Data(contentsOf: root.appendingPathComponent("bridge/snapshot.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertFalse(text.contains("org.telegram"))
        XCTAssertFalse(text.contains("/Applications/"))
    }
}
