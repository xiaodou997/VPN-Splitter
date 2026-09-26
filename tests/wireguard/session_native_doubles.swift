// SPDX-License-Identifier: MIT
// EXPLICIT TEST DOUBLES. No WireGuardKit, NetworkExtension, Keychain, socket or VPN.
// Only the controller and ManagedWireGuardSession source are real in this harness.
import Foundation

public final class NEPacketTunnelProvider {}
public struct IPv4Policy: Sendable {}
public struct IPv4ConstraintInput: Sendable {}
public enum WireGuardDNSSelection: Sendable { case keepSystem }
public struct InterfaceConfiguration: Sendable { var marker: String }
public struct PeerConfiguration: Sendable { var marker: String }
public final class TunnelConfiguration {
    public var name: String?
    public var interface: InterfaceConfiguration
    public let peers: [PeerConfiguration]
    public init(name: String?, interface: InterfaceConfiguration, peers: [PeerConfiguration]) {
        self.name = name; self.interface = interface; self.peers = peers
    }
}
public struct SplitterRuntimeRevision: Sendable, Equatable {
    public let providerInstance: UUID
    public let session: UUID
    public let generation: UInt64
    public let networkEpoch: UInt64
    public let credentialBinding: UUID
}
public final class SplitterTunnelDescriptorLease {}
@MainActor public final class SplitterWireGuardBinding {
    var invalidated = false
    public func invalidate() { invalidated = true }
}
@MainActor public final class WireGuardAdapter {
    var starts = 0
    var stops = 0
    var marker: String?
    var deferredStart = false
    var stopFails = false
    var startCompletion: ((Error?) -> Void)?
    public func start(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (Error?) -> Void) {
        starts += 1; marker = tunnelConfiguration.interface.marker; startCompletion = completionHandler
        if !deferredStart { completionHandler(nil) }
    }
    public func stop(completionHandler: @escaping (Error?) -> Void) {
        stops += 1
        completionHandler(stopFails ? NSError(domain: "EXPLICIT-TEST-DOUBLE", code: 1) : nil)
    }
}
@MainActor public final class ManagedWireGuardAssembly {
    static var made: [ManagedWireGuardAssembly] = []
    static var failPreparation = false
    static var deferStart = false
    let binding = SplitterWireGuardBinding()
    let adapter = WireGuardAdapter()
    let current: () -> SplitterRuntimeRevision?
    let revision: SplitterRuntimeRevision
    init(current: @escaping () -> SplitterRuntimeRevision?, revision: SplitterRuntimeRevision) {
        self.current = current; self.revision = revision
    }
    public static func prepareForIntegration(provider: NEPacketTunnelProvider, configuration: TunnelConfiguration,
        policy: IPv4Policy, underlay: IPv4ConstraintInput, dnsSelection: WireGuardDNSSelection,
        revision: SplitterRuntimeRevision, currentRevision: @escaping () -> SplitterRuntimeRevision?,
        descriptor: @escaping () throws -> SplitterTunnelDescriptorLease) throws -> ManagedWireGuardAssembly {
        if failPreparation { throw NSError(domain: "NEVER-LOG-THIS-SYNTHETIC-VALUE", code: 2) }
        precondition(currentRevision() == revision)
        let value = ManagedWireGuardAssembly(current: currentRevision, revision: revision)
        value.adapter.deferredStart = deferStart
        made.append(value)
        return value
    }
}
