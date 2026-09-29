// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

/// Local rule documents only: never persist a gateway, network snapshot, receipt or authority.
public enum ExternalProfileError: String, Error, Sendable {
    case invalidName, invalidRules, ruleNeedsFlowBackend, limitExceeded, invalidDocument, unsupportedVersion
    case missingProfile, unsavedChanges, staleRevision, busy, unsafeStorage, readFailed, writeFailed, saveUncertain
    public var message: String {
        switch self {
        case .invalidName: return "方案名称须为 1–64 个字符，且不能包含控制字符。"
        case .invalidRules: return "规则格式无效；请检查 IP/CIDR、域名或应用名称。"
        case .ruleNeedsFlowBackend: return "当前方案含域名/应用规则；现有 Route Bypass 不能按来源应用或动态域名安全执行。"
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

public enum ExternalSavedRuleKind: String, Codable, CaseIterable, Sendable {
    case ipCIDR = "IP-CIDR"
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case application = "APPLICATION"

    public var requiresFlowBackend: Bool { self != .ipCIDR }
    public var displayName: String {
        switch self {
        case .ipCIDR: return "IP / CIDR"
        case .domain: return "完整域名"
        case .domainSuffix: return "域名后缀"
        case .domainKeyword: return "域名关键字"
        case .application: return "应用名称"
        }
    }
}

public struct ExternalSavedRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: ExternalSavedRuleKind
    public var target: String
    public var applicationIdentifier: String?
    public var enabled: Bool
    public init(id: UUID = UUID(), kind: ExternalSavedRuleKind = .ipCIDR, target: String,
                applicationIdentifier: String? = nil, enabled: Bool = true) {
        self.id = id; self.kind = kind; self.target = target
        self.applicationIdentifier = applicationIdentifier; self.enabled = enabled
    }
    private enum CodingKeys: String, CodingKey { case id, kind, target, applicationIdentifier, enabled }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(ExternalSavedRuleKind.self, forKey: .kind) ?? .ipCIDR
        target = try container.decode(String.self, forKey: .target)
        applicationIdentifier = try container.decodeIfPresent(String.self, forKey: .applicationIdentifier)
        enabled = try container.decode(Bool.self, forKey: .enabled)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id); try container.encode(kind, forKey: .kind)
        try container.encode(target, forKey: .target)
        try container.encodeIfPresent(applicationIdentifier, forKey: .applicationIdentifier)
        try container.encode(enabled, forKey: .enabled)
    }
    public func validated() throws -> Self {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ExternalProfileError.invalidRules
        }
        switch kind {
        case .ipCIDR:
            guard trimmed.utf8.count <= 18,
                  let cidr = try? IPv4CIDR(trimmed.contains("/") ? trimmed : trimmed + "/32") else {
                throw ExternalProfileError.invalidRules
            }
            return Self(id: id, kind: kind, target: cidr.description, applicationIdentifier: nil, enabled: enabled)
        case .domain:
            guard let value = Self.normalizedDomain(trimmed, suffix: false) else { throw ExternalProfileError.invalidRules }
            return Self(id: id, kind: kind, target: value, applicationIdentifier: nil, enabled: enabled)
        case .domainSuffix:
            guard let value = Self.normalizedDomain(trimmed, suffix: true) else { throw ExternalProfileError.invalidRules }
            return Self(id: id, kind: kind, target: value, applicationIdentifier: nil, enabled: enabled)
        case .domainKeyword:
            let value = trimmed.lowercased()
            guard (1...64).contains(value.utf8.count), value.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
            }) else { throw ExternalProfileError.invalidRules }
            return Self(id: id, kind: kind, target: value, applicationIdentifier: nil, enabled: enabled)
        case .application:
            guard (1...128).contains(trimmed.count), trimmed.utf8.count <= 512 else {
                throw ExternalProfileError.invalidRules
            }
            if let identifier = applicationIdentifier {
                guard Self.validApplicationIdentifier(identifier) else { throw ExternalProfileError.invalidRules }
                return Self(id: id, kind: kind, target: trimmed,
                            applicationIdentifier: identifier, enabled: enabled)
            }
            return Self(id: id, kind: kind, target: trimmed, applicationIdentifier: nil, enabled: enabled)
        }
    }
    private static func validApplicationIdentifier(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }
    private static func normalizedDomain(_ text: String, suffix: Bool) -> String? {
        var value = text.lowercased()
        if suffix && value.hasPrefix("*.") { value.removeFirst(2) }
        while value.hasSuffix(".") { value.removeLast() }
        guard (1...253).contains(value.utf8.count), !value.contains("..") else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...122).contains(byte) || byte == 45
                  }) else { return nil }
        }
        return value
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
    public var enabledRules: [ExternalSavedRule] { rules.filter(\.enabled) }
    public var hasEnabledFlowRules: Bool { enabledRules.contains { $0.kind.requiresFlowBackend } }
    public var enabledRulesText: String { (try? routeExecutionRulesText()) ?? "" }
    public func routeExecutionRulesText() throws -> String {
        let enabled = enabledRules
        guard !enabled.isEmpty else { return "" }
        guard enabled.allSatisfy({ $0.kind == .ipCIDR }) else { throw ExternalProfileError.ruleNeedsFlowBackend }
        return enabled.map(\.target).joined(separator: "\n")
    }
    public mutating func appendBatch(_ text: String) throws {
        guard text.utf8.count <= 16_384 else { throw ExternalProfileError.limitExceeded }
        let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 64 - rules.count else { throw ExternalProfileError.limitExceeded }
        let additions = try lines.map { line -> ExternalSavedRule in
            let fields = line.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if fields.count == 1 { return try ExternalSavedRule(target: fields[0]).validated() }
            let token = fields[0].trimmingCharacters(in: .whitespaces).uppercased()
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            let kind: ExternalSavedRuleKind
            switch token {
            case "IP", "IP-CIDR": kind = .ipCIDR
            case "DOMAIN": kind = .domain
            case "DOMAIN-SUFFIX": kind = .domainSuffix
            case "DOMAIN-KEYWORD": kind = .domainKeyword
            case "APP", "APPLICATION": kind = .application
            default: throw ExternalProfileError.invalidRules
            }
            return try ExternalSavedRule(kind: kind, target: value).validated()
        }
        rules += additions
    }
    public mutating func move(_ id: UUID, by delta: Int) {
        guard delta == -1 || delta == 1, let index = rules.firstIndex(where: { $0.id == id }),
              rules.indices.contains(index + delta) else { return }
        rules.swapAt(index, index + delta)
    }
    public func duplicated(name: String) -> Self {
        Self(name: name, rules: rules.map {
            ExternalSavedRule(kind: $0.kind, target: $0.target,
                              applicationIdentifier: $0.applicationIdentifier, enabled: $0.enabled)
        })
    }
}

public struct ExternalProfileWorkspace: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let schema = "external-profiles-v2"
    public static let legacySchema = "external-profiles-v1"
    public let format: String
    public var revision: UUID?
    public var profiles: [ExternalSavedProfile]
    public var selectedID: UUID?
    public init(revision: UUID? = nil, profiles: [ExternalSavedProfile] = [], selectedID: UUID? = nil) {
        format = Self.schema; self.revision = revision; self.profiles = profiles; self.selectedID = selectedID
    }
    private enum CodingKeys: String, CodingKey { case format, revision, profiles, selectedID }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let source = try container.decode(String.self, forKey: .format)
        guard source == Self.schema || source == Self.legacySchema else { throw ExternalProfileError.unsupportedVersion }
        format = Self.schema
        revision = try container.decodeIfPresent(UUID.self, forKey: .revision)
        profiles = try container.decode([ExternalSavedProfile].self, forKey: .profiles)
        selectedID = try container.decodeIfPresent(UUID.self, forKey: .selectedID)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .format)
        try container.encodeIfPresent(revision, forKey: .revision)
        try container.encode(profiles, forKey: .profiles)
        try container.encodeIfPresent(selectedID, forKey: .selectedID)
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
        return result
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
