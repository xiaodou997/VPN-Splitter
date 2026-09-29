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

    func testProviderMessageStatusMustMatchReportPresence() throws {
        var report = ExternalFlowProbeReport()
        report.total = 1; report.tcp = 1
        XCTAssertNoThrow(try ExternalFlowProbeSnapshot(
            configurationCount: 1, configurationEnabled: true,
            connectionStatus: "connected", providerMessageStatus: "pass",
            providerReport: report).validated())
        XCTAssertThrowsError(try ExternalFlowProbeSnapshot(
            configurationCount: 1, configurationEnabled: true,
            connectionStatus: "connected", providerMessageStatus: "send_failed",
            providerReport: report).validated())
        XCTAssertThrowsError(try ExternalFlowProbeSnapshot(
            configurationCount: 1, configurationEnabled: true,
            connectionStatus: "connected", providerMessageStatus: "pass",
            providerReport: nil).validated())
        XCTAssertNoThrow(try ExternalFlowProbeSnapshot(
            configurationCount: 1, configurationEnabled: false,
            connectionStatus: "disconnected", providerMessageStatus: "not_connected",
            providerReport: nil).validated())
        XCTAssertThrowsError(try ExternalFlowProbeSnapshot(
            configurationCount: 1, configurationEnabled: false,
            connectionStatus: "disconnected", providerMessageStatus: "mystery",
            providerReport: nil).validated())
    }

    func testRoundtripStoreUsesCountsOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "flow-wire-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ExternalFlowProbeSnapshotStore(directory: root.appendingPathComponent("bridge"))
        let initial = try await store.load()
        XCTAssertNil(initial)
        var report = ExternalFlowProbeReport(); report.total = 2; report.tcp = 2
        report.withRemoteHostname = 1
        let value = ExternalFlowProbeSnapshot(configurationCount: 1, configurationEnabled: true,
                                               connectionStatus: "connected", providerReport: report)
        try await store.save(value)
        let reloaded = try await store.load()
        let loaded = try XCTUnwrap(reloaded)
        XCTAssertEqual(loaded, value)
        let bridge = root.appendingPathComponent("bridge")
        let snapshotFile = bridge.appendingPathComponent("snapshot.json")
        let dirMode = try FileManager.default.attributesOfItem(atPath: bridge.path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: snapshotFile.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(dirMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        let data = try Data(contentsOf: snapshotFile)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertFalse(text.contains("org.telegram"))
        XCTAssertFalse(text.contains("/Applications/"))
    }
}
