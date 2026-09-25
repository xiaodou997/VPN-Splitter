// SPDX-License-Identifier: MIT
import Foundation

/// Opaque metadata only. The independent nonce is an ownership check, not a secret.
public struct CredentialReference: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let profileID: UUID
    public let ownershipNonce: UUID
    public init(profileID: UUID, id: UUID = UUID(), ownershipNonce: UUID = UUID()) {
        self.id = id; self.profileID = profileID; self.ownershipNonce = ownershipNonce
    }
}

public enum CredentialError: String, Error, Sendable {
    case unavailable = "E_KEYCHAIN_UNAVAILABLE", accessDenied = "E_KEYCHAIN_ACCESS"
    case cancelled = "E_KEYCHAIN_CANCELLED", duplicate = "E_KEYCHAIN_DUPLICATE"
    case missing = "E_KEYCHAIN_MISSING", invalidRecord = "E_KEYCHAIN_RECORD"
    case ownership = "E_KEYCHAIN_OWNERSHIP", mismatch = "E_KEYCHAIN_MISMATCH"
    case operation = "E_KEYCHAIN_OPERATION", pendingCleanup = "E_KEYCHAIN_PENDING"
    case workspaceInUse = "E_WORKSPACE_IN_USE", workspaceChanged = "E_WORKSPACE_CHANGED"

    public var message: String {
        let text: String
        switch self {
        case .unavailable: text = "系统 Keychain 当前不可用；未回退为明文保存。"
        case .accessDenied: text = "无法访问 Keychain，可能被锁定或授权被拒绝。请在本机确认后重试，不要降低系统安全设置。"
        case .cancelled: text = "已取消本次 Keychain 授权；未继续执行需要授权的操作。"
        case .duplicate: text = "随机凭据标识发生冲突；未覆盖已有 Keychain 条目。"
        case .missing: text = "关联的 Keychain 条目不存在。规则仍保留，可从原 .conf 重新导入。"
        case .invalidRecord: text = "Keychain 记录格式不合法或版本不支持；未自动删除。"
        case .ownership: text = "Keychain 记录归属不符；已停止，不删除无法认领的条目。"
        case .mismatch: text = "Keychain 凭据与当前结构不匹配；未视为可用，也未删除原记录。"
        case .operation: text = "Keychain 操作失败；未回退为明文保存。若有待清理记录，请确认后重试。"
        case .pendingCleanup: text = "请先重试待清理凭据，再保存新的凭据。取消授权不会清空旧策略。"
        case .workspaceInUse: text = "另一实例正在使用工作区，或无法取得安全的工作区锁。请退出其他 LocalDev 实例；不要删除锁文件。"
        case .workspaceChanged: text = "磁盘工作区已变化；已停止凭据操作。请保护现有文件并重新打开应用，不要强制覆盖。"
        }
        return text + "（" + rawValue + "）"
    }
}

/// Deliberately not Codable and not a raw-config wrapper. Only KeychainRecord can encode it.
/// Redaction reduces accidental logging; Swift copies are NOT guaranteed to be zeroized.
public struct WGCredentialMaterial: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let metadata: WGMetadata
    fileprivate let payload: Payload
    fileprivate struct Peer: Codable, Equatable, Sendable {
        let id: String
        let publicKey: Data
        let presharedKey: Data?
    }
    fileprivate struct Payload: Codable, Equatable, Sendable {
        let privateKey: Data
        let peers: [Peer]
    }
    init(metadata: WGMetadata, privateKey: Data, peers: [(id: String, publicKey: Data, presharedKey: Data?)]) throws {
        self.metadata = metadata
        payload = Payload(privateKey: privateKey, peers: peers.map { Peer(id: $0.id, publicKey: $0.publicKey, presharedKey: $0.presharedKey) })
        try validate()
    }
    fileprivate func validate() throws {
        try metadata.validate()
        func valid(_ key: Data) -> Bool { key.count == 32 && key.contains(where: { $0 != 0 }) }
        guard valid(payload.privateKey), payload.peers.count == metadata.peers.count,
              Set(payload.peers.map(\.publicKey)).count == payload.peers.count else { throw CredentialError.invalidRecord }
        for (key, peer) in zip(payload.peers, metadata.peers) {
            guard key.id == peer.id, valid(key.publicKey), (key.presharedKey != nil) == peer.hadPresharedKey,
                  key.presharedKey.map(valid) != false else { throw CredentialError.invalidRecord }
        }
    }
    public var description: String { "WGCredentialMaterial(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Only this internal envelope serializes keys, and its bytes are handed only to the vault.
/// Network metadata is included inside the encrypted value for an exact binding check.
struct KeychainRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let byteLimit = 512 * 1024
    let version: Int
    let reference: CredentialReference
    let metadata: WGMetadata
    private let payload: WGCredentialMaterial.Payload
    init(reference: CredentialReference, material: WGCredentialMaterial) throws {
        try material.validate()
        version = 1; self.reference = reference; metadata = material.metadata; payload = material.payload
    }
    func encoded() throws -> Data {
        do {
            let data = try JSONEncoder().encode(self)
            guard data.count <= Self.byteLimit else { throw CredentialError.invalidRecord }
            return data
        } catch { throw CredentialError.invalidRecord }
    }
    static func decode(_ data: Data) throws -> Self {
        do {
            guard data.count <= byteLimit else { throw CredentialError.invalidRecord }
            let item = try JSONDecoder().decode(Self.self, from: data)
            guard item.version == 1 else { throw CredentialError.invalidRecord }
            _ = try WGCredentialMaterial(metadata: item.metadata, privateKey: item.payload.privateKey,
                peers: item.payload.peers.map { ($0.id, $0.publicKey, $0.presharedKey) })
            return item
        } catch { throw CredentialError.invalidRecord }
    }
    func check(reference: CredentialReference, metadata: WGMetadata? = nil) throws {
        guard self.reference == reference else { throw CredentialError.ownership }
        if let metadata, self.metadata != metadata { throw CredentialError.mismatch }
    }
    var description: String { "KeychainRecord(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// No update, enumeration, bulk delete, plaintext fallback, or credential export API.
public protocol CredentialVault: Sendable {
    func create(_ material: WGCredentialMaterial, reference: CredentialReference) throws
    func verify(reference: CredentialReference, metadata: WGMetadata) throws
    /// Idempotent on missing items; rejects unreadable / malformed / wrong-owner items.
    func removeOwned(reference: CredentialReference) throws
}

/// Injected persistence lets tests interrupt every journal write without using a real Keychain.
public protocol WorkspacePersistence {
    func load() throws -> Workspace
    func save(_ workspace: Workspace) throws
}

public struct CredentialImportTransaction: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id = UUID()
    public let profileID: UUID
    public let replacing: Bool
    public let material: WGCredentialMaterial
    public var metadata: WGMetadata { material.metadata }
    private let baselineProfiles: [ProfileDraft]
    public var previousCredential: CredentialReference? { baselineProfiles.first { $0.id == profileID }?.credential }
    public init(material: WGCredentialMaterial, workspace: Workspace, replacing profileID: UUID? = nil) throws {
        try workspace.validate()
        if let profileID {
            guard workspace.profiles.contains(where: { $0.id == profileID && $0.backend == .wireGuard }) else {
                throw DraftEditError.missing
            }
        }
        self.material = material; baselineProfiles = workspace.profiles
        self.profileID = profileID ?? UUID(); replacing = profileID != nil
    }
    func applying(to workspace: Workspace, reference: CredentialReference?) throws -> Workspace {
        guard workspace.profiles == baselineProfiles else { throw DraftEditError.conflict }
        var next = workspace
        if replacing {
            guard let index = next.profiles.firstIndex(where: { $0.id == profileID }) else { throw DraftEditError.missing }
            let old = next.profiles[index].credential
            next.profiles[index].wireGuard = metadata
            next.profiles[index].credential = reference
            if let old { next.enqueueCleanup(old) }
        } else {
            var profile = ProfileDraft(id: profileID, name: "WireGuard 策略 \(next.profiles.count + 1)")
            profile.wireGuard = metadata; profile.credential = reference
            next.profiles.append(profile)
        }
        next.schemaVersion = max(next.schemaVersion, reference == nil ? 2 : 3)
        try next.validate()
        return next
    }
    public var description: String { "CredentialImportTransaction(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

public enum CredentialOperations {
    private static func current(_ session: LocalSession, store: any WorkspacePersistence) throws {
        try session.workspace.validate()
        guard try store.load() == session.workspace else { throw CredentialError.workspaceChanged }
    }
    private static func publish(_ next: Workspace, session: inout LocalSession, store: any WorkspacePersistence) throws {
        try current(session, store: store)
        try session.commit(next, store: store)
    }
    public static func save(_ transaction: CredentialImportTransaction, persistCredentials: Bool,
                            session: inout LocalSession, store: any WorkspacePersistence,
                            vault: any CredentialVault) throws {
        try current(session, store: store)
        // Validate baseline, limits and final profile BEFORE any vault or journal write.
        _ = try transaction.applying(to: session.workspace, reference: nil)
        if !persistCredentials {
            let next = try transaction.applying(to: session.workspace, reference: nil)
            try publish(next, session: &session, store: store)
            session.select(transaction.profileID)
            return
        }
        guard session.workspace.cleanupQueue.isEmpty else { throw CredentialError.pendingCleanup }
        let reference = CredentialReference(profileID: transaction.profileID)
        var staged = session.workspace
        staged.enqueueCleanup(reference)
        try publish(staged, session: &session, store: store)
        // On any following failure the staged reference remains visible for explicit recovery.
        try vault.create(transaction.material, reference: reference)
        try vault.verify(reference: reference, metadata: transaction.metadata)
        var committed = session.workspace
        committed.pendingCredentialCleanup = nil
        committed = try transaction.applying(to: committed, reference: reference)
        try publish(committed, session: &session, store: store)
        session.select(transaction.profileID)
    }

    public static func remove(profileID: UUID, deleteProfile: Bool, removeMetadata: Bool,
                              session: inout LocalSession, store: any WorkspacePersistence) throws {
        try current(session, store: store)
        var next = session.workspace
        guard let index = next.profiles.firstIndex(where: { $0.id == profileID }) else { throw DraftEditError.missing }
        let reference = next.profiles[index].credential
        if deleteProfile { next.profiles.remove(at: index) }
        else {
            next.profiles[index].credential = nil
            if removeMetadata { next.profiles[index].wireGuard = nil }
        }
        if let reference { next.enqueueCleanup(reference) }
        // Never remove a vault item before persistence accepts the unlink.
        // This orders ordinary process-crash recovery; it is not a power-loss guarantee.
        try publish(next, session: &session, store: store)
    }

    /// Must be explicitly requested; never called automatically at application startup.
    public static func cleanup(session: inout LocalSession, store: any WorkspacePersistence,
                               vault: any CredentialVault, only: CredentialReference? = nil) throws {
        try current(session, store: store)
        for reference in session.workspace.cleanupQueue where only == nil || reference == only {
            try current(session, store: store)
            guard !session.workspace.profiles.contains(where: { $0.credential?.id == reference.id }) else {
                throw CredentialError.ownership
            }
            try vault.removeOwned(reference: reference)
            var next = session.workspace
            let remaining = next.cleanupQueue.filter { $0 != reference }
            next.pendingCredentialCleanup = remaining.isEmpty ? nil : remaining
            // If acknowledgement fails, missing-item handling makes the retry idempotent.
            try publish(next, session: &session, store: store)
        }
    }
}

extension Workspace {
    public var cleanupQueue: [CredentialReference] { pendingCredentialCleanup ?? [] }
    mutating func enqueueCleanup(_ reference: CredentialReference) {
        schemaVersion = 3
        var queue = cleanupQueue
        if !queue.contains(reference) { queue.append(reference) }
        pendingCredentialCleanup = queue
    }
    func validateCredentials() throws {
        let active = profiles.compactMap(\.credential)
        let all = active + cleanupQueue
        guard all.isEmpty || schemaVersion == 3,
              cleanupQueue.count <= 200, Set(all.map(\.id)).count == all.count else { throw DraftError.invalidDraft }
        for profile in profiles {
            if let reference = profile.credential {
                guard reference.profileID == profile.id, profile.backend == .wireGuard, profile.wireGuard != nil else {
                    throw DraftError.invalidDraft
                }
            }
        }
    }
}
