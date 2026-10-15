// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
import PolicyCore
#if canImport(Darwin)
import Darwin

/// Blocking system resolver (the current VPN's DNS included), AF_INET only.
/// Call it off the service actor; the lease schedules it on a detached task.
/// No third-party DNS, no result caching and no logging of queried names.
public enum ExternalSystemResolver {
    public static func resolveIPv4(_ domain: String) throws -> [IPv4Address] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(domain, nil, &hints, &list)
        guard status == 0, let first = list else { throw ExternalError.domainResolutionFailed }
        defer { freeaddrinfo(first) }
        var addresses: [IPv4Address] = []
        for cursor in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard cursor.pointee.ai_family == AF_INET,
                  cursor.pointee.ai_addrlen == socklen_t(MemoryLayout<sockaddr_in>.size),
                  let address = cursor.pointee.ai_addr else { continue }
            let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            addresses.append(IPv4Address(rawValue: UInt32(bigEndian: raw)))
        }
        return addresses
    }
}
#endif
