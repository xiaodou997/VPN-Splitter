// SPDX-License-Identifier: MIT
import Foundation

public enum WGParameterError: String, Error, Sendable {
    case missing = "E_WG_EDIT_MISSING", identity = "E_WG_EDIT_IDENTITY"
    case transactionRequired = "E_WG_EDIT_TRANSACTION"
    public var message: String {
        switch self {
        case .missing: "请先导入 WireGuard 配置，再编辑参数。"
        case .identity: "Peer 身份、顺序、AllowedIPs、搜索域或密钥标记发生变化；请使用重新导入，不会自动覆盖。"
        case .transactionRequired: "参数修改必须通过配置保存事务，不能绕过凭据一致性检查。"
        }
    }
}

/// Non-secret input buffer only; peer identity and protocol ranges are not editable here.
public struct WGPeerParameterDraft: Equatable, Sendable, Identifiable {
    public let id: String
    public var endpoint: String
    public var persistentKeepalive: String
}

public struct WGParameterDraft: Equatable, Sendable {
    public var addresses: String
    public var dnsServers: String
    public var listenPort: String
    public var mtu: String
    public var peers: [WGPeerParameterDraft]

    public init(_ metadata: WGMetadata) {
        addresses = metadata.addresses.map(\.text).joined(separator: ", ")
        dnsServers = metadata.dnsServers.joined(separator: ", ")
        listenPort = metadata.listenPort.map(String.init) ?? ""
        mtu = metadata.mtu.map(String.init) ?? ""
        peers = metadata.peers.map {
            .init(id: $0.id, endpoint: $0.endpoint?.display ?? "",
                  persistentKeepalive: $0.persistentKeepalive.map(String.init) ?? "")
        }
    }

    public func metadata(replacing original: WGMetadata) throws -> WGMetadata {
        try original.validate()
        guard peers.map(\.id) == original.peers.map(\.id) else { throw WGParameterError.identity }
        let addresses = try Self.list(addresses, maxCount: 64, field: .address).map { value in
            try Self.field(.address) { try WGAddressRange(value) }
        }
        let dns = try Self.list(dnsServers, maxCount: 32, field: .dns)
        guard dns.allSatisfy({ WGValidation.ip($0) != nil }) else { throw WGImportError(.address, field: .dns) }
        let updatedPeers = try zip(peers, original.peers).map { draft, old in
            let endpoint = try Self.text(draft.endpoint, limit: 264, field: .endpoint)
            return WGPeerMetadata(id: old.id, allowedIPs: old.allowedIPs,
                endpoint: endpoint.isEmpty ? nil : try Self.field(.endpoint) { try WGEndpoint(endpoint) },
                persistentKeepalive: try Self.number(draft.persistentKeepalive, range: 0...65535,
                                                    field: .persistentKeepalive, allowOff: true),
                hadPresharedKey: old.hadPresharedKey)
        }
        let result = WGMetadata(formatVersion: original.formatVersion, addresses: addresses,
            dnsServers: dns, searchDomains: original.searchDomains,
            listenPort: try Self.number(listenPort, range: 0...65535, field: .listenPort),
            mtu: try Self.number(mtu, range: 576...65535, field: .mtu), peers: updatedPeers)
        try Self.checkPreserved(original, updated: result)
        return result
    }

    /// Also enforced at the vault boundary, not just by the UI's field list.
    static func checkPreserved(_ original: WGMetadata, updated: WGMetadata) throws {
        try original.validate(); try updated.validate()
        guard original.formatVersion == updated.formatVersion,
              original.searchDomains == updated.searchDomains,
              original.peers.count == updated.peers.count else { throw WGParameterError.identity }
        for (old, new) in zip(original.peers, updated.peers) {
            guard old.id == new.id, old.allowedIPs == new.allowedIPs,
                  old.hadPresharedKey == new.hadPresharedKey else { throw WGParameterError.identity }
        }
    }

    public func changedFields(from original: WGMetadata) throws -> [String] {
        let next = try metadata(replacing: original)
        var names: [String] = []
        if next.addresses != original.addresses { names.append("接口地址") }
        if next.dnsServers != original.dnsServers { names.append("DNS 地址") }
        if next.listenPort != original.listenPort { names.append("监听端口") }
        if next.mtu != original.mtu { names.append("MTU") }
        for (index, pair) in zip(original.peers, next.peers).enumerated() {
            if pair.0.endpoint != pair.1.endpoint { names.append("Peer \(index + 1) 端点") }
            if pair.0.persistentKeepalive != pair.1.persistentKeepalive { names.append("Peer \(index + 1) 保活间隔") }
        }
        return names
    }

    private static func field<T>(_ name: WGField, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as WGImportError { throw WGImportError(error.code, field: name) }
    }
    private static func text(_ input: String, limit: Int, field: WGField) throws -> String {
        guard input.utf8.count <= limit else { throw WGImportError(.limit, field: field) }
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.newlines).contains($0) }) else {
            throw WGImportError(.text, field: field)
        }
        return input.trimmingCharacters(in: .whitespaces)
    }
    private static func list(_ input: String, maxCount: Int, field: WGField) throws -> [String] {
        let input = try text(input, limit: 8192, field: field)
        guard !input.isEmpty else { return [] }
        let values = input.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard values.count <= maxCount else { throw WGImportError(.limit, field: field) }
        guard values.allSatisfy({ !$0.isEmpty }) else { throw WGImportError(.address, field: field) }
        return values
    }
    private static func number(_ input: String, range: ClosedRange<Int>, field: WGField, allowOff: Bool = false) throws -> Int? {
        let input = try text(input, limit: 16, field: field)
        if input.isEmpty { return nil }
        if allowOff, input.lowercased() == "off" { return 0 }
        return try Self.field(field) { try WGValidation.integer(input, range: range) }
    }
}

/// A parameter save never exports keys, edits AllowedIPs, or installs a network plan.
public enum WGParameterOperations {
    @discardableResult
    public static func save(_ edit: DraftEdit, session: inout LocalSession,
                            store: any WorkspacePersistence, vault: any CredentialVault) throws -> Bool {
        guard edit.kind == .parameters, let draft = edit.parameters,
              let original = edit.baseline.wireGuard else { throw WGParameterError.missing }
        try current(session, store: store)
        guard session.selectedID == edit.baseline.id, session.profile == edit.baseline else { throw DraftEditError.conflict }
        let updated = try draft.metadata(replacing: original)
        guard updated != original else { return false }
        guard let index = session.workspace.profiles.firstIndex(where: { $0.id == edit.baseline.id }) else { throw DraftEditError.missing }
        var next = session.workspace
        next.profiles[index].wireGuard = updated
        try next.validate()
        if let old = edit.baseline.credential {
            guard session.workspace.cleanupQueue.isEmpty else { throw CredentialError.pendingCleanup }
            let reference = CredentialReference(profileID: edit.baseline.id)
            var staged = session.workspace
            staged.enqueueCleanup(reference)
            try publish(staged, session: &session, store: store)
            // The old item remains active until the new record and workspace both succeed.
            try vault.copyUpdatingParameters(from: old, to: reference, expected: original, updated: updated)
            try vault.verify(reference: reference, metadata: updated)
            next.profiles[index].credential = reference
            next.enqueueCleanup(old)
        }
        try publish(next, session: &session, store: store)
        return true
    }
    private static func current(_ session: LocalSession, store: any WorkspacePersistence) throws {
        try session.workspace.validate()
        guard try store.load() == session.workspace else { throw CredentialError.workspaceChanged }
    }
    private static func publish(_ next: Workspace, session: inout LocalSession, store: any WorkspacePersistence) throws {
        try current(session, store: store)
        try session.commit(next, store: store)
    }
}
