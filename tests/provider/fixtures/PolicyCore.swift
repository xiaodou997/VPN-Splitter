// SPDX-License-Identifier: MIT
// TEST DOUBLE ONLY. This exercises the legacy provider branch, NOT PolicyCore.
public struct IPv4CIDR {
    public init(_ input: String) throws {}
    public var description: String { "198.51.100.0/24" }
}
