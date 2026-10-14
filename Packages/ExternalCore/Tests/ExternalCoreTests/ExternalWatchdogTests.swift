// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import PolicyCore
@testable import ExternalCore

final class ExternalWatchdogTests: XCTestCase {
    private let header = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"
    private let base = """
    default 192.168.50.1 UGScg en7
    0/1 10.20.0.1 UGSc utun42
    128.0/1 10.20.0.1 UGSc utun42
    192.168.50 link#7 UCS en7
    192.168.50.1 aa:bb:cc:dd:ee:ff UHLWIir en7 1200
    127 127.0.0.1 UCS lo0
    """
    private func routes(_ text: String) throws -> Set<ExternalRoute> { try ExternalRouteTable.parse(Data((header + text + "\n").utf8)) }
    private func path(_ interface: String = "en7", gateway: String = "192.168.50.1") throws -> ExternalPhysicalPath {
        try .init(service: "physical-service", interface: interface, gateway: IPv4Address(gateway), networks: [IPv4CIDR("192.168.50.0/24")])
    }
    private func snapshot(_ text: String? = nil, paths: [ExternalPhysicalPath]? = nil,
                          tunnelName: String = "utun42", uptime: TimeInterval = 100) throws -> ExternalObservation {
        try .init(capturedAtUptime: uptime, interfaces: [
            .init(name: "en7", isUp: true, isTunnelCandidate: false, addresses: [IPv4Address("192.168.50.9")]),
            .init(name: tunnelName, isUp: true, isTunnelCandidate: true, addresses: [IPv4Address("10.20.0.2")]),
            .init(name: "lo0", isUp: true, isTunnelCandidate: false, addresses: [IPv4Address("127.0.0.1")])
        ], physicalPaths: paths ?? [path()], routes: routes(text ?? base), observedDNSServers: [])
    }
    /// Routes with the tunnel gone but the physical service intact.
    private var disconnectedRoutes: String {
        base.split(separator: "\n").filter { !$0.hasPrefix("0/1 ") && !$0.hasPrefix("128.0/1 ") }.joined(separator: "\n")
    }
    /// Replaced-default form on the same tunnel.
    private var replacedDefaultRoutes: String {
        disconnectedRoutes.replacingOccurrences(of: "default 192.168.50.1 UGScg en7", with: "default 10.20.0.1 UGSc utun42")
    }

    func testClassifyOnlineTopology() throws {
        let health = ExternalWatchdogTracker.classify(try snapshot())
        XCTAssertEqual(health, .online(.init(physicalInterface: "en7", physicalGateway: try IPv4Address("192.168.50.1"),
                                             tunnelInterface: "utun42", pattern: .splitDefault)))
    }
    func testInitialAndSteadyTransitions() throws {
        var tracker = ExternalWatchdogTracker()
        XCTAssertEqual(tracker.ingest(try snapshot()), .initialOnline)
        XCTAssertNil(tracker.ingest(try snapshot(uptime: 103)))
        XCTAssertEqual(tracker.health, .online(.init(physicalInterface: "en7", physicalGateway: try IPv4Address("192.168.50.1"),
                                                     tunnelInterface: "utun42", pattern: .splitDefault)))
    }
    func testInitialUnavailable() throws {
        var tracker = ExternalWatchdogTracker()
        XCTAssertEqual(tracker.ingest(try snapshot(disconnectedRoutes)), .initialUnavailable)
        XCTAssertEqual(tracker.health, .unavailable(.tunnelUnknown))
    }
    func testDisconnectAndReconnectSameTopology() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        XCTAssertEqual(tracker.ingest(try snapshot(disconnectedRoutes, uptime: 103)), .vpnDisconnected)
        XCTAssertNil(tracker.ingest(try snapshot(disconnectedRoutes, uptime: 106)))
        XCTAssertEqual(tracker.ingest(try snapshot(uptime: 109)), .vpnReconnected)
        XCTAssertEqual(tracker.lastOnline?.tunnelInterface, "utun42")
    }
    func testReconnectOnNewTunnelInterface() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        _ = tracker.ingest(try snapshot(disconnectedRoutes, uptime: 103))
        let renamed = base.replacingOccurrences(of: "utun42", with: "utun43")
        XCTAssertEqual(tracker.ingest(try snapshot(renamed, tunnelName: "utun43", uptime: 106)), .vpnReconnected)
        XCTAssertEqual(tracker.lastOnline?.tunnelInterface, "utun43")
    }
    func testTunnelInterfaceChangedWhileOnline() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        let renamed = base.replacingOccurrences(of: "utun42", with: "utun43")
        XCTAssertEqual(tracker.ingest(try snapshot(renamed, tunnelName: "utun43", uptime: 103)), .tunnelInterfaceChanged)
    }
    func testPhysicalPathChangedWhileOnline() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        let moved = base.replacingOccurrences(of: "192.168.50.1", with: "192.168.50.254")
        XCTAssertEqual(tracker.ingest(try snapshot(moved, paths: [path(gateway: "192.168.50.254")], uptime: 103)),
                       .physicalPathChanged)
    }
    func testRoutingPatternChangedWhileOnline() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        XCTAssertEqual(tracker.ingest(try snapshot(replacedDefaultRoutes, uptime: 103)), .routingPatternChanged)
    }
    func testPhysicalPathLost() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        XCTAssertEqual(tracker.ingest(try snapshot(paths: [], uptime: 103)), .physicalPathLost)
        XCTAssertEqual(tracker.health, .unavailable(.physicalUnknown))
    }
    func testObservationFailureIsNotReportedAsVPNDisconnect() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        XCTAssertEqual(tracker.ingestFailure(.readFailed), .observationFailed)
        XCTAssertEqual(tracker.ingestFailure(.changedDuringRead), nil)
        XCTAssertEqual(tracker.ingest(try snapshot(uptime: 103)), .vpnReconnected)
    }
    func testTopologyBecameUnsupported() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot())
        let brokenHalf = base.replacingOccurrences(of: "128.0/1 10.20.0.1 UGSc utun42\n", with: "")
        XCTAssertEqual(tracker.ingest(try snapshot(brokenHalf, uptime: 103)), .topologyBecameUnsupported)
    }
    func testUnavailableCauseChangeStaysQuiet() throws {
        var tracker = ExternalWatchdogTracker()
        _ = tracker.ingest(try snapshot(disconnectedRoutes))
        XCTAssertNil(tracker.ingest(try snapshot(paths: [], uptime: 103)))
        XCTAssertNil(tracker.ingestFailure(.readFailed))
    }
}
