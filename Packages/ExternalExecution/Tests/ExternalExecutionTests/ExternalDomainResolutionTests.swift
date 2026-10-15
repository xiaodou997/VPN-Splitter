// SPDX-License-Identifier: MIT
import Foundation
import XCTest
import ExternalCore
import PolicyCore
@testable import ExternalExecution

private func addresses(_ texts: [String]) -> [IPv4Address] { texts.map { try! IPv4Address($0) } }
private func cidrs(_ texts: [String]) -> Set<IPv4CIDR> { Set(texts.map { try! IPv4CIDR($0) }) }

final class ExternalDomainRuleSetTests: XCTestCase {
    func testParsesMixedTextAndNormalizesSuffixApex() throws {
        let parsed = try ExternalDomainRuleSet.parse("198.51.100.4\nDOMAIN,WWW.Example.COM.\nDOMAIN-SUFFIX,*.Example.ORG\n203.0.113.0/24")
        XCTAssertEqual(parsed.staticLines, ["198.51.100.4", "203.0.113.0/24"])
        XCTAssertEqual(parsed.domains, [ExternalDomainRule(name: "www.example.com", suffixApex: false),
                                        ExternalDomainRule(name: "example.org", suffixApex: true)])
    }
    func testRejectsFlowOnlyAndUnknownTypedRulesAsAWhole() throws {
        for text in ["DOMAIN-KEYWORD,google", "APPLICATION,Telegram", "APP,Telegram",
                     "FINAL,example.com", "DOMAIN,", "DOMAIN-SUFFIX,", "DOMAIN,bad_name.com",
                     "DOMAIN,-bad.com", "domain,lower-prefix.com"] {
            XCTAssertThrowsError(try ExternalDomainRuleSet.parse(text)) {
                XCTAssertEqual($0 as? ExternalError, .invalidRules)
            }
        }
    }
    func testDedupesAndCapsDomainCount() throws {
        let repeated = try ExternalDomainRuleSet.parse("DOMAIN,a.com\nDOMAIN-SUFFIX,a.com\nDOMAIN,a.com")
        XCTAssertEqual(repeated.domains, [ExternalDomainRule(name: "a.com", suffixApex: false)])
        let many = (0..<9).map { "DOMAIN,d\($0).example.com" }.joined(separator: "\n")
        XCTAssertThrowsError(try ExternalDomainRuleSet.parse(many)) {
            XCTAssertEqual($0 as? ExternalError, .limitExceeded)
        }
        let eight = (0..<8).map { "DOMAIN,d\($0).example.com" }.joined(separator: "\n")
        XCTAssertEqual(try ExternalDomainRuleSet.parse(eight).domains.count, 8)
    }
}

final class ExternalDomainResolverTests: XCTestCase {
    private let rules = [ExternalDomainRule(name: "example.com", suffixApex: false)]
    func testExpandsToBoundedSortedSlash32Lines() throws {
        let expansion = try ExternalDomainResolver.expand(domains: rules, budget: 8) { _ in
            addresses(["203.0.113.9", "203.0.113.1", "203.0.113.9"])
        }
        XCTAssertEqual(expansion.lines, ["203.0.113.1/32", "203.0.113.9/32"])
        XCTAssertEqual(expansion.sources, ["203.0.113.1/32": "example.com", "203.0.113.9/32": "example.com"])
        XCTAssertEqual(expansion.destinations, cidrs(["203.0.113.1/32", "203.0.113.9/32"]))
        XCTAssertFalse(expansion.truncated)
    }
    func testPerDomainLimitTruncatesAndMarks() throws {
        let expansion = try ExternalDomainResolver.expand(domains: rules, budget: 32) { _ in
            addresses((1...10).map { "203.0.113.\($0)" })
        }
        XCTAssertEqual(expansion.lines.count, 8)
        XCTAssertTrue(expansion.truncated)
    }
    func testFakeIPAndReservedAnswersAreFiltered() throws {
        let expansion = try ExternalDomainResolver.expand(domains: rules, budget: 8) { _ in
            addresses(["198.18.0.7", "198.19.255.7", "127.0.0.1", "0.1.2.3", "169.254.1.1", "224.0.0.5",
                       "240.0.0.1", "203.0.113.5"])
        }
        XCTAssertEqual(expansion.lines, ["203.0.113.5/32"])
        XCTAssertFalse(expansion.truncated)
    }
    func testEmptyAfterFilteringOrResolverErrorRejectsTheWholeSet() throws {
        XCTAssertThrowsError(try ExternalDomainResolver.expand(domains: rules, budget: 8) { _ in
            addresses(["198.18.0.7", "127.0.0.1"])
        }) { XCTAssertEqual($0 as? ExternalError, .domainResolutionFailed) }
        struct Offline: Error {}
        XCTAssertThrowsError(try ExternalDomainResolver.expand(domains: rules, budget: 8) { _ in throw Offline() }) {
            XCTAssertEqual($0 as? ExternalError, .domainResolutionFailed)
        }
    }
    func testTotalBudgetTruncatesDeterministicallyAcrossDomains() throws {
        let domains = (0..<3).map { ExternalDomainRule(name: "d\($0).example.com", suffixApex: false) }
        let distinct: ExternalDomainResolver.Resolve = { name in
            let base = name.hasPrefix("d0") ? 0 : (name.hasPrefix("d1") ? 16 : (name.hasPrefix("d2") ? 32 : (name.hasPrefix("d3") ? 48 : 64)))
            return addresses((1...8).map { "203.0.113.\(base + $0)" })
        }
        let expansion = try ExternalDomainResolver.expand(domains: domains, budget: 32, resolve: distinct)
        XCTAssertEqual(expansion.lines.count, 24) // 3 domains x 8 records, under the 32 total cap
        XCTAssertFalse(expansion.truncated)
        let five = (0..<5).map { ExternalDomainRule(name: "d\($0).example.com", suffixApex: false) }
        let over = try ExternalDomainResolver.expand(domains: five, budget: 32, resolve: distinct)
        XCTAssertEqual(over.lines.count, 32)
        XCTAssertTrue(over.truncated)
    }
    func testStaticBudgetAndDuplicatesNeverExceedTheExecutionLimit() throws {
        let staticLines = (1...7).map { "198.51.100.\($0)/32" }
        let expansion = try ExternalDomainResolver.expand(domains: rules, staticLines: staticLines, budget: 1) { _ in
            addresses(["203.0.113.9", "203.0.113.10"])
        }
        XCTAssertEqual(expansion.lines, ["203.0.113.9/32"])
        XCTAssertTrue(expansion.truncated)
        XCTAssertThrowsError(try ExternalDomainResolver.expand(domains: rules,
            staticLines: staticLines + ["198.51.100.8/32"], budget: 0) { _ in addresses(["203.0.113.9"]) }) {
            XCTAssertEqual($0 as? ExternalError, .limitExceeded)
        }
        let duplicate = try ExternalDomainResolver.expand(domains: rules, staticLines: ["203.0.113.9/32"], budget: 4) { _ in
            addresses(["203.0.113.9"])
        }
        XCTAssertEqual(duplicate.lines, []) // Resolved set exists but overlaps a static rule; no duplicate line.
        XCTAssertEqual(duplicate.destinations, [])
    }
    func testSuffixApexIsAnnotatedInSources() throws {
        let suffix = [ExternalDomainRule(name: "example.org", suffixApex: true)]
        let expansion = try ExternalDomainResolver.expand(domains: suffix, budget: 8) { _ in addresses(["203.0.113.9"]) }
        XCTAssertEqual(expansion.sources["203.0.113.9/32"], "example.org 后缀 apex")
    }
}

final class ExternalDomainRefreshTests: XCTestCase {
    private let a = try! IPv4CIDR("203.0.113.9/32")
    private let b = try! IPv4CIDR("203.0.113.10/32")
    func testRefreshIsDueOnlyAfterSixtySecondsAndOnlyOnce() throws {
        var refresh = ExternalDomainRefresh(applied: [a], startedAt: 100)
        XCTAssertFalse(refresh.due(at: 99))
        XCTAssertFalse(refresh.due(at: 159.9))
        XCTAssertFalse(refresh.due(at: .nan))
        XCTAssertTrue(refresh.due(at: 160))
        XCTAssertTrue(refresh.begin(at: 160))
        XCTAssertFalse(refresh.due(at: 500)) // In flight: never a second concurrent resolution.
        XCTAssertFalse(refresh.begin(at: 500))
    }
    func testSuccessfulRefreshDiffsSortedAdditionsAndRemovals() throws {
        var refresh = ExternalDomainRefresh(applied: [a], startedAt: 100)
        XCTAssertTrue(refresh.begin(at: 160))
        let diff = refresh.finish(at: 165, resolved: [b])
        XCTAssertEqual(diff, ExternalDomainDiff(add: [b], remove: [a]))
        XCTAssertEqual(refresh.applied, [b])
        XCTAssertFalse(refresh.inFlight)
        XCTAssertFalse(refresh.due(at: 224.9))
        XCTAssertTrue(refresh.due(at: 225))
    }
    func testFailedRefreshKeepsTheAppliedSetAndRetriesNextInterval() throws {
        var refresh = ExternalDomainRefresh(applied: [a], startedAt: 100)
        XCTAssertTrue(refresh.begin(at: 160))
        XCTAssertNil(refresh.finish(at: 165, resolved: nil))
        XCTAssertEqual(refresh.applied, [a])
        XCTAssertFalse(refresh.inFlight)
        XCTAssertFalse(refresh.due(at: 200))
        XCTAssertTrue(refresh.due(at: 225))
    }
    func testNonMonotonicOrStaleCompletionIsIgnored() throws {
        var refresh = ExternalDomainRefresh(applied: [a], startedAt: 100)
        XCTAssertNil(refresh.finish(at: 200, resolved: [b])) // Never began.
        XCTAssertEqual(refresh.applied, [a])
        XCTAssertTrue(refresh.begin(at: 160))
        XCTAssertNil(refresh.finish(at: 150, resolved: [b])) // Clock regression.
        XCTAssertTrue(refresh.inFlight)
        XCTAssertNotNil(refresh.finish(at: 161, resolved: [b]))
    }
    func testIdenticalResolutionProducesAnEmptyDiff() throws {
        var refresh = ExternalDomainRefresh(applied: [a], startedAt: 100)
        XCTAssertTrue(refresh.begin(at: 160))
        let diff = refresh.finish(at: 161, resolved: [a])
        XCTAssertEqual(diff, ExternalDomainDiff(add: [], remove: []))
        XCTAssertTrue(diff?.isEmpty == true)
        XCTAssertEqual(refresh.applied, [a])
    }
}
