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
    public init(tunnel: String, queryOnly: Bool = false) throws {
        guard let context = queryOnly ? er_open_query() : er_open() else {
            throw queryOnly ? ExternalLeaseFailure.observationFailed : ExternalLeaseFailure.consentRequired
        }
        self.context = context; self.tunnel = tunnel
    }
    deinit { er_close(context) } // NEVER assume close removes kernel routes.
    public func observe() throws -> ExternalObservation { try ExternalSystemSnapshotReader().capture() }
    public func drainEvents() -> Bool { er_drain(context) == 1 }
    public func owns(_ token: UInt64) -> Bool { er_owns(context, token) == 1 }
    /// Safe metadata only. First native failure is retained across stop/cleanup.
    public var diagnosticSummary: String {
        let d = er_get_diagnostic(context)
        let stages = ["none", "targetGET", "gatewayGET", "add", "removeGET", "delete"]
        let reasons = ["none", "invalid", "readOnly", "poisoned", "event", "eventLimit", "receive", "truncated",
                       "request", "clock", "send", "timeout", "poll", "replyType", "decode", "replyKey",
                       "kernel", "targetPath", "gatewayPath", "ownership"]
        func name(_ value: Int32, _ names: [String]) -> String {
            let index = Int(value); return names.indices.contains(index) ? names[index] : "unknown"
        }
        return "route_io_schema=external-route-io-v1 stage=\(name(d.stage, stages)) reason=\(name(d.reason, reasons)) " +
            "decode_field=\(d.decode_field) system_errno=\(d.system_errno) reply_errno=\(d.reply_errno) " +
            "reply_type=\(d.reply_type) mutation_attempts=\(d.mutation_attempts)"
    }
    public func probe(_ route: ExternalLeaseRoute) -> Bool {
        guard let spec = makeSpec(route) else { return false }
        return er_probe(context, spec).status == 0
    }
    private func makeSpec(_ route: ExternalLeaseRoute) -> er_spec? {
        let physical = route.interface.withCString { if_nametoindex($0) }
        let vpn = tunnel.withCString { if_nametoindex($0) }
        guard physical > 0, physical <= UInt16.max, vpn > 0, vpn <= UInt16.max else { return nil }
        return er_spec(destination: route.destination.networkAddress.rawValue, gateway: route.gateway.rawValue,
                           interface_index: UInt16(physical), tunnel_index: UInt16(vpn), prefix: UInt8(route.destination.prefixLength))
    }
    public func add(_ route: ExternalLeaseRoute) -> ExternalAddResult {
        guard let spec = makeSpec(route) else { return .rejected }
        let result = er_add(context, spec)
        switch result.status {
        case 0: return .acknowledged(result.token)
        // Status 3 proves this call did not attempt ADD; prior batch receipts
        // still need the transaction's normal reverse cleanup.
        case 1, 3: return .rejected
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
