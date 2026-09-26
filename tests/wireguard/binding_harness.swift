// SPDX-License-Identifier: MIT
// Explicit type doubles for exercising the ACTUAL appended binding source.
// Not WireGuardKit, Apple SDK, real keys, packets or Provider integration.
import Foundation

public struct InterfaceConfiguration: Equatable {
    var key: String
    var addresses: [String]
    var dns: [String]
    var port: Int?
    var mtu: Int?
}
public struct PeerConfiguration: Equatable {
    var key: String
    var psk: String?
    var allowedIPs: [String]
    var endpoint: String
    var keepalive: Int?
    public static func == (a: Self, b: Self) -> Bool {
        // Match the pinned upstream's set semantics to exercise extra order checks.
        a.key == b.key && a.psk == b.psk && Set(a.allowedIPs) == Set(b.allowedIPs)
            && a.endpoint == b.endpoint && a.keepalive == b.keepalive
    }
}
public final class TunnelConfiguration {
    public var name: String?
    public var interface: InterfaceConfiguration
    public let peers: [PeerConfiguration]
    public init(name: String?, interface: InterfaceConfiguration, peers: [PeerConfiguration]) {
        self.name = name; self.interface = interface; self.peers = peers
    }
}

// BINDING_SOURCE is inserted by test_admission.py here.
// <BINDING>

func config() -> TunnelConfiguration {
    TunnelConfiguration(name: "PRIVATE-NAME", interface: .init(key: "PRIVATE-KEY", addresses: ["a", "b"],
        dns: ["dns1"], port: 9, mtu: 1420), peers: [
        .init(key: "peer1", psk: "SECRET-PSK", allowedIPs: ["r1", "r2"], endpoint: "e1", keepalive: 25),
        .init(key: "peer2", psk: nil, allowedIPs: ["r3"], endpoint: "e2", keepalive: nil)
    ])
}
let revision = SplitterRuntimeRevision(providerInstance: UUID(), session: UUID(), generation: 1,
    networkEpoch: 2, credentialBinding: UUID())
func make(_ c: TunnelConfiguration) -> SplitterWireGuardBinding {
    SplitterWireGuardBinding(configuration: c, revision: revision, currentRevision: { revision })
}
func rejected(_ operation: () throws -> Void) {
    do { try operation(); fatalError("Unexpected admission") } catch {}
}

// Capture is not an alias to the mutable input reference.
let input = config(), binding = make(config())
let copy = try binding.checkedCopy(matching: input)
precondition(copy !== input && copy.name == nil)
copy.interface.mtu = 1200
let unchanged = try binding.checkedCopy(matching: input)
precondition(unchanged.interface.mtu == 1420)
input.interface.key = "OTHER-KEY"
rejected { _ = try binding.checkedCopy(matching: input) }
rejected { _ = try binding.checkedCopy(matching: config()) } // cannot revive

// Every configuration component, including order, is compared.
for index in 0..<11 {
    let old = config(), gate = make(config())
    var i = old.interface, peers = old.peers
    switch index {
    case 0: i.key = "changed"
    case 1: i.addresses.reverse()
    case 2: i.dns = ["other"]
    case 3: i.port = 10
    case 4: i.mtu = 1380
    case 5: peers.reverse()
    case 6: peers[0].key = "changed"
    case 7: peers[0].psk = nil
    case 8: peers[0].allowedIPs.reverse()
    case 9: peers[0].endpoint = "changed"
    default: peers[0].keepalive = 30
    }
    let altered = TunnelConfiguration(name: nil, interface: i, peers: peers)
    rejected { _ = try gate.checkedCopy(matching: altered) }
}
let fewer = config(), countBinding = make(config())
rejected { _ = try countBinding.checkedCopy(matching: TunnelConfiguration(name: nil, interface: fewer.interface, peers: [])) }
let renaming = config(), renameBinding = make(config())
renaming.name = "Other display name"
_ = try renameBinding.checkedCopy(matching: renaming)
let missing = SplitterWireGuardBinding(configuration: config(), revision: revision, currentRevision: { nil })
rejected { try missing.checkCurrent() }
let invalidated = make(config()); invalidated.invalidate()
rejected { try invalidated.checkCurrent() }
precondition(Mirror(reflecting: renameBinding).children.isEmpty)
precondition(!String(reflecting: renameBinding).contains("PRIVATE-KEY"))
print("binding_harness=PASS; upstream_types=DOUBLES; network=NOT_USED")
