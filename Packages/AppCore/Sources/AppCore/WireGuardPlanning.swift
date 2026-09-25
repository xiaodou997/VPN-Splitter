// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

public enum WireGuardPlanning {
    public static let boundary = "仅校验导入配置提供的 IPv4 端点、DNS、接口地址和 Peer 范围；未探测物理网关/局域网，未解析 DNS、未验证认证或出口。不是可安装的路由计划，无系统级 Kill Switch。"

    public static func compile(_ policy: IPv4Policy, metadata: WGMetadata,
                               context: PlanContext) throws -> ConstrainedIPv4PolicyPlan {
        try metadata.validate()
        guard !metadata.compatibilityIssues.contains(where: \.blocksPlanning) else { throw WGImportError(.planning) }
        var requirements: [InfrastructureRequirement] = []
        for (index, address) in metadata.addresses.enumerated() {
            requirements.append(.init(id: "wg-address-\(index + 1)", role: .localAddress,
                                      cidr: try IPv4CIDR(address.address + "/32")))
        }
        for (index, dns) in metadata.dnsServers.enumerated() {
            requirements.append(.init(id: "wg-dns-\(index + 1)", role: .vpnDNS, cidr: try IPv4CIDR(dns + "/32")))
        }
        for (index, peer) in metadata.peers.enumerated() {
            // Compatibility validation above rejects missing, hostname and IPv6 endpoints.
            guard let endpoint = peer.endpoint else { throw WGImportError(.planning) }
            requirements.append(.init(id: "wg-endpoint-\(index + 1)", role: .vpnEndpoint,
                                      cidr: try IPv4CIDR(endpoint.host + "/32")))
        }
        let peers = try metadata.peers.map { peer -> WireGuardPeerRange in
            let ranges = try peer.allowedIPs.map { range -> IPv4CIDR in
                guard let cidr = range.ipv4CIDR else { throw WGImportError(.planning) }
                return cidr
            }
            return WireGuardPeerRange(id: peer.id, allowedIPs: ranges)
        }
        return try IPv4ConstrainedPolicyCompiler.compile(policy, capabilities: .wireGuard,
            context: context, constraints: .init(context: context, infrastructure: requirements, wireGuardPeers: peers))
    }
}

/// Confirmation creates a NEW profile. No source path, keys or raw text survive parsing.
/// Exact baseline comparison also fences stale callbacks and failed-save retries.
public struct WGImportTransaction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let metadata: WGMetadata
    public let baseline: Workspace
    public init(metadata: WGMetadata, baseline: Workspace, id: UUID = UUID()) throws {
        try metadata.validate(); try baseline.validate()
        self.id = id; self.metadata = metadata; self.baseline = baseline
    }
    public func applying(to current: Workspace) throws -> Workspace {
        guard current == baseline else { throw DraftEditError.conflict }
        var next = current
        var profile = ProfileDraft(id: id, name: "WireGuard 策略 \(current.profiles.count + 1)")
        profile.wireGuard = metadata
        next.profiles.append(profile)
        // Old builds reject v2 rather than silently dropping the new metadata on save.
        next.schemaVersion = max(next.schemaVersion, 2)
        try next.validate()
        return next
    }
    public func save(session: inout LocalSession, store: DraftStore) throws {
        let next = try applying(to: session.workspace)
        try session.commit(next, store: store)
        session.select(id)
    }
}
