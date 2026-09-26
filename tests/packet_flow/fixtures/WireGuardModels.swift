// SPDX-License-Identifier: MIT
// TEST DOUBLES for model constructors and UAPI generator. The quick-config parser
// and project converter are actual source; these are NOT WireGuard crypto/models.
import Foundation
import Network
public struct PrivateKey: Equatable {
    public let base64Key: String
    public init?(base64Key: String) { guard Data(base64Encoded: base64Key)?.count == 32 else { return nil }; self.base64Key = base64Key }
}
public struct PublicKey: Hashable {
    public let base64Key: String
    public init?(base64Key: String) { guard Data(base64Encoded: base64Key)?.count == 32 else { return nil }; self.base64Key = base64Key }
}
public typealias PreSharedKey = PrivateKey
public struct IPAddressRange {
    public let address: any IPAddress
    public let networkPrefixLength: UInt8
    public var stringRepresentation: String { "\(address)/\(networkPrefixLength)" }
    public init?(from value: String) {
        let p = value.split(separator: "/")
        guard !p.isEmpty, p.count <= 2, let a = IPv4Address(String(p[0])), let n = UInt8(p.count == 2 ? String(p[1]) : "32"), n <= 32 else { return nil }
        address = a; networkPrefixLength = n
    }
}
public struct DNSServer {
    public let stringRepresentation: String
    public init?(from value: String) { guard IPv4Address(value) != nil else { return nil }; stringRepresentation = value }
}
public struct Endpoint: Equatable {
    public enum Host: Equatable { case ipv4(IPv4Address), ipv6 }
    public struct Port: Equatable { public let rawValue: UInt16 }
    public let host: Host
    public let port: Port
    public let stringRepresentation: String
    public init?(from value: String) {
        let p = value.split(separator: ":")
        guard p.count == 2, let a = IPv4Address(String(p[0])), let port = UInt16(p[1]) else { return nil }
        host = .ipv4(a); self.port = Port(rawValue: port); stringRepresentation = value
    }
}
public struct InterfaceConfiguration {
    public let privateKey: PrivateKey
    public var addresses: [IPAddressRange] = []
    public var dns: [DNSServer] = []
    public var dnsSearch: [String] = []
    public var listenPort: UInt16?
    public var mtu: UInt16?
    public init(privateKey: PrivateKey) { self.privateKey = privateKey }
}
public struct PeerConfiguration {
    public let publicKey: PublicKey
    public var preSharedKey: PreSharedKey?
    public var allowedIPs: [IPAddressRange] = []
    public var endpoint: Endpoint?
    public var persistentKeepAlive: UInt16?
    public init(publicKey: PublicKey) { self.publicKey = publicKey }
}
public final class TunnelConfiguration {
    public var name: String?
    public var interface: InterfaceConfiguration
    public var peers: [PeerConfiguration]
    public init(name: String?, interface: InterfaceConfiguration, peers: [PeerConfiguration]) {
        self.name = name; self.interface = interface; self.peers = peers
    }
}
enum MockResolutionError: Error { case rejected }
final class PacketTunnelSettingsGenerator {
    let configuration: TunnelConfiguration
    let endpoints: [Endpoint?]
    init(tunnelConfiguration: TunnelConfiguration, resolvedEndpoints: [Endpoint?]) { configuration = tunnelConfiguration; endpoints = resolvedEndpoints }
    func uapiConfiguration() -> (String, [Result<(Endpoint, Endpoint), MockResolutionError>?]) {
        guard let endpoint = endpoints[0] else { return ("fixture", [nil]) }
        if configuration.interface.listenPort == 65534 { return ("fixture", [.failure(.rejected)]) }
        return ("fixture-only-not-wireguard-uapi", [.success((endpoint, endpoint))])
    }
}
