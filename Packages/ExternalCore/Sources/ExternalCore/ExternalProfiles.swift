// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

/// Local rule documents only: never persist a gateway, network snapshot, receipt or authority.
public enum ExternalProfileError: String, Error, Sendable {
    case invalidName, invalidRules, limitExceeded, invalidDocument, unsupportedVersion
    case missingProfile, unsavedChanges, staleRevision, busy, unsafeStorage, readFailed, writeFailed, saveUncertain
    public var message: String {
        switch self {
        case .invalidName: return "方案名称须为 1–64 个字符，且不能包含控制字符。"
        case .invalidRules: return "规则须为 IPv4 地址或 CIDR；停用的规则也需要有效格式。"
        case .limitExceeded: return "最多保存 16 套方案，每套最多 64 条规则。"
        case .invalidDocument: return "本地方案文件损坏或不完整；未覆盖、未自动重置。"
        case .unsupportedVersion: return "本地方案由不兼容的版本保存；未降级覆盖。"
        case .missingProfile: return "所选方案已不存在，请重新载入。"
        case .unsavedChanges: return "存在未保存修改，请先保存或明确放弃。"
        case .staleRevision: return "方案文件已被其他窗口或进程更新；保留当前编辑，请重新载入后处理。"
        case .busy: return "另一项本地保存正在进行，请稍后再试。"
        case .unsafeStorage: return "方案存储路径或文件权限不符合要求；未读取或覆盖。"
        case .readFailed: return "无法完整读取方案；不会把读取失败当作空列表。"
        case .writeFailed: return "方案未保存；当前编辑仍保留。"
        case .saveUncertain: return "文件替换后无法确认保存完成；请重新载入，不自动重试覆盖。"
        }
    }
}

public struct ExternalSavedRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var target: String
    public var enabled: Bool
    public init(id: UUID = UUID(), target: String, enabled: Bool = true) {
        self.id = id; self.target = target; self.enabled = enabled
    }
    public func validated() throws -> Self {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 18, !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let cidr = try? IPv4CIDR(trimmed.contains("/") ? trimmed : trimmed + "/32") else {
            throw ExternalProfileError.invalidRules
        }
        // Normalization is explicit in the saved editor; never widen a route silently at execution.
        return Self(id: id, target: cidr.description, enabled: enabled)
    }
}

public struct ExternalSavedProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rules: [ExternalSavedRule]
    public init(id: UUID = UUID(), name: String, rules: [ExternalSavedRule] = []) {
        self.id = id; self.name = name; self.rules = rules
    }
    public func validated() throws -> Self {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(title.count), title.utf8.count <= 256,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ExternalProfileError.invalidName
        }
        guard rules.count <= 64 else { throw ExternalProfileError.limitExceeded }
        guard Set(rules.map(\.id)).count == rules.count else { throw ExternalProfileError.invalidDocument }
        return try Self(id: id, name: title, rules: rules.map { try $0.validated() })
    }
    /// Empty/all-disabled documents may be saved, but are not an executable plan.
    public var enabledRulesText: String { rules.filter(\.enabled).map(\.target).joined(separator: "\n") }
    public mutating func appendBatch(_ text: String) throws {
        guard text.utf8.count <= 16_384 else { throw ExternalProfileError.limitExceeded }
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 64 - rules.count else { throw ExternalProfileError.limitExceeded }
        let additions = try lines.map { try ExternalSavedRule(target: $0).validated() }
        rules += additions // All-or-nothing, preserving order and existing per-rule IDs.
    }
    public mutating func move(_ id: UUID, by delta: Int) {
        guard delta == -1 || delta == 1, let index = rules.firstIndex(where: { $0.id == id }),
              rules.indices.contains(index + delta) else { return }
        rules.swapAt(index, index + delta)
    }
    public func duplicated(name: String) -> Self {
        Self(name: name, rules: rules.map { ExternalSavedRule(target: $0.target, enabled: $0.enabled) })
    }
}

public struct ExternalProfileWorkspace: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let schema = "external-profiles-v1"
    public let format: String
    /// nil is allowed only for a missing file; persisted documents always get a fresh revision.
    public var revision: UUID?
    public var profiles: [ExternalSavedProfile]
    public var selectedID: UUID?
    public init(revision: UUID? = nil, profiles: [ExternalSavedProfile] = [], selectedID: UUID? = nil) {
        format = Self.schema; self.revision = revision; self.profiles = profiles; self.selectedID = selectedID
    }
    public var selected: ExternalSavedProfile? { profiles.first { $0.id == selectedID } }
    public func validated(persisted: Bool = false) throws -> Self {
        guard format == Self.schema else { throw ExternalProfileError.unsupportedVersion }
        guard profiles.count <= 16 else { throw ExternalProfileError.limitExceeded }
        guard Set(profiles.map(\.id)).count == profiles.count,
              selectedID == nil || profiles.contains(where: { $0.id == selectedID }),
              !persisted || revision != nil else { throw ExternalProfileError.invalidDocument }
        return try Self(revision: revision, profiles: profiles.map { try $0.validated() }, selectedID: selectedID)
    }
    public func replacing(_ draft: ExternalSavedProfile) throws -> Self {
        var value = self
        let profile = try draft.validated()
        if let index = value.profiles.firstIndex(where: { $0.id == profile.id }) { value.profiles[index] = profile }
        else { value.profiles.append(profile) }
        value.selectedID = profile.id
        return try value.validated()
    }
    public func selecting(_ id: UUID?) throws -> Self {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { throw ExternalProfileError.missingProfile }
        var result = self; result.selectedID = id; return result
    }
    public func deleting(_ id: UUID) throws -> Self {
        guard profiles.contains(where: { $0.id == id }) else { throw ExternalProfileError.missingProfile }
        var result = self; result.profiles.removeAll { $0.id == id }
        if result.selectedID == id { result.selectedID = nil }
        return result // No automatic selection or activation of a different profile.
    }
    public var description: String { "ExternalProfileWorkspace(<redacted>; rules-only)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}

/// Pure editor state. No network/Helper calls, and no implicit acceptance of a newer disk revision.
public struct ExternalProfileEditor: Sendable {
    public private(set) var workspace = ExternalProfileWorkspace()
    public private(set) var draft: ExternalSavedProfile?
    public private(set) var loaded = false
    public private(set) var mustReload = false
    private var original: ExternalSavedProfile?
    public init() {}
    public var isDirty: Bool { draft != original }
    public mutating func loaded(_ value: ExternalProfileWorkspace, discard: Bool = false) throws {
        guard !isDirty || discard else { throw ExternalProfileError.unsavedChanges }
        workspace = try value.validated(); loaded = true; mustReload = false
        original = workspace.selected; draft = original
    }
    public mutating func new(name: String = "新建方案", discard: Bool = false) throws {
        guard loaded, !mustReload else { throw ExternalProfileError.staleRevision }
        guard !isDirty || discard else { throw ExternalProfileError.unsavedChanges }
        guard workspace.profiles.count < 16 else { throw ExternalProfileError.limitExceeded }
        original = nil; draft = ExternalSavedProfile(name: name)
    }
    public mutating func edit(_ body: (inout ExternalSavedProfile) throws -> Void) throws {
        guard loaded, var value = draft else { throw ExternalProfileError.missingProfile }
        try body(&value); draft = value
    }
    public mutating func discarded() { original = workspace.selected; draft = original }
    public func candidate() throws -> ExternalProfileWorkspace {
        guard loaded, !mustReload else { throw ExternalProfileError.staleRevision }
        guard let draft else { throw ExternalProfileError.missingProfile }
        return try workspace.replacing(draft)
    }
    public mutating func saved(_ value: ExternalProfileWorkspace) throws {
        try loaded(value, discard: true)
    }
    public mutating func failed(_ error: ExternalProfileError) {
        if error == .staleRevision || error == .saveUncertain { mustReload = true }
    }
}
