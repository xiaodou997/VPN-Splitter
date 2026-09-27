// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Darwin
import ExternalCore
import CExternalRoute

/// Process-local routing socket. Do not move between workers or expose over IPC.
/// The kernel checks root; the foreground host separately requires console consent.
public final class NativeExternalRouteDriver: ExternalRouteOperating {
    private let context: OpaquePointer
    private let tunnel: String
    public init(tunnel: String) throws {
        guard let context = er_open() else { throw ExternalLeaseFailure.consentRequired }
        self.context = context; self.tunnel = tunnel
    }
    deinit { er_close(context) } // NEVER assume close removes kernel routes.
    public func observe() throws -> ExternalObservation { try ExternalSystemSnapshotReader().capture() }
    public func drainEvents() -> Bool { er_drain(context) == 1 }
    public func owns(_ token: UInt64) -> Bool { er_owns(context, token) == 1 }
    public func add(_ route: ExternalLeaseRoute) -> ExternalAddResult {
        let physical = route.interface.withCString { if_nametoindex($0) }
        let vpn = tunnel.withCString { if_nametoindex($0) }
        guard physical > 0, physical <= UInt16.max, vpn > 0, vpn <= UInt16.max else { return .rejected }
        let spec = er_spec(destination: route.destination.networkAddress.rawValue, gateway: route.gateway.rawValue,
                           interface_index: UInt16(physical), tunnel_index: UInt16(vpn), prefix: UInt8(route.destination.prefixLength))
        let result = er_add(context, spec)
        switch result.status {
        case 0: return .acknowledged(result.token)
        case 1: return .rejected
        default: return .uncertain
        }
    }
    public func remove(_ token: UInt64) -> ExternalRemoveResult {
        switch er_remove(context, token).status {
        case 0: return .acknowledged
        case 1: return .refused
        default: return .uncertain
        }
    }
}
#endif
