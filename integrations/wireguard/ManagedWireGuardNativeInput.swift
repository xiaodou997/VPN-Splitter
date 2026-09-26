// SPDX-License-Identifier: MIT
import Foundation
import ProviderConfiguration
import PolicyCore
import WireGuardKit

public enum ManagedWireGuardNativeInputError: String, Error {
    case conversion, projectionChanged
}

/// Converts the exact 08D snapshot to actual WireGuardKit model objects. Secrets
/// remain in memory; neither parser errors nor raw config are exposed as diagnostics.
/// Every requested configuration is a fresh reference, not the retained mutable one.
public final class ManagedWireGuardNativeInput: CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let policy: IPv4Policy
    private let interface: InterfaceConfiguration
    private let peers: [PeerConfiguration]

    public init(_ admitted: CheckedManagedWireGuardInput) throws {
        let native: TunnelConfiguration
        do {
            native = try admitted.withValidatedSource { source, _ in
                guard let text = String(data: source, encoding: .utf8) else {
                    throw ManagedWireGuardNativeInputError.conversion
                }
                return try SplitterNativeConfiguration.parseAdmittedText(text)
            }
        } catch { throw ManagedWireGuardNativeInputError.conversion }
        let metadata = admitted.metadata
        func explicitPrefix(_ value: String) -> String { value.contains("/") ? value : value + "/32" }
        guard native.peers.count == 1, metadata.peers.count == 1,
              native.interface.addresses.map(\.stringRepresentation) == metadata.addresses.map({ explicitPrefix($0.text) }),
              native.interface.listenPort.map(Int.init) == metadata.listenPort,
              native.interface.mtu.map(Int.init) == metadata.mtu,
              native.interface.dns.isEmpty, native.interface.dnsSearch.isEmpty,
              metadata.dnsServers.isEmpty, metadata.searchDomains.isEmpty,
              native.peers[0].allowedIPs.map(\.stringRepresentation) == metadata.peers[0].allowedIPs.map({ explicitPrefix($0.text) }),
              native.peers[0].endpoint?.stringRepresentation == metadata.peers[0].endpoint?.display,
              native.peers[0].persistentKeepAlive.map(Int.init) == metadata.peers[0].persistentKeepalive,
              (native.peers[0].preSharedKey != nil) == metadata.peers[0].hadPresharedKey else {
            throw ManagedWireGuardNativeInputError.projectionChanged
        }
        interface = native.interface; peers = native.peers; policy = admitted.policy
    }
    public func makeConfiguration() -> TunnelConfiguration {
        TunnelConfiguration(name: nil, interface: interface, peers: peers)
    }
    public var description: String { "ManagedWireGuardNativeInput(<redacted>; native-model-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
