// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import ExternalCore
import PolicyCore
@testable import ExternalExecution
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func snapshot(rows: Set<ExternalRoute>? = nil, dns: String = "10.8.0.53", gateway: String = "192.0.2.1") throws -> ExternalObservation {
    let routes = try rows ?? Set([
        ExternalRoute(destination: IPv4CIDR("0.0.0.0/0"), gateway: gateway, interface: "en7", flags: "UGSc"),
        ExternalRoute(destination: IPv4CIDR("192.0.2.0/24"), gateway: "link#2", interface: "en7", flags: "UCS"),
        ExternalRoute(destination: IPv4CIDR("0.0.0.0/1"), gateway: "10.8.0.1", interface: "utun42", flags: "UGSc"),
        ExternalRoute(destination: IPv4CIDR("128.0.0.0/1"), gateway: "10.8.0.1", interface: "utun42", flags: "UGSc")])
    return try ExternalObservation(capturedAtUptime: 100, interfaces: [
        .init(name: "en7", isUp: true, isTunnelCandidate: false, addresses: [IPv4Address("192.0.2.5")]),
        .init(name: "utun42", isUp: true, isTunnelCandidate: true, addresses: [IPv4Address("10.8.0.2")])],
        physicalPaths: [.init(service: "service-a", interface: "en7", gateway: IPv4Address(gateway), networks: [IPv4CIDR("192.0.2.0/24")])],
        routes: routes, observedDNSServers: [IPv4Address(dns)])
}
private func row(_ route: ExternalLeaseRoute) -> ExternalRoute {
    .init(destination: route.destination, gateway: route.gateway.description, interface: route.interface,
          flags: route.destination.prefixLength == 32 ? "UGHS2" : "UGS2")
}
private func plan(_ rules: String = "198.51.100.4", baseline: ExternalObservation? = nil) throws -> ExternalLeasePlan {
    try .prepare(rules: rules, observation: baseline ?? snapshot(), uptime: 101, clock: 10)
}
private final class Clock { var now = 11.0; var cancelled = false }
private final class Driver: ExternalRouteOperating {
    var rows: Set<ExternalRoute>
    var dns = "10.8.0.53"
    var live: Set<UInt64> = []
    var receipts: [UInt64: ExternalLeaseRoute] = [:]
    var adds: [ExternalLeaseRoute] = []; var removes: [UInt64] = []
    var next = UInt64(1); var observeCount = 0
    var observationFailure = false; var eventFailure = false
    var rejectAt: Int?; var unknownAt: Int?; var unknownCreates = false
    var removeRefused = false; var removeRetainsRow = false; var omitAddRow = false
    var afterAdd: (() -> Void)?
    init(_ initial: ExternalObservation? = nil) throws { rows = try (initial ?? snapshot()).routes }
    func observe() throws -> ExternalObservation {
        observeCount += 1
        if observationFailure { throw ExternalLeaseFailure.observationFailed }
        return try snapshot(rows: rows, dns: dns)
    }
    func drainEvents() -> Bool { !eventFailure }
    func owns(_ token: UInt64) -> Bool { live.contains(token) }
    func add(_ route: ExternalLeaseRoute) -> ExternalAddResult {
        adds.append(route)
        if rejectAt == adds.count { rows.insert(row(route)); return .rejected } // Foreign EEXIST, never owned.
        if unknownAt == adds.count {
            if unknownCreates { rows.insert(row(route)) }
            return .uncertain
        }
        let token = next; next += 1; receipts[token] = route; live.insert(token)
        if !omitAddRow { rows.insert(row(route)) }
        afterAdd?()
        return .acknowledged(token)
    }
    func remove(_ token: UInt64) -> ExternalRemoveResult {
        removes.append(token)
        guard !removeRefused, live.contains(token), let route = receipts[token] else { return .refused }
        live.remove(token)
        if !removeRetainsRow { rows.remove(row(route)) }
        return .acknowledged
    }
}
private final class Journal: ExternalLeaseJournaling {
    var began = 0; var finished = 0; var events: [String] = []
    var beginFails = false; var recordFailsAt: Int?; var finishFails = false
    func begin(session: UUID, routes: [ExternalLeaseRoute]) throws {
        began += 1
        if beginFails { throw ExternalLeaseFailure.journalFailed }
    }
    func record(_ event: String, index: Int) throws {
        events.append("\(index):\(event)")
        if recordFailsAt == events.count { throw ExternalLeaseFailure.journalFailed }
    }
    func finish() throws {
        finished += 1
        if finishFails { throw ExternalLeaseFailure.journalFailed }
    }
}
private func session(_ p: ExternalLeasePlan, _ driver: Driver, _ journal: Journal, _ clock: Clock = Clock()) -> ExternalLeaseTransaction {
    .init(plan: p, driver: driver, journal: journal, now: { clock.now }, uptime: { 101 }, cancelled: { clock.cancelled })
}

final class ExternalLeaseTests: XCTestCase {
    func testRequiresSeparateConsentAndDoesNotUpgradePreview() throws {
        let p = try plan(), d = try Driver(), j = Journal(); let t = session(p, d, j)
        XCTAssertFalse(p.preview.canApply); t.start(consent: false)
        XCTAssertEqual(t.failure, .consentRequired); XCTAssertEqual(d.adds.count, 0); XCTAssertEqual(j.began, 0)
        t.start(consent: true); XCTAssertTrue(d.adds.isEmpty)
    }
    func testActualPlannerAndFiniteExecutionBudget() throws {
        for input in ["198.51.100.0/23", "0.0.0.0/0", "192.0.2.4", "10.8.0.53", "example.invalid", "::1"] {
            XCTAssertThrowsError(try plan(input))
        }
        XCTAssertThrowsError(try plan((0..<9).map { "198.51.100.\($0 * 4 + 1)" }.joined(separator: "\n")))
        XCTAssertEqual(try plan("198.51.100.0/24").additions.count, 1)
    }
    func testStaleReviewClockAndCancellationPreventWrites() throws {
        for time in [9.0, 40.0, Double.nan, Double.infinity] {
            let c = Clock(); c.now = time
            let d = try Driver(), j = Journal(); let t = session(try plan(), d, j, c)
            t.start(consent: true); XCTAssertTrue(d.adds.isEmpty); XCTAssertEqual(t.failure, .expired)
        }
        let c = Clock(); c.cancelled = true
        let d = try Driver(), j = Journal(); let t = session(try plan(), d, j, c)
        t.start(consent: true); XCTAssertTrue(d.adds.isEmpty); XCTAssertEqual(t.failure, .cancelled)
    }
    func testFreshObservationIDDoesNotInvalidateEquivalentSnapshot() throws {
        let d = try Driver(), j = Journal(); let t = session(try plan(), d, j)
        t.start(consent: true); XCTAssertEqual(t.state, .active)
        XCTAssertEqual(j.events, ["0:willAdd", "0:addAcknowledged", "0:addReadback"])
        t.stop(); XCTAssertEqual(t.state, .closed); XCTAssertEqual(t.postObservation, .unchanged)
        XCTAssertEqual(j.finished, 1); XCTAssertEqual(d.removes, [1])
    }
    func testChangedNetworkBeforeStartRejectsWithoutJournalOrWrite() throws {
        let d = try Driver(), j = Journal(); d.dns = "10.8.0.54"
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertEqual(t.failure, .networkChanged); XCTAssertTrue(d.adds.isEmpty); XCTAssertEqual(j.began, 0)
        XCTAssertEqual(t.snapshotChangeSummary,
                       "interfaces_changed=false physical_paths_changed=false dns_changed=true routes_added=0 routes_removed=0")
    }
    func testUnrelatedRouteChangeIsStillRejectedWithCountOnlyDiagnostic() throws {
        let d = try Driver(), j = Journal()
        d.rows.insert(ExternalRoute(destination: try IPv4CIDR("203.0.113.0/24"),
                                    gateway: "10.8.0.1", interface: "utun42", flags: "UGSc"))
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertEqual(t.failure, .networkChanged)
        XCTAssertTrue(d.adds.isEmpty); XCTAssertEqual(j.began, 0)
        XCTAssertEqual(t.snapshotChangeSummary,
                       "interfaces_changed=false physical_paths_changed=false dns_changed=false routes_added=1 routes_removed=0")
        XCTAssertFalse(t.snapshotChangeSummary!.contains("203.0.113"))
    }
    func testExistingDirectRoutesAreNeverClaimedOrDeleted() throws {
        let single = try plan().additions[0]
        let baseline = try snapshot(rows: snapshot().routes.union([row(single)]))
        let d = try Driver(baseline), j = Journal()
        let t = session(try plan("198.51.100.4\n203.0.113.4", baseline: baseline), d, j)
        t.start(consent: true); XCTAssertEqual(t.state, .active); XCTAssertEqual(d.adds.count, 1)
        t.stop(); XCTAssertTrue(d.rows.contains(row(single))); XCTAssertEqual(d.removes, [1])
    }
    func testOnlyBorrowedRowsCreateNoLeaseOrJournal() throws {
        let p = try plan(), baseline = try snapshot(rows: snapshot().routes.union([row(p.additions[0])]))
        let d = try Driver(baseline), j = Journal(); let t = session(try plan(baseline: baseline), d, j)
        t.start(consent: true); XCTAssertEqual(t.state, .closed); XCTAssertTrue(d.adds.isEmpty); XCTAssertEqual(j.began, 0)
    }
    func testPartialAddFailureRollsBackOnlyPriorSuccessfulRows() throws {
        let d = try Driver(), j = Journal(); d.rejectAt = 2
        let t = session(try plan("198.51.100.4\n203.0.113.4"), d, j)
        t.start(consent: true)
        XCTAssertEqual(t.state, .closed); XCTAssertEqual(t.failure, .routeRejected); XCTAssertEqual(d.removes, [1])
        XCTAssertTrue(d.rows.contains(row(d.adds[1]))); XCTAssertEqual(j.finished, 1)
    }
    func testUnknownAddCannotBeAdoptedFromIdenticalReadback() throws {
        let d = try Driver(), j = Journal(); d.unknownAt = 1; d.unknownCreates = true
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertEqual(t.state, .recoveryRequired); XCTAssertEqual(t.failure, .routeUncertain)
        XCTAssertTrue(d.removes.isEmpty); XCTAssertEqual(j.finished, 0)
    }
    func testUnknownSecondWriteStillDrainsKnownPriorReceipt() throws {
        let d = try Driver(), j = Journal(); d.unknownAt = 2
        let t = session(try plan("198.51.100.4\n203.0.113.4"), d, j); t.start(consent: true)
        XCTAssertEqual(d.removes, [1]); XCTAssertEqual(t.state, .recoveryRequired); XCTAssertEqual(j.finished, 0)
    }
    func testAddAckWithoutReadbackIsNotActive() throws {
        let d = try Driver(), j = Journal(); d.omitAddRow = true
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertEqual(t.failure, .readbackFailed); XCTAssertEqual(t.state, .closed)
        XCTAssertTrue(d.removes.isEmpty) // Already absent; never delete the covering VPN route.
    }
    func testDNSChangeDuringAddRollsBackAndReportsChangedSnapshot() throws {
        let d = try Driver(), j = Journal(); d.afterAdd = { d.dns = "10.8.0.54" }
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertEqual(t.state, .closed); XCTAssertEqual(t.failure, .networkChanged)
        XCTAssertEqual(d.removes, [1]); XCTAssertEqual(t.postObservation, .changed)
    }
    func testIdleLeaseExpirationAndRepeatedStop() throws {
        let c = Clock(), d = try Driver(), j = Journal(); let t = session(try plan(), d, j, c)
        t.start(consent: true); c.now = 71; t.poll(); t.stop(); t.poll(); t.start(consent: true)
        XCTAssertEqual(t.state, .closed); XCTAssertEqual(t.failure, .expired)
        XCTAssertEqual(d.adds.count, 1); XCTAssertEqual(d.removes, [1])
    }
    func testCancellationImmediatelyAfterAcknowledgedAddRollsBack() throws {
        let c = Clock(), d = try Driver(), j = Journal(); d.afterAdd = { c.cancelled = true }
        let t = session(try plan(), d, j, c); t.start(consent: true)
        XCTAssertEqual(t.state, .closed); XCTAssertEqual(t.failure, .cancelled); XCTAssertEqual(d.removes, [1])
    }
    func testSameFieldReplacementRevokesOwnershipPermanently() throws {
        let d = try Driver(), j = Journal(); let t = session(try plan(), d, j)
        t.start(consent: true); d.live.remove(1); t.poll(); t.stop()
        XCTAssertEqual(t.state, .recoveryRequired); XCTAssertTrue(d.removes.isEmpty); XCTAssertEqual(j.finished, 0)
    }
    func testEventGapNeverAuthorizesDelete() throws {
        let d = try Driver(), j = Journal(); let t = session(try plan(), d, j)
        t.start(consent: true); d.eventFailure = true; t.poll()
        XCTAssertEqual(t.state, .recoveryRequired); XCTAssertTrue(d.removes.isEmpty)
    }
    func testForeignDifferentGatewayIsRetained() throws {
        let p = try plan(), d = try Driver(), j = Journal(); let t = session(p, d, j)
        t.start(consent: true); d.rows.remove(row(p.additions[0]))
        d.rows.insert(.init(destination: p.additions[0].destination, gateway: "192.0.2.254", interface: "en7", flags: "UGHS2"))
        t.stop(); XCTAssertEqual(t.state, .recoveryRequired); XCTAssertTrue(d.removes.isEmpty)
    }
    func testScopedSameKeyPreventsCleanupDeletion() throws {
        let p = try plan(), d = try Driver(), j = Journal(); let t = session(p, d, j)
        t.start(consent: true)
        d.rows.insert(.init(destination: p.additions[0].destination, gateway: "192.0.2.1", interface: "en7", flags: "UGHSI"))
        t.stop(); XCTAssertEqual(t.state, .recoveryRequired); XCTAssertTrue(d.removes.isEmpty)
    }
    func testExternalAbsenceDoesNotRequireReclaimedReceipt() throws {
        let p = try plan(), d = try Driver(), j = Journal(); let t = session(p, d, j)
        t.start(consent: true); d.rows.remove(row(p.additions[0])); d.live.remove(1)
        t.stop(); XCTAssertEqual(t.state, .closed); XCTAssertTrue(d.removes.isEmpty); XCTAssertEqual(j.finished, 1)
    }
    func testDeleteRefusalAndFalseReadbackStayUnconfirmed() throws {
        for retain in [false, true] {
            let d = try Driver(), j = Journal(); d.removeRefused = !retain; d.removeRetainsRow = retain
            let t = session(try plan(), d, j); t.start(consent: true); t.stop(); t.stop()
            XCTAssertEqual(t.state, .recoveryRequired); XCTAssertEqual(d.removes, [1]); XCTAssertEqual(j.finished, 0)
        }
    }
    func testCleanupReadFailureRetainsJournalAndReceipt() throws {
        let d = try Driver(), j = Journal(); let t = session(try plan(), d, j)
        t.start(consent: true); d.observationFailure = true; t.stop()
        XCTAssertEqual(t.state, .recoveryRequired); XCTAssertEqual(t.postObservation, .notObserved); XCTAssertEqual(j.finished, 0)
    }
    func testStopDeletesInReverseAcknowledgedOrder() throws {
        let d = try Driver(), j = Journal(); let t = session(try plan("198.51.100.4\n203.0.113.4"), d, j)
        t.start(consent: true); t.stop(); XCTAssertEqual(d.removes, [2, 1]); XCTAssertEqual(t.state, .closed)
    }
    func testJournalBeginFailurePreventsAllRouteWrites() throws {
        let d = try Driver(), j = Journal(); j.beginFails = true
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertTrue(d.adds.isEmpty); XCTAssertEqual(t.state, .recoveryRequired)
    }
    func testJournalFailureAfterAckKeepsRecoveryMarker() throws {
        let d = try Driver(), j = Journal(); j.recordFailsAt = 2
        let t = session(try plan(), d, j); t.start(consent: true)
        XCTAssertEqual(d.removes, [1]); XCTAssertEqual(t.state, .recoveryRequired); XCTAssertEqual(j.finished, 0)
    }
    func testJournalFinishFailureDoesNotClaimCleanTermination() throws {
        let d = try Driver(), j = Journal(); j.finishFails = true
        let t = session(try plan(), d, j); t.start(consent: true); t.stop()
        XCTAssertEqual(t.state, .recoveryRequired); XCTAssertEqual(t.failure, .journalFailed)
    }
    func testRedactedPlanHasNoAutomaticNetworkValues() throws {
        let p = try plan(); XCTAssertFalse(String(reflecting: p).contains("198.51"))
        XCTAssertTrue(Mirror(reflecting: p).children.isEmpty)
    }
}

final class ExternalLeaseJournalTests: XCTestCase {
    private func temporary(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("external-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) } // This test's synthetic directory ONLY.
        try body(directory.appendingPathComponent("journal"))
    }
    func testWriteAheadAndCleanClose() throws {
        try temporary { dir in
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid())
            try j.begin(session: UUID(), routes: plan().additions); try j.record("willAdd", index: 0)
            let file = dir.appendingPathComponent("active")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)); try j.finish()
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("lease.lock").path))
        }
    }
    func testAbsentMarkerAuditsAsZeroWithoutGrantingClearAuthority() throws {
        try temporary { dir in
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid())
            XCTAssertEqual(try j.auditCandidates(), [])
            XCTAssertThrowsError(try j.clearAuditedAbsence(routes: [], observation: snapshot(), uptime: 101))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("active").path))
        }
    }
    func testConcurrentWriterRejectedWithoutDeletingLock() throws {
        try temporary { dir in
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid())
            try withExtendedLifetime(j) { XCTAssertThrowsError(try ExternalLeaseFileJournal(directory: dir, owner: getuid())) }
        }
    }
    func testAbandonedIntentBlocksWritesAndIsOnlyAudited() throws {
        try temporary { dir in
            let routes = try plan().additions
            do { let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); try j.begin(session: UUID(), routes: routes) }
            do {
                let next = try ExternalLeaseFileJournal(directory: dir, owner: getuid())
                XCTAssertThrowsError(try next.begin(session: UUID(), routes: routes))
                XCTAssertEqual(try next.auditCandidates(), routes)
                let present = try snapshot(rows: snapshot().routes.union([row(routes[0])]))
                XCTAssertThrowsError(try next.clearAuditedAbsence(routes: routes, observation: present, uptime: 101))
                try next.clearAuditedAbsence(routes: routes, observation: snapshot(), uptime: 101)
            }
        }
    }
    func testAuditCannotSubstituteOtherCandidates() throws {
        try temporary { dir in
            let routes = try plan().additions
            do { let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); try j.begin(session: UUID(), routes: routes) }
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); _ = try j.auditCandidates()
            XCTAssertThrowsError(try j.clearAuditedAbsence(routes: plan("203.0.113.4").additions, observation: snapshot(), uptime: 101))
        }
    }
    func testMoreSpecificOrScopedResidueBlocksMarkerClear() throws {
        try temporary { dir in
            let routes = try plan("198.51.100.0/24").additions
            do { let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); try j.begin(session: UUID(), routes: routes) }
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); _ = try j.auditCandidates()
            let extra = try ExternalRoute(destination: IPv4CIDR("198.51.100.5/32"), gateway: "192.0.2.1", interface: "en7", flags: "UGHSI")
            let observed = try snapshot(rows: snapshot().routes.union([extra]))
            XCTAssertThrowsError(try j.clearAuditedAbsence(routes: routes, observation: observed, uptime: 101))
        }
    }
    func testSymlinkDirectoryAndWidePermissionsRejected() throws {
        try temporary { dir in
            let other = dir.deletingLastPathComponent().appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            XCTAssertEqual(symlink(other.path, dir.path), 0)
            XCTAssertThrowsError(try ExternalLeaseFileJournal(directory: dir, owner: getuid()))
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
            XCTAssertEqual(chmod(dir.path, 0o755), 0)
            XCTAssertThrowsError(try ExternalLeaseFileJournal(directory: dir, owner: getuid()))
        }
    }
    func testExistingMarkerCannotBeOverwrittenOrSymlinkRead() throws {
        try temporary { dir in
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid())
            let outside = dir.deletingLastPathComponent().appendingPathComponent("untouched")
            try Data("sentinel".utf8).write(to: outside)
            XCTAssertEqual(symlink(outside.path, dir.appendingPathComponent("active").path), 0)
            XCTAssertThrowsError(try j.begin(session: UUID(), routes: plan().additions))
            XCTAssertThrowsError(try j.auditCandidates())
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "sentinel")
        }
    }
    func testMalformedOrOversizedMarkerIsNotAdopted() throws {
        for contents in [Data("{}\n".utf8), Data(repeating: 65, count: 16385)] {
            try temporary { dir in
                do { let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); try j.begin(session: UUID(), routes: plan().additions) }
                let file = dir.appendingPathComponent("active"); try contents.write(to: file)
                XCTAssertEqual(chmod(file.path, 0o600), 0)
                let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); XCTAssertThrowsError(try j.auditCandidates())
            }
        }
    }
    func testMarkerNameReplacementIsNotUnlinked() throws {
        try temporary { dir in
            let j = try ExternalLeaseFileJournal(directory: dir, owner: getuid()); try j.begin(session: UUID(), routes: plan().additions)
            let file = dir.appendingPathComponent("active")
            try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("previous"))
            try Data("foreign".utf8).write(to: file); XCTAssertEqual(chmod(file.path, 0o600), 0)
            XCTAssertThrowsError(try j.finish()); XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "foreign")
        }
    }
}
