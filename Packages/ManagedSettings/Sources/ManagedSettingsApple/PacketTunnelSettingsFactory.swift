// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import ManagedSettings

/// Allocates Apple settings objects only. No provider, manager, or application API.
/// Kept out of LocalDev and out of the deliberately nonfunctional S1 provider.
public enum PacketTunnelSettingsFactory {
    public static func makeForInspection(_ draft: ManagedSettingsDraft,
                                         current: SettingsInput) throws -> NEPacketTunnelNetworkSettings {
        try draft.check(against: current)
        // A display value, NOT endpoint protection. Every endpoint is separately checked
        // in the draft and excluded from this tunnel by the compiled route intent.
        guard let remote = draft.input.endpoints.first else { throw SettingsError.invalidAddress }
        let result = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote.description)
        let ipv4 = NEIPv4Settings(addresses: draft.input.addresses.map { $0.address.description },
                                 subnetMasks: draft.input.addresses.map(\.subnetMask))
        ipv4.includedRoutes = draft.includedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destination, subnetMask: $0.subnetMask)
        }
        ipv4.excludedRoutes = draft.excludedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destination, subnetMask: $0.subnetMask)
        }
        result.ipv4Settings = ipv4
        result.ipv6Settings = nil
        switch draft.input.dns {
        case .keepSystemExplicitly: result.dnsSettings = nil
        case .tunnelDefault(let servers):
            let dns = NEDNSSettings(servers: servers.map(\.description))
            dns.matchDomains = [""]
            dns.matchDomainsNoSearch = true
            dns.searchDomains = []
            result.dnsSettings = dns
        }
        switch draft.input.mtu {
        case .explicit(let value): result.mtu = NSNumber(value: value)
        case .automaticOverhead80: result.tunnelOverheadBytes = 80
        }
        return result
    }
}
