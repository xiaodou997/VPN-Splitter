// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PolicyCore
@testable import ExternalCore

final class ExternalTests: XCTestCase {
    private let header = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"
    private let base = """
    default 192.168.50.1 UGScg en7
    0/1 10.20.0.1 UGSc utun42
    128.0/1 10.20.0.1 UGSc utun42
    192.168.50 link#7 UCS en7
    192.168.50.1 aa:bb:cc:dd:ee:ff UHLWIir en7 1200
    127 127.0.0.1 UCS lo0
    """
    private func routes(_ text: String? = nil) throws -> Set<ExternalRoute> { try ExternalRouteTable.parse(Data((header + (text ?? base) + "\n").utf8)) }
    private func path(_ name: String = "en7", service: String = "physical-service") throws -> ExternalPhysicalPath {
        try .init(service: service, interface: name, gateway: IPv4Address("192.168.50.1"), networks: [IPv4CIDR("192.168.50.0/24")])
    }
    private func snapshot(_ text: String? = nil, paths: [ExternalPhysicalPath]? = nil,
                          extra: [ExternalInterface] = [], dns: [IPv4Address] = []) throws -> ExternalObservation {
        try .init(capturedAtUptime: 100, interfaces: [
            .init(name: "en7", isUp: true, isTunnelCandidate: false, addresses: [IPv4Address("192.168.50.9")]),
            .init(name: "utun42", isUp: true, isTunnelCandidate: true, addresses: [IPv4Address("10.20.0.2")]),
            .init(name: "lo0", isUp: true, isTunnelCandidate: false, addresses: [IPv4Address("127.0.0.1")])
        ] + extra, physicalPaths: paths ?? [path()], routes: routes(text), observedDNSServers: dns)
    }
    private func preview(_ text: String = "203.0.113.7", snapshot: ExternalObservation? = nil, now: TimeInterval = 101) throws -> ExternalPreview {
        try ExternalPlanner.preview(text, observation: snapshot ?? self.snapshot(), now: now)
    }
    private func rejects(_ error: ExternalError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? ExternalError, error, file: file, line: line) }
    }
    func testSplitDefaultAndPhysicalGatewayNotVPNDefault() throws {
        let result = try preview()
        XCTAssertEqual(result.topology.pattern, .splitDefault)
        XCTAssertEqual(result.topology.tunnelInterface, "utun42")
        XCTAssertEqual(result.proposals[0].gateway.description, "192.168.50.1")
        XCTAssertEqual(result.proposals[0].interface, "en7")
        XCTAssertEqual(result.proposals[0].destination.description, "203.0.113.7/32")
        XCTAssertEqual(result.proposals[0].disposition, .wouldAdd)
        XCTAssertFalse(result.canApply)
    }
    func testDefaultReplacement() throws {
        let source = base.split(separator: "\n").filter { !$0.hasPrefix("0/1 ") && !$0.hasPrefix("128.0/1 ") }
            .joined(separator: "\n").replacingOccurrences(of: "default 192.168.50.1 UGScg en7", with: "default 10.20.0.1 UGSc utun42")
        XCTAssertEqual(try preview(snapshot: snapshot(source)).topology.pattern, .replacedDefault)
    }
    func testDisconnectedPhysicalDefaultDoesNotBecomeVPN() throws {
        rejects(.tunnelUnknown) { _ = try preview(snapshot: snapshot("default 192.168.50.1 UGScg en7\n192.168.50 link#7 UCS en7")) }
    }
    func testIncompleteHalfDefaultRefused() throws {
        rejects(.unsupportedTopology) { _ = try preview(snapshot: snapshot(base.replacingOccurrences(of: "128.0/1 10.20.0.1 UGSc utun42\n", with: ""))) }
    }
    func testConflictingHalfRouteRefused() throws {
        rejects(.unsupportedTopology) { _ = try preview(snapshot: snapshot(base + "\n128.0/1 192.168.50.1 UGSc en7")) }
    }
    func testHalfGatewaysMustAgree() throws {
        rejects(.unsupportedTopology) { _ = try preview(snapshot: snapshot(base.replacingOccurrences(of: "128.0/1 10.20.0.1", with: "128.0/1 10.21.0.1"))) }
    }
    func testMultipleTunnelCandidatesRefused() throws {
        let extra = try ExternalInterface(name: "utun99", isUp: true, isTunnelCandidate: true, addresses: [IPv4Address("10.30.0.2")])
        rejects(.tunnelAmbiguous) { _ = try preview(snapshot: snapshot(base + "\n10.30/16 10.30.0.1 UGSc utun99", extra: [extra])) }
    }
    func testMultiplePhysicalPathsNotAutomaticallySelected() throws {
        rejects(.physicalAmbiguous) { _ = try preview(snapshot: snapshot(paths: [path(), path(service: "other-service")])) }
    }
    func testMissingServiceNoSavedGatewayFallback() throws {
        rejects(.physicalUnknown) { _ = try preview(snapshot: snapshot(paths: [])) }
    }
    func testGatewayMustBeOnObservedLocalNetwork() throws {
        let candidate = try ExternalPhysicalPath(service: "s", interface: "en7", gateway: IPv4Address("198.51.100.1"), networks: [IPv4CIDR("192.168.50.0/24")])
        rejects(.physicalUnknown) { _ = try preview(snapshot: snapshot(paths: [candidate])) }
    }
    func testMissingLinkRouteCannotConfirmPhysicalCandidate() throws {
        rejects(.physicalUnknown) { _ = try preview(snapshot: snapshot(base.replacingOccurrences(of: "192.168.50 link#7 UCS en7\n", with: ""))) }
    }
    func testDNSAndLocalAndReservedRangesProtected() throws {
        let observed = try snapshot(dns: [IPv4Address("198.51.100.53")])
        for target in ["198.51.100.0/24", "192.168.50.0/24", "10.20.0.2", "0.0.0.0/0", "127.0.0.7", "224.0.0.0/4", "169.254.2.3"] {
            rejects(.protectedRange) { _ = try preview(target, snapshot: observed) }
        }
    }
    func testExistingVPNHostRouteIsConflict() throws {
        rejects(.existingRouteConflict) { _ = try preview(snapshot: snapshot(base + "\n203.0.113.7 10.20.0.1 UGHS utun42")) }
    }
    func testMoreSpecificVPNRouteDoesNotDisappearInCIDR() throws {
        rejects(.existingRouteConflict) { _ = try preview("203.0.113.0/24", snapshot: snapshot(base + "\n203.0.113.7 10.20.0.1 UGHS utun42")) }
    }
    func testExistingPhysicalHostRouteIsNotOwned() throws {
        let result = try preview(snapshot: snapshot(base + "\n203.0.113.7 192.168.50.1 UGHS en7"))
        XCTAssertEqual(result.proposals[0].disposition, .alreadyDirectNoOwnership)
        XCTAssertFalse(result.canApply)
    }
    func testScopedAndClonedEntriesRemainBlocking() throws {
        rejects(.scopedRouteConflict) { _ = try preview(snapshot: snapshot(base + "\n203.0.113.7 192.168.50.1 UGHWI en7")) }
        rejects(.existingRouteConflict) { _ = try preview(snapshot: snapshot(base + "\n203.0.113.7 192.168.50.1 UGHW en7")) }
    }
    func testBroaderPhysicalExceptionNotMisreportedVPN() throws {
        rejects(.existingRouteConflict) { _ = try preview(snapshot: snapshot(base + "\n203.0.113/24 192.168.50.1 UGSc en7")) }
    }
    func testBlackholeNotOverridden() throws {
        rejects(.existingRouteConflict) { _ = try preview(snapshot: snapshot(base + "\n203.0.113/24 10.20.0.1 UGB utun42")) }
    }
    func testWholeBatchRejectedNotPartialSuccess() throws {
        rejects(.protectedRange) { _ = try preview("203.0.113.7\n127.0.0.1") }
    }
    func testPolicyCorePreservesShadowingAndNormalizesCIDRs() throws {
        let result = try preview("203.0.113.9/24\n203.0.113.7\n203.0.113.0/24")
        XCTAssertEqual(result.proposals.map { $0.destination.description }, ["203.0.113.0/24"])
        XCTAssertEqual(result.ruleEvaluations.map(\.effect), [.effective, .fullyShadowed, .fullyShadowed])
    }
    func testRuleLimitsAndUnknownSelectors() throws {
        for text in ["", "example.invalid", "::1", "-n", "203.0.113.7;echo", "01.2.3.4", Array(repeating: "203.0.113.7", count: 65).joined(separator: "\n")] {
            rejects(.invalidRules) { _ = try preview(text) }
        }
        rejects(.limitExceeded) { _ = try preview(String(repeating: " ", count: 16_385)) }
    }
    func testFreshnessAndClockReversal() throws {
        for time in [99.0, 130, .infinity, .nan] { rejects(.expired) { _ = try preview(now: time) } }
        XCTAssertNoThrow(try preview(now: 129.99))
    }
    func testRedactedObservationAndPreview() throws {
        let observation = try snapshot(); let result = try preview(snapshot: observation)
        for rendered in [String(describing: observation), String(reflecting: observation), String(describing: result), String(reflecting: result)] {
            XCTAssertFalse(rendered.contains("192.168")); XCTAssertFalse(rendered.contains("utun42"))
        }
        XCTAssertEqual(Mirror(reflecting: observation).children.count, 0)
        XCTAssertEqual(Mirror(reflecting: result).children.count, 0)
    }
    func testParserRetainsScopeFlagsAndAbbreviations() throws {
        let records = try routes()
        XCTAssertTrue(records.contains { $0.destination.description == "0.0.0.0/1" })
        XCTAssertTrue(records.contains { $0.destination.description == "128.0.0.0/1" })
        XCTAssertTrue(records.contains { $0.destination.description == "192.168.50.0/24" })
        XCTAssertTrue(records.contains { $0.scoped && $0.flags.contains("W") })
    }
    func testParserOlderCounterColumnsAndExpiryDoNotChangeIdentity() throws {
        let old = "Routing tables\nInternet:\nDestination Gateway Flags Refs Use Netif Expire\n203.0.113.7 192.168.50.1 UGHS 2 304 en7 10\n"
        let expected = try routes("203.0.113.7 192.168.50.1 UGHS en7 999")
        XCTAssertEqual(try ExternalRouteTable.parse(Data(old.utf8)), expected)
    }
    func testParserUnknownRowsFlagsGatewayAndHeadersFailClosed() throws {
        for row in ["203.0.113.7 evil.invalid UGHS en7", "0/1 10.20.0.1 UG? utun42", "198.51.100.7/24 10.20.0.1 UGS utun42", "garbage", "Internet6:"] {
            rejects(.malformedRoutes) { _ = try routes(base + "\n" + row) }
        }
        rejects(.malformedRoutes) { _ = try ExternalRouteTable.parse(Data("Destination Gateway Flags Netif Expire\ndefault 192.168.50.1 UG en7\n".utf8)) }
        rejects(.malformedRoutes) { _ = try ExternalRouteTable.parse(Data("Routing tables\nInternet:\nDestination Gateway Flags Netif Expire\n".utf8)) }
    }
    func testParserLimitsAndInvalidEncoding() throws {
        rejects(.limitExceeded) { _ = try ExternalRouteTable.parse(Data(repeating: 65, count: ExternalRouteTable.maximumBytes + 1)) }
        rejects(.malformedRoutes) { _ = try ExternalRouteTable.parse(Data([255, 254])) }
        rejects(.limitExceeded) { _ = try routes(Array(repeating: "203.0.113.7 192.168.50.1 UGHS en7", count: 8193).joined(separator: "\n")) }
    }
    func testClassfulOmissionIsNotGuessedFromOctetCount() throws {
        XCTAssertTrue(try routes("172.16 link#7 UCS en7").contains { $0.destination.description == "172.16.0.0/16" })
        rejects(.malformedRoutes) { _ = try routes("198.51 link#7 UCS en7") }
        rejects(.malformedRoutes) { _ = try routes("10.1 link#7 UCS en7") }
        XCTAssertTrue(try routes("10.1/16 link#7 UCS en7").contains { $0.destination.description == "10.1.0.0/16" })
    }
    func testBroadcastGatewayNotAUsablePhysicalPath() throws {
        let candidate = try ExternalPhysicalPath(service: "s", interface: "en7", gateway: IPv4Address("192.168.50.255"), networks: [IPv4CIDR("192.168.50.0/24")])
        rejects(.physicalUnknown) { _ = try preview(snapshot: snapshot(paths: [candidate])) }
    }

}
