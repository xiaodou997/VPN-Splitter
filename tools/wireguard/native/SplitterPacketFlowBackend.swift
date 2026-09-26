// SPDX-License-Identifier: MIT
import Foundation
import Network
import NetworkExtension
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if SWIFT_PACKAGE
import WireGuardKitGo
#endif

public enum SplitterPacketFlowError: String, Error, Sendable {
    case invalidConfiguration, invalidMTU, stale, engineStart, packetRead, packetWrite, packetBatch
}

/// Protocol engine + the originating Provider's PUBLIC packetFlow, not a new utun.
/// Does not generate/apply NE routes or DNS. The host must first obtain a current
/// authorized plan and successful system-settings completion, then start on a worker.
/// Only IPv4/single-peer/no-DNS is admitted. No roaming, implicit update or retry.
public final class SplitterPacketFlowBackend: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let pump: PacketPump
    private init(pump: PacketPump) { self.pump = pump }

    public static func start(provider: NEPacketTunnelProvider, configuration: TunnelConfiguration,
                             mtu: Int, isCurrent: @escaping @Sendable () -> Bool,
                             failure: @escaping @Sendable (SplitterPacketFlowError) -> Void) throws -> SplitterPacketFlowBackend {
        guard (576...65535).contains(mtu) else { throw SplitterPacketFlowError.invalidMTU }
        guard isCurrent() else { throw SplitterPacketFlowError.stale }
        let snapshot = TunnelConfiguration(name: nil, interface: configuration.interface, peers: configuration.peers)
        guard snapshot.peers.count == 1, !snapshot.interface.addresses.isEmpty,
              snapshot.interface.addresses.allSatisfy({ $0.address is Network.IPv4Address }),
              snapshot.interface.dns.isEmpty, snapshot.interface.dnsSearch.isEmpty,
              !snapshot.peers[0].allowedIPs.isEmpty,
              snapshot.peers[0].allowedIPs.allSatisfy({ $0.address is Network.IPv4Address }),
              let endpoint = snapshot.peers[0].endpoint, case .ipv4 = endpoint.host,
              endpoint.port.rawValue > 0,
              snapshot.interface.mtu.map({ Int($0) == mtu }) ?? true else {
            throw SplitterPacketFlowError.invalidConfiguration
        }
        // Only protocol serialization is reused, NEVER generateNetworkSettings().
        let generator = PacketTunnelSettingsGenerator(tunnelConfiguration: snapshot, resolvedEndpoints: [endpoint])
        let (uapi, results) = generator.uapiConfiguration()
        guard results.count == 1, case .success((_, let resolved))? = results[0],
              resolved == endpoint else { throw SplitterPacketFlowError.invalidConfiguration }
        guard isCurrent() else { throw SplitterPacketFlowError.stale }
        let handle = wgTurnOnPacketFlow(uapi, Int32(mtu))
        guard handle >= 0 else { throw SplitterPacketFlowError.engineStart }
        guard isCurrent() else {
            wgTurnOffPacketFlow(handle)
            throw SplitterPacketFlowError.stale
        }
        let pump = PacketPump(flow: provider.packetFlow, handle: handle, mtu: mtu,
                              isCurrent: isCurrent, failure: failure)
        let backend = SplitterPacketFlowBackend(pump: pump)
        pump.begin()
        return backend
    }

    /// Ends protocol and packet work only. NOT evidence of NE settings/DNS restoration.
    /// Go shutdown may block; call off MainActor and retain until it settles.
    public func stop() { pump.close() }
    deinit { pump.close() }
    public var description: String { "SplitterPacketFlowBackend(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

// Workers retain this state, not the public owner. Releasing that owner closes the
// Go queues even if a read/producer is blocked. All handle claims are lock-guarded.
private final class PacketPump: @unchecked Sendable {
    private let flow: NEPacketTunnelFlow
    private let mtu: Int
    private let current: @Sendable () -> Bool
    private let failure: @Sendable (SplitterPacketFlowError) -> Void
    private let lock = NSLock()
    private let closing = DispatchGroup()
    private var handle: Int32?
    private var pendingRead: UUID?
    private let input = DispatchQueue(label: "vpnsplitter.packet-flow.input")
    private let output = DispatchQueue(label: "vpnsplitter.packet-flow.output")
    private let shutdown = DispatchQueue(label: "vpnsplitter.packet-flow.shutdown")

    init(flow: NEPacketTunnelFlow, handle: Int32, mtu: Int,
         isCurrent: @escaping @Sendable () -> Bool,
         failure: @escaping @Sendable (SplitterPacketFlowError) -> Void) {
        self.flow = flow; self.handle = handle; self.mtu = mtu
        current = isCurrent; self.failure = failure
    }
    func begin() {
        input.async { self.readNext() }
        output.async { self.writeLoop() }
    }
    private func active() -> Int32? {
        guard current() else { fail(.stale); return nil }
        lock.lock(); defer { lock.unlock() }
        return handle
    }
    private func readNext() {
        guard let expected = active() else { return }
        lock.lock()
        guard handle == expected, pendingRead == nil else { lock.unlock(); return }
        let token = UUID(); pendingRead = token
        lock.unlock()
        flow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.lock.lock()
            let accept = self.handle == expected && self.pendingRead == token
            if accept { self.pendingRead = nil }
            self.lock.unlock()
            guard accept else { return }
            // Framework has already allocated the batch. Bound what this layer retains
            // and queues; this is not a claim about Foundation's pre-callback allocation.
            guard packets.count == protocols.count, !packets.isEmpty, packets.count <= 128 else {
                self.fail(.packetBatch); return
            }
            var bytes = 0
            for (packet, family) in zip(packets, protocols) {
                guard family.int32Value == AF_INET, packet.count >= 20, packet.count <= self.mtu,
                      packet.count <= 2_097_152 - bytes else { self.fail(.packetBatch); return }
                bytes += packet.count
            }
            self.input.async {
                for packet in packets {
                    guard self.active() == expected else { return }
                    let written = packet.withUnsafeBytes { raw -> Int32 in
                        wgWritePacketFlow(expected, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count))
                    }
                    guard written == packet.count else { self.fail(.packetWrite); return }
                }
                self.readNext()
            }
        }
    }
    private func writeLoop() {
        var buffer = [UInt8](repeating: 0, count: mtu)
        while let expected = active() {
            let count = buffer.withUnsafeMutableBufferPointer {
                wgReadPacketFlow(expected, $0.baseAddress, Int32($0.count))
            }
            guard count >= 20, count <= mtu else { fail(.packetRead); return }
            guard active() == expected else { return }
            let packet = Data(buffer.prefix(Int(count)))
            // Serialize this synchronous write with handle revocation. Late readPackets
            // completions have no cancellation API; their tokens are discarded instead.
            lock.lock()
            guard handle == expected else { lock.unlock(); return }
            let written = flow.writePackets([packet], withProtocols: [NSNumber(value: AF_INET)])
            lock.unlock()
            guard written else { fail(.packetWrite); return }
        }
    }
    private func takeHandle() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        let old = handle; handle = nil; pendingRead = nil
        if old != nil { closing.enter() }
        return old
    }
    func close() {
        if let old = takeHandle() {
            wgTurnOffPacketFlow(old)
            closing.leave()
        }
        // Also join a failure-triggered shutdown that already claimed the handle.
        closing.wait()
    }
    private func fail(_ reason: SplitterPacketFlowError) {
        guard let old = takeHandle() else { return }
        // Never wait for the engine from inside one of its own packet callbacks.
        shutdown.async {
            wgTurnOffPacketFlow(old)
            self.closing.leave()
            self.failure(reason)
        }
    }
}
