// SPDX-License-Identifier: MIT
import PolicyCore

/// Static errors only: no input addresses, keys, or arbitrary framework errors.
public enum SettingsError: String, Error, Sendable {
    case contextChanged = "E_SETTINGS_CONTEXT"
    case wrongBackend = "E_SETTINGS_BACKEND"
    case peerMismatch = "E_SETTINGS_PEERS"
    case invalidAddress = "E_SETTINGS_ADDRESS"
    case invalidMTU = "E_SETTINGS_MTU"
    case inputLimit = "E_SETTINGS_INPUT_LIMIT"
    case routeLimit = "E_SETTINGS_ROUTE_LIMIT"
    case infrastructureMismatch = "E_SETTINGS_INFRASTRUCTURE"
    case dnsChoice = "E_SETTINGS_DNS_CHOICE"
    case dnsRoute = "E_SETTINGS_DNS_ROUTE"
    case emptyVPN = "E_SETTINGS_NO_VPN_ROUTES"
}

/// An interface address is NOT a route network address. Host bits must survive.
public struct TunnelIPv4Address: Equatable, Sendable {
    public let address: IPv4Address
    public let prefixLength: Int
    public var subnetMask: String { Self.mask(prefixLength) }

    public init(_ text: String) throws {
        do {
            let cidr = try IPv4CIDR(text)
            guard let host = text.split(separator: "/").first else { throw SettingsError.invalidAddress }
            self.address = try IPv4Address(String(host))
            self.prefixLength = cidr.prefixLength
        } catch { throw SettingsError.invalidAddress }
    }
    static func mask(_ prefix: Int) -> String {
        IPv4Address(rawValue: prefix == 0 ? 0 : UInt32.max << (32 - prefix)).description
    }
}

/// No implicit DNS fallback. Keeping system DNS requires a caller's explicit choice.
/// Domain DNS selection is deliberately absent until the S2 resolver contract exists.
public enum ManagedDNSChoice: Equatable, Sendable {
    case keepSystemExplicitly
    case tunnelDefault(servers: [IPv4Address])
}

/// Explicit IPv4 MTU or the upstream macOS overhead candidate, not path discovery.
public enum ManagedMTU: Equatable, Sendable {
    case explicit(Int)
    case automaticOverhead80
}

/// Complete key-free IPv4 projection supplied by the future protocol adapter.
/// Callers must reject unsupported IPv6/hostname projections before construction.
/// No endpoint resolution, credential access, or network discovery occurs here.
public struct SettingsInput: Equatable, Sendable {
    public let context: PlanContext
    public let addresses: [TunnelIPv4Address]
    public let endpoints: [IPv4Address]
    public let protocolPeers: [WireGuardPeerRange]
    public let dns: ManagedDNSChoice
    public let mtu: ManagedMTU

    public init(context: PlanContext, addresses: [TunnelIPv4Address], endpoints: [IPv4Address],
                protocolPeers: [WireGuardPeerRange], dns: ManagedDNSChoice, mtu: ManagedMTU) {
        self.context = context; self.addresses = addresses; self.endpoints = endpoints
        self.protocolPeers = protocolPeers; self.dns = dns; self.mtu = mtu
    }
}
