// SPDX-License-Identifier: MIT
import Foundation
@preconcurrency import Network
import SystemConfiguration
import Darwin
import PolicyCore

/// Read-only observations. No shell, DNS query, guessed en0, saved gateway replay,
/// private packetFlow access, or route writes. Unsupported/ambiguous paths fail.
struct ManagedUnderlaySnapshot: Equatable, Sendable {
    struct Address: Equatable, Sendable { let address: String; let prefix: Int }
    let service: String
    let interface: String
    let gateway: String
    let addresses: [Address]
    let mtu: Int

    func constraints(context: PlanContext) throws -> IPv4ConstraintInput {
        var values = [InfrastructureRequirement(id: "physical-gateway", role: .physicalGateway,
                                               cidr: try IPv4CIDR(gateway + "/32"))]
        for (index, address) in addresses.enumerated() {
            values.append(.init(id: "physical-lan-\(index)", role: .physicalLAN,
                cidr: try IPv4CIDR(address.address + "/\(address.prefix)")))
        }
        for (index, text) in ["0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/3"].enumerated() {
            values.append(.init(id: "reserved-\(index)", role: .systemReserved, cidr: try IPv4CIDR(text)))
        }
        return .init(context: context, infrastructure: values)
    }
    func resolvedMTU(_ configured: Int?) throws -> Int {
        let ceiling = mtu - 80
        let value = configured ?? min(1280, ceiling)
        guard (576...65535).contains(value), value <= ceiling else { throw ManagedUnderlayError.unsupported }
        return value
    }
}
enum ManagedUnderlayError: Error { case unavailable, unsupported, changed }

@MainActor
final class ManagedUnderlayMonitor {
    private let queue = DispatchQueue(label: "vpnsplitter.underlay")
    private let path = NWPathMonitor()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var baseline: ManagedUnderlaySnapshot?
    private var initial: ((Result<ManagedUnderlaySnapshot, ManagedUnderlayError>) -> Void)?
    private var changed: (() -> Void)?

    func start(initial: @escaping (Result<ManagedUnderlaySnapshot, ManagedUnderlayError>) -> Void,
               changed: @escaping () -> Void) {
        self.initial = initial; self.changed = changed
        path.pathUpdateHandler = { [weak self] path in
            // Do not pass NWPath between actors; only the bounded result leaves this queue.
            let usable = path.status == .satisfied && path.supportsIPv4 &&
                (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                if !usable { self.reject(); return }
                self.sample()
            }
        }
        path.start(queue: queue)
        // SCDynamicStore/getifaddrs re-observation also catches DHCP/MTU changes that
        // need not change NWPath's status. No topology is synthesized on read failure.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in Task { @MainActor in
            guard let self, !self.stopped, self.baseline != nil else { return }; self.sample()
        } }
        self.timer = timer; timer.resume()
    }
    func checkNow() throws {
        guard !stopped, let baseline, try Self.capture(rejectTunnels: false) == baseline else {
            throw ManagedUnderlayError.changed
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; path.cancel(); timer?.cancel(); timer = nil
        initial = nil; changed = nil
    }
    private func sample() {
        guard !stopped else { return }
        do {
            let observed = try Self.capture(rejectTunnels: baseline == nil)
            if let baseline {
                if observed != baseline { reject() }
            } else {
                baseline = observed; let ready = initial; initial = nil; ready?(.success(observed))
            }
        } catch { reject() }
    }
    private func reject() {
        let ready = initial; let invalidated = changed
        stop()
        if let ready { ready(.failure(.unavailable)) } else { invalidated?() }
    }
    private static func capture(rejectTunnels: Bool) throws -> ManagedUnderlaySnapshot {
        guard let store = SCDynamicStoreCreate(nil, "VPN-Splitter underlay" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let service = global["PrimaryService"] as? String,
              let name = global["PrimaryInterface"] as? String,
              !service.isEmpty, service.utf8.count <= 128, name.utf8.count <= 32,
              let values = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any],
              values["InterfaceName"] as? String == name,
              let router = values["Router"] as? String, (try? IPv4Address(router)) != nil,
              let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface],
              let physical = all.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == name }),
              let kind = SCNetworkInterfaceGetInterfaceType(physical) as String?,
              [kSCNetworkInterfaceTypeEthernet as String, kSCNetworkInterfaceTypeIEEE80211 as String].contains(kind) else {
            throw ManagedUnderlayError.unsupported
        }
        var mtu: Int32 = 0
        guard SCNetworkInterfaceCopyMTU(physical, &mtu, nil, nil), mtu >= 656 else { throw ManagedUnderlayError.unsupported }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { throw ManagedUnderlayError.unavailable }
        defer { freeifaddrs(first) }
        var addresses: [ManagedUnderlaySnapshot.Address] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            let entry = item.pointee; cursor = entry.ifa_next
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let interface = String(cString: entry.ifa_name)
            if rejectTunnels && (interface.hasPrefix("utun") || interface.hasPrefix("tun") ||
                                entry.ifa_flags & UInt32(IFF_POINTOPOINT) != 0) {
                throw ManagedUnderlayError.unsupported
            }
            guard interface == name, let mask = entry.ifa_netmask,
                  mask.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let ip = UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let bits = UInt32(bigEndian: netmask.s_addr)
            let prefix = bits.nonzeroBitCount
            guard prefix > 0, bits == (UInt32.max << (32 - prefix)) else { throw ManagedUnderlayError.unsupported }
            addresses.append(.init(address: IPv4Address(rawValue: UInt32(bigEndian: ip.s_addr)).description, prefix: prefix))
        }
        guard !addresses.isEmpty, addresses.count <= 16 else { throw ManagedUnderlayError.unsupported }
        addresses.sort { $0.address == $1.address ? $0.prefix < $1.prefix : $0.address < $1.address }
        // Read the global selection again; reject a change during this observation.
        guard let after = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? NSDictionary,
              after.isEqual(to: global) else { throw ManagedUnderlayError.changed }
        return .init(service: service, interface: name, gateway: router, addresses: addresses, mtu: Int(mtu))
    }
}
