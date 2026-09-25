// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import PolicyCore

final class IPv4Tests: XCTestCase {
    func testCanonicalAddressesRoundTrip() throws {
        for value in ["0.0.0.0", "255.255.255.255", "10.42.0.1", "198.51.100.7"] {
            XCTAssertEqual(try IPv4Address(value).description, value)
        }
        XCTAssertEqual(try IPv4Address("255.255.255.255").rawValue, UInt32.max)
    }

    func testInvalidAndAmbiguousAddressesAreRejected() {
        for value in ["", "1", "127.1", "1.2.3", "1.2.3.4.5", "1..2.3", ".1.2.3", "1.2.3.",
                      "256.1.2.3", "-1.2.3.4", "+1.2.3.4", "01.2.3.4", "1.02.3.4", "0x1.2.3.4",
                      "1.2.3.4 ", " 1.2.3.4", "1.2.3.4\n", "１.2.3.4", "1.2.3.٤", "::1", "host.example",
                      "1.2.3.4/32", "1.2.3.4:443", "1.2.3.4\u{0}"] {
            XCTAssertThrowsError(try IPv4Address(value), value)
        }
    }

    func testRawAddressRoundTripsAcrossRange() throws {
        for i in UInt32(0)...255 {
            let value = i * 0x01010101
            XCTAssertEqual(try IPv4Address(IPv4Address(rawValue: value).description).rawValue, value)
        }
    }

    func testCIDRNormalizesHostBits() throws {
        XCTAssertEqual(try IPv4CIDR("10.42.7.9/16").description, "10.42.0.0/16")
        XCTAssertEqual(try IPv4CIDR("255.255.255.255/0").description, "0.0.0.0/0")
        XCTAssertEqual(try IPv4CIDR("198.51.100.7/32").description, "198.51.100.7/32")
    }

    func testInvalidCIDRsAreRejected() {
        for value in ["", "10.0.0.0", "10/8", "10.0.0.0/", "/8", "10.0.0.0/33", "10.0.0.0/-1",
                      "10.0.0.0/+1", "10.0.0.0/08", "10.0.0.0/8/1", "10.0.0.0/8 ", "10.0.0.0/８",
                      "10.0.0.0/255.0.0.0", "256.0.0.0/8", "::/0"] {
            XCTAssertThrowsError(try IPv4CIDR(value), value)
        }
    }

    func testPrefixConstructorRejectsOutOfRange() {
        for length in [-1, 33, Int.min, Int.max] {
            XCTAssertThrowsError(try IPv4CIDR(address: IPv4Address(rawValue: 0), prefixLength: length))
        }
    }

    func testEveryPrefixSizeAndBoundaries() throws {
        for prefix in 0...32 {
            let cidr = try IPv4CIDR(address: IPv4Address(rawValue: 0xA1234567), prefixLength: prefix)
            let start = UInt64(cidr.networkAddress.rawValue)
            let end = start + cidr.addressCount
            XCTAssertEqual(cidr.addressCount, UInt64(1) << (32 - prefix))
            XCTAssertTrue(cidr.contains(cidr.networkAddress))
            XCTAssertTrue(cidr.contains(IPv4Address(rawValue: UInt32(end - 1))))
            if start > 0 { XCTAssertFalse(cidr.contains(IPv4Address(rawValue: UInt32(start - 1)))) }
            if end < UInt64(1) << 32 { XCTAssertFalse(cidr.contains(IPv4Address(rawValue: UInt32(end)))) }
        }
    }

    func testSlashZeroAndSlash32() throws {
        let all = try IPv4CIDR("0.0.0.0/0")
        XCTAssertEqual(all.addressCount, 4_294_967_296)
        XCTAssertTrue(all.contains(IPv4Address(rawValue: 0)))
        XCTAssertTrue(all.contains(IPv4Address(rawValue: .max)))
        let last = try IPv4CIDR("255.255.255.255/32")
        XCTAssertEqual(last.addressCount, 1)
        XCTAssertFalse(last.contains(IPv4Address(rawValue: .max - 1)))
    }

    func testDeterministicOrdering() throws {
        let values = try ["10.42.0.0/16", "10.0.0.0/16", "0.0.0.0/0", "10.0.0.0/8"].map(IPv4CIDR.init)
        XCTAssertEqual(values.sorted().map(\.description), ["0.0.0.0/0", "10.0.0.0/8", "10.0.0.0/16", "10.42.0.0/16"])
    }

    func testCodableUsesValidatedCanonicalStrings() throws {
        let cidr = try IPv4CIDR("10.42.7.9/16")
        XCTAssertEqual(try JSONDecoder().decode(IPv4CIDR.self, from: JSONEncoder().encode(cidr)), cidr)
        let ip = try IPv4Address("198.51.100.7")
        XCTAssertEqual(try JSONDecoder().decode(IPv4Address.self, from: JSONEncoder().encode(ip)), ip)
        for raw in ["\"10.0.0.0/99\"", "{\"networkAddress\":0,\"prefixLength\":99}", "null", "42"] {
            XCTAssertThrowsError(try JSONDecoder().decode(IPv4CIDR.self, from: Data(raw.utf8)))
        }
        XCTAssertThrowsError(try JSONDecoder().decode(IPv4Address.self, from: Data("\"999.0.0.1\"".utf8)))
    }
}
