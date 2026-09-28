// SPDX-License-Identifier: MIT
// Synthetic numeric netstat inputs; actual parser and IPv4 model, no system reads.
import Foundation
import PolicyCore
import ExternalCore

func require(_ condition: @autoclosure () -> Bool, _ reason: String = "assertion") {
    if !condition() { fatalError(reason) }
}
let header = "Routing tables\n\nInternet:\nDestination Gateway Flags Netif Expire\n"
let row = "203.0.113.7 192.0.2.1 UGHS en7"
func table(_ rows: String) -> Data { Data((header + rows + "\n").utf8) }
func parse(_ rows: String) throws -> Set<ExternalRoute> { try ExternalRouteTable.parseDiagnosing(table(rows)) }
func rejected(_ data: Data, _ field: ExternalRouteParseDiagnostic.Field,
              line: Int? = nil, columns: Int? = nil, code: ExternalError = .malformedRoutes) {
    do { _ = try ExternalRouteTable.parseDiagnosing(data); fatalError("accepted invalid table") }
    catch let diagnostic as ExternalRouteParseDiagnostic {
        require(diagnostic.code == code); require(diagnostic.field == field)
        if let line { require(diagnostic.line == line, "wrong line") }
        if let columns { require(diagnostic.columns == columns) }
        let text = String(describing: diagnostic)
        require(text == String(reflecting: diagnostic))
        for secret in ["203.0.113.7", "192.0.2.1", "en7", "secret.invalid"] { require(!text.contains(secret)) }
        require(Mirror(reflecting: diagnostic).children.isEmpty)
        require(text.utf8.count < 200)
    } catch { fatalError("diagnostic lost") }
    do { _ = try ExternalRouteTable.parse(data); fatalError("legacy accepted invalid table") }
    catch { require(error as? ExternalError == code, "legacy error changed") }
}

switch CommandLine.arguments[1] {
case "expiry":
    let records = try parse(row + " !\n198.51.100.0/24 192.0.2.1 UGS en7")
    require(records.count == 2)
    let expired = records.first { $0.destination.description == "203.0.113.7/32" }!
    require(expired.isExpired); require(!expired.usable); require(expired.flags == "UGHS")
    require(expired.gateway == "192.0.2.1"); require(expired.interface == "en7")
    let neighbors = try parse("192.0.2.1 aa:bb:cc:dd:ee:ff UHLWIir en7 !")
    require(neighbors.first!.isExpired && neighbors.first!.scoped && !neighbors.first!.usable)
    for selector in ["default", "0/1", "128.0/1", "192.0.2/24"] {
        let result = try parse(selector + " 192.0.2.1 UGS en7 !")
        require(result.count == 1 && !result.first!.usable)
    }
case "identity":
    let absent = try parse(row), first = try parse(row + " 1200"), second = try parse(row + " 1")
    require(absent == first && first == second)
    let expired = try parse(row + " !")
    require(expired != first && expired != absent)
    require(tryParseLegacy(table(row + " !")) == expired)
    for flags in ["UGHS", "UGHRS", "UGHBS"] {
        let value = try parse("203.0.113.7 192.0.2.1 " + flags + " en7 !")
        require(!value.first!.usable)
    }
case "columns":
    let old = "Routing tables\n\nInternet:\nDestination Gateway Flags Refs Use Netif Expire\n203.0.113.7 192.0.2.1 UGHS 2 300 en7 !\n"
    let modern = try parse(row + " !")
    require(tryParseLegacy(Data(old.utf8)) == modern)
    require(tryParseLegacy(Data(old.replacingOccurrences(of: "\n", with: "\r\n").utf8)) == modern)
    let crlf = (header + row + "\n" + row + " bad\n").replacingOccurrences(of: "\n", with: "\r\n")
    rejected(Data(crlf.utf8), .expiry, line: 6, columns: 5)
case "invalid":
    let cases: [(String, ExternalRouteParseDiagnostic.Field, Int)] = [
        ("203.0.113.7 secret.invalid UGHS en7", .gateway, 4),
        ("203.0.113.7 192.0.2.1 UG?S en7", .flags, 4),
        ("203.0.113.7 192.0.2.1 UGHS bad/name", .interface, 4),
        ("203.0.113.7/24 192.0.2.1 UGS en7", .destination, 4),
        (row + " !!", .expiry, 5), (row + " -1", .expiry, 5),
        (row + " 1.5", .expiry, 5), (row + " １２", .expiry, 5),
        (row + " 10 junk", .columns, 6), ("garbage", .columns, 1)]
    for (bad, field, count) in cases { rejected(table(row + "\n" + bad), field, line: 6, columns: count) }
    let old = "Routing tables\nInternet:\nDestination Gateway Flags Refs Use Netif Expire\n"
    rejected(Data((old + "203.0.113.7 192.0.2.1 UGHS ! 300 en7 10\n").utf8), .counters, line: 4)
    rejected(Data((old + "203.0.113.7 192.0.2.1 UGHS ２ 300 en7 10\n").utf8), .counters, line: 4)
    rejected(Data("Routing tables\nInternet:\nDestination Gateway Unknown Netif Expire\n".utf8), .header, line: 3)
    rejected(Data((header + "Internet:\n").utf8), .section, line: 5)
case "limits":
    rejected(Data(), .inputSize, line: 0, code: .limitExceeded)
    rejected(Data(repeating: 65, count: ExternalRouteTable.maximumBytes + 1), .inputSize, line: 0, code: .limitExceeded)
    rejected(Data([255, 254]), .encoding, line: 0)
    rejected(table(row + "\u{1b}"), .controlCharacter, line: 0)
    rejected(table(String(repeating: "X", count: 1025)), .lineSize, line: 5, code: .limitExceeded)
    rejected(table(Array(repeating: row, count: 8193).joined(separator: "\n")), .rowCount, line: 8197, code: .limitExceeded)
    rejected(Data(header.utf8), .emptyTable)
case "legacy":
    let samples: [(String, String)] = [("0/1", "0.0.0.0/1"), ("128.0/1", "128.0.0.0/1"),
        ("127", "127.0.0.0/8"), ("172.16", "172.16.0.0/16"), ("192.0.2", "192.0.2.0/24"),
        ("10.1/16", "10.1.0.0/16")]
    for (source, target) in samples { require(tryParseLegacy(table(source + " link#7 UCS en7")).first!.destination.description == target) }
    for bad in ["198.51", "10.1", "01.2.3.0/24", "0/33"] {
        rejected(table(bad + " link#7 UCS en7"), .destination, line: 5)
    }
    rejected(table("203.0.113.7 secret.invalid UGHS en7"), .gateway, line: 5, columns: 4)
default: fatalError("unknown test")
}
print("route-parser=PASS source=ACTUAL input=SYNTHETIC network=NOT_READ")

func tryParseLegacy(_ data: Data) -> Set<ExternalRoute> {
    do { return try ExternalRouteTable.parse(data) } catch { fatalError("legacy parse failed") }
}
