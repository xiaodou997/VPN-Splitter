// SPDX-License-Identifier: MIT
// TEST DOUBLE: constructs an admitted fixture; does not test 08D or authentication.
import Foundation
import PolicyCore
public struct Address { public var text: String; public init(_ text: String) { self.text = text } }
public struct Endpoint { public var display: String; public init(_ text: String) { display = text } }
public struct Peer {
    public var allowedIPs = [Address("10.99.0.0/16"), Address("10.88.0.7")]
    public var endpoint: Endpoint? = Endpoint("198.51.100.20:51820")
    public var persistentKeepalive: Int? = 0
    public var hadPresharedKey = true
    public init() {}
}
public struct Metadata {
    public var addresses = [Address("10.55.0.2/24")]
    public var dnsServers: [String] = []
    public var searchDomains: [String] = []
    public var listenPort: Int? = 0
    public var mtu: Int? = 1420
    public var peers = [Peer()]
    public init() {}
}
public struct CheckedManagedWireGuardInput {
    public var metadata: Metadata
    public let policy = IPv4Policy(73)
    private let source: Data
    public init(_ source: String, metadata: Metadata = Metadata()) { self.source = Data(source.utf8); self.metadata = metadata }
    public func withValidatedSource<T>(_ body: (Data, Data) throws -> T) rethrows -> T { try body(source, Data([1])) }
}
