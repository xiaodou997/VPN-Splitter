// SPDX-License-Identifier: MIT
import XCTest
import PolicyCore
import ExternalCore
import ExternalFlowWire
@testable import ExternalFlowCore

final class ExternalFlowCoreTests: XCTestCase {
    func testFirstMatchAcrossApplicationDomainAndIP() throws {
        let app = ExternalSavedRule(kind: .application, target: "Chrome")
        let domain = ExternalSavedRule(kind: .domainSuffix, target: "example.com")
        let ip = ExternalSavedRule(kind: .ipCIDR, target: "198.51.100.0/24")
        let profile = ExternalSavedProfile(name: "flow", rules: [app, domain, ip])
        let policy = try ExternalFlowPolicy(profile: profile,
            applicationBindings: [.init(ruleID: app.id, signingIdentifier: "com.google.Chrome")])
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: "com.google.Chrome",
                                             remoteHostname: "other.test",
                                             destinationIPv4: try IPv4Address("198.51.100.7"))),
                       .direct(ruleID: app.id))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: "com.other",
                                             remoteHostname: "a.example.com.",
                                             destinationIPv4: nil)),
                       .direct(ruleID: domain.id))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: nil,
                                             remoteHostname: nil,
                                             destinationIPv4: try IPv4Address("198.51.100.7"))),
                       .direct(ruleID: ip.id))
    }

    func testMissingHostnameDoesNotPretendDomainMatch() throws {
        let domain = ExternalSavedRule(kind: .domainKeyword, target: "google")
        let policy = try ExternalFlowPolicy(profile: .init(name: "x", rules: [domain]))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: nil,
                                             remoteHostname: nil, destinationIPv4: nil)), .systemDefault)
    }

    func testApplicationRequiresStableResolvedIdentity() throws {
        let app = ExternalSavedRule(kind: .application, target: "Telegram")
        XCTAssertThrowsError(try ExternalFlowPolicy(profile: .init(name: "x", rules: [app]))) {
            XCTAssertEqual($0 as? ExternalFlowCompileError, .unresolvedApplication(app.id))
        }
        XCTAssertThrowsError(try ExternalFlowPolicy(profile: .init(name: "x", rules: [app]),
            applicationBindings: [.init(ruleID: app.id, signingIdentifier: "bad id")]))
    }

    func testSavedApplicationIdentityCompilesWithoutExternalBinding() throws {
        let app = ExternalSavedRule(kind: .application, target: "Telegram",
                                    applicationIdentifier: "org.telegram.desktop")
        let policy = try ExternalFlowPolicy(profile: .init(name: "x", rules: [app]))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: "org.telegram.desktop",
                                             remoteHostname: nil, destinationIPv4: nil)),
                       .direct(ruleID: app.id))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: "com.other",
                                             remoteHostname: nil, destinationIPv4: nil)),
                       .systemDefault)
    }

    func testDisabledApplicationDoesNotRequireBinding() throws {
        let app = ExternalSavedRule(kind: .application, target: "Telegram", enabled: false)
        let policy = try ExternalFlowPolicy(profile: .init(name: "x", rules: [app]))
        XCTAssertEqual(policy.evaluate(.init(sourceAppSigningIdentifier: "org.telegram.desktop",
                                             remoteHostname: nil, destinationIPv4: nil)), .systemDefault)
    }

    func testProbeReportContainsCountsOnly() throws {
        var report = ExternalFlowProbeReport()
        report.total = 2; report.tcp = 1; report.udp = 1
        report.withSourceSigningIdentifier = 1; report.withRemoteHostname = 1
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(ExternalFlowProbeReport.schema))
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertTrue(report.appIdentityObservable); XCTAssertTrue(report.hostnameObservable)
    }
}
