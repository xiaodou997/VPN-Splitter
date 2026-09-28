// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import SystemConfiguration
import Darwin
import PolicyCore

/// Synchronous read-only collector. Call off MainActor; callers provide their own isolation.
/// This type exposes no route-write, VPN-control,
/// Keychain, generic command, file-import, resolver-query or packet-capture operation.
public struct ExternalSystemSnapshotReader: Sendable {
    public init() {}
    private struct NIC: Equatable {
        var addresses: [IPv4Address] = []
        var networks: [IPv4CIDR] = []
        var up = false
        var tunnel = false
    }
    public func capture() throws -> ExternalObservation {
        do {
            try Task.checkCancellation()
            let began = ProcessInfo.processInfo.systemUptime
            guard let store = SCDynamicStoreCreate(nil, "VPN-Splitter External read-only" as CFString, nil, nil) else { throw ExternalError.readFailed }
            let before = try values(store)
            let interfaces = try nics()
            let routes = try ExternalRouteTable.parseDiagnosing(readRoutes())
            let paths = try physicalPaths(before, interfaces: interfaces)
            var dns: Set<IPv4Address> = []
            for (key, value) in before where key.hasSuffix("/DNS") {
                guard let fields = value as? [String: Any] else { throw ExternalError.readFailed }
                if let raw = fields["ServerAddresses"] {
                    guard let servers = raw as? [String], servers.count <= 64 else { throw ExternalError.readFailed }
                    for server in servers {
                        if let ip = try? IPv4Address(server) { dns.insert(ip) }
                    }
                }
            }
            // Compare semantic rows, excluding countdowns but retaining expired status. No automatic
            // retry. This is a bounded observation window, not a kernel atomic snapshot.
            guard routes == (try ExternalRouteTable.parseDiagnosing(readRoutes())), interfaces == (try nics()),
                  NSDictionary(dictionary: before).isEqual(to: try values(store)) else { throw ExternalError.changedDuringRead }
            try Task.checkCancellation()
            return try ExternalObservation(capturedAtUptime: began,
                interfaces: interfaces.keys.sorted().map { name in
                    let nic = interfaces[name]!
                    return ExternalInterface(name: name, isUp: nic.up, isTunnelCandidate: nic.tunnel, addresses: nic.addresses)
                }, physicalPaths: paths, routes: routes, observedDNSServers: dns.sorted())
        } catch let error as ExternalRouteParseDiagnostic { throw error }
        catch let error as ExternalError { throw error }
        catch { throw ExternalError.readFailed }
    }
    private func values(_ store: SCDynamicStore) throws -> [String: Any] {
        let patterns = ["State:/Network/Service/[^/]+/IPv4", "State:/Network/Service/[^/]+/DNS"]
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/DNS"]
        guard let result = SCDynamicStoreCopyMultiple(store, keys as CFArray, patterns as CFArray) as? [String: Any],
              result.count <= 512 else { throw ExternalError.readFailed }
        return result
    }
    private func physicalPaths(_ state: [String: Any], interfaces: [String: NIC]) throws -> [ExternalPhysicalPath] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface], all.count <= 128 else { throw ExternalError.readFailed }
        var physical: Set<String> = []
        for item in all {
            guard let name = SCNetworkInterfaceGetBSDName(item) as String?,
                  let kind = SCNetworkInterfaceGetInterfaceType(item) as String? else { continue }
            if kind == (kSCNetworkInterfaceTypeEthernet as String) || kind == (kSCNetworkInterfaceTypeIEEE80211 as String) { physical.insert(name) }
        }
        var result: [ExternalPhysicalPath] = []
        for key in state.keys.sorted() where key.hasPrefix("State:/Network/Service/") && key.hasSuffix("/IPv4") {
            guard let fields = state[key] as? [String: Any] else { throw ExternalError.readFailed }
            guard let name = fields["InterfaceName"] as? String, physical.contains(name),
                  let nic = interfaces[name], nic.up, !nic.tunnel else { continue }
            // An active physical service without a router cannot become an Internet path.
            guard let rawRouter = fields["Router"] else { continue }
            guard let router = rawRouter as? String, let gateway = try? IPv4Address(router),
                  let addresses = fields["Addresses"] as? [String], !addresses.isEmpty,
                  addresses.count <= 64, addresses.allSatisfy({ text in nic.addresses.contains { $0.description == text } }),
                  !nic.networks.isEmpty else { throw ExternalError.readFailed }
            let service = String(key.dropFirst("State:/Network/Service/".count).dropLast("/IPv4".count))
            result.append(.init(service: service, interface: name, gateway: gateway, networks: nic.networks))
        }
        return result
    }
    private func nics() throws -> [String: NIC] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { throw ExternalError.readFailed }
        defer { freeifaddrs(first) }
        var result: [String: NIC] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var count = 0
        while let node = cursor {
            count += 1; guard count <= 8192 else { throw ExternalError.limitExceeded }
            let entry = node.pointee; cursor = entry.ifa_next
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.ifa_name)
            var nic = result[name] ?? NIC()
            nic.up = entry.ifa_flags & UInt32(IFF_UP) != 0
            nic.tunnel = entry.ifa_flags & UInt32(IFF_POINTOPOINT) != 0 || name.hasPrefix("utun") || name.hasPrefix("tun")
            let address = UnsafeRawPointer(socket).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let ip = IPv4Address(rawValue: UInt32(bigEndian: address.s_addr))
            nic.addresses.append(ip)
            if let mask = entry.ifa_netmask, mask.pointee.sa_family == UInt8(AF_INET) {
                let raw = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
                let bits = UInt32(bigEndian: raw); let prefix = bits.nonzeroBitCount
                guard prefix > 0, bits == UInt32.max << (32 - prefix) else { throw ExternalError.readFailed }
                nic.networks.append(try IPv4CIDR(address: ip, prefixLength: prefix))
            }
            nic.addresses = Array(Set(nic.addresses)).sorted(); nic.networks = Array(Set(nic.networks)).sorted()
            result[name] = nic
        }
        return result
    }
    private func readRoutes() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let output = Pipe(); process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw ExternalError.readFailed }
        try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning { process.terminate() }
            // Only this read-only child may be killed; never touch a VPN process.
            let stopAt = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stopAt { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); try? output.fileHandleForReading.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ExternalError.readFailed }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw ExternalError.readFailed }
            let readCount = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if readCount == 0 { break }
            if readCount > 0 {
                guard readCount <= ExternalRouteTable.maximumBytes - bytes.count else { throw ExternalError.limitExceeded }
                bytes.append(contentsOf: buffer.prefix(readCount))
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                Thread.sleep(forTimeInterval: 0.01)
            } else { throw ExternalError.readFailed }
        }
        // EOF can precede exit. Keep waiting bounded instead of waitUntilExit on an
        // otherwise still-running child; the defer reaps only after termination.
        while process.isRunning {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { throw ExternalError.readFailed }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw ExternalError.readFailed }
        return bytes
    }
}
#endif
