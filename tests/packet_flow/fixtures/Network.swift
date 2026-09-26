// SPDX-License-Identifier: MIT
// TEST DOUBLE: no Apple Network framework behavior.
public protocol IPAddress: CustomStringConvertible {}
public struct IPv4Address: IPAddress, Equatable, Sendable {
    public let description: String
    public init?(_ value: String) {
        let pieces = value.split(separator: ".")
        guard pieces.count == 4, pieces.allSatisfy({ UInt8($0) != nil }) else { return nil }
        description = value
    }
}
public struct IPv6Address: IPAddress, Equatable, Sendable {
    public let description: String
    public init(_ value: String) { description = value }
}
