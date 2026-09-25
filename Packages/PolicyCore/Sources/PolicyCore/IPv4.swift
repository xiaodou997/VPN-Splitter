// SPDX-License-Identifier: MIT

/// Errors deliberately omit the supplied address/configuration.
public enum IPv4ParseError: Error, Equatable, Sendable {
    case invalidAddress
    case invalidCIDR
    case invalidPrefixLength
}

/// Canonical dotted-decimal IPv4 only; no DNS, abbreviations, signs or octal.
public struct IPv4Address: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public init(_ text: String) throws {
        guard (7...15).contains(text.utf8.count) else { throw IPv4ParseError.invalidAddress }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw IPv4ParseError.invalidAddress }
        var value: UInt32 = 0
        for part in parts {
            guard (1...3).contains(part.utf8.count),
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0",
                  let octet = UInt32(part), octet <= 255 else {
                throw IPv4ParseError.invalidAddress
            }
            value = (value << 8) | octet
        }
        rawValue = value
    }

    public var description: String {
        [24, 16, 8, 0].map { String((rawValue >> $0) & 255) }.joined(separator: ".")
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do { self = try Self(value) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid canonical IPv4 address")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Host bits are normalized. All construction paths preserve prefix invariants.
public struct IPv4CIDR: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let networkAddress: IPv4Address
    public let prefixLength: Int

    public init(address: IPv4Address, prefixLength: Int) throws {
        guard (0...32).contains(prefixLength) else { throw IPv4ParseError.invalidPrefixLength }
        self.init(validatedAddress: address.rawValue, prefixLength: prefixLength)
    }

    public init(_ text: String) throws {
        guard text.utf8.count <= 18 else { throw IPv4ParseError.invalidCIDR }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw IPv4ParseError.invalidCIDR }
        let prefix = parts[1]
        guard (1...2).contains(prefix.utf8.count),
              prefix.utf8.allSatisfy({ (48...57).contains($0) }),
              prefix.count == 1 || prefix.first != "0",
              let length = Int(prefix), length <= 32 else { throw IPv4ParseError.invalidPrefixLength }
        try self.init(address: IPv4Address(String(parts[0])), prefixLength: length)
    }

    // Only called with a prefix already validated by parsing or interval decomposition.
    internal init(validatedAddress: UInt32, prefixLength: Int) {
        let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - prefixLength)
        self.networkAddress = IPv4Address(rawValue: validatedAddress & mask)
        self.prefixLength = prefixLength
    }

    public var addressCount: UInt64 { UInt64(1) << (32 - prefixLength) }
    public var description: String { "\(networkAddress)/\(prefixLength)" }

    public func contains(_ address: IPv4Address) -> Bool {
        let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - prefixLength)
        return address.rawValue & mask == networkAddress.rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.networkAddress != rhs.networkAddress { return lhs.networkAddress < rhs.networkAddress }
        return lhs.prefixLength < rhs.prefixLength
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do { self = try Self(value) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IPv4 CIDR")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
