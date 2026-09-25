// SPDX-License-Identifier: MIT
import Foundation

public enum DraftEditError: String, Error, Sendable {
    case alreadyEditing = "E_EDIT_IN_PROGRESS"
    case conflict = "E_EDIT_CONFLICT"
    case missing = "E_EDIT_MISSING"
}

/// An in-memory transaction. Never persisted; no partial changes reach the workspace.
/// The complete profile baseline intentionally makes concurrent edits conservative.
public struct DraftEdit: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case settings, rule, batch, parameters }
    public let id = UUID()
    public let kind: Kind
    public let baseline: ProfileDraft
    public let initialRule: DraftRule
    public let isNewRule: Bool
    public var name: String
    public var backend: DraftBackend
    public var defaultAction: DraftAction
    public var rule: DraftRule
    public var parameters: WGParameterDraft?
    public var batchText = ""
    public var batchAction: DraftAction

    private init(profile: ProfileDraft, kind: Kind, rule: DraftRule, isNewRule: Bool) {
        baseline = profile; self.kind = kind; initialRule = rule
        self.rule = rule; self.isNewRule = isNewRule
        parameters = profile.wireGuard.map(WGParameterDraft.init)
        batchAction = profile.defaultAction == .vpn ? .direct : .vpn
        name = profile.name; backend = profile.backend; defaultAction = profile.defaultAction
    }

    public static func settings(_ profile: ProfileDraft) -> Self {
        Self(profile: profile, kind: .settings, rule: DraftRule(), isNewRule: false)
    }

    public static func rule(_ profile: ProfileDraft, id: UUID? = nil) throws -> Self {
        if let id {
            guard let rule = profile.rules.first(where: { $0.id == id }) else { throw DraftEditError.missing }
            return Self(profile: profile, kind: .rule, rule: rule, isNewRule: false)
        }
        let rule = DraftRule(action: profile.defaultAction == .vpn ? .direct : .vpn)
        return Self(profile: profile, kind: .rule, rule: rule, isNewRule: true)
    }

    public static func batch(_ profile: ProfileDraft) -> Self {
        Self(profile: profile, kind: .batch, rule: DraftRule(), isNewRule: false)
    }

    public static func parameterEdit(_ profile: ProfileDraft) throws -> Self {
        guard profile.backend == .wireGuard, let metadata = profile.wireGuard else { throw WGParameterError.missing }
        try metadata.validate()
        return Self(profile: profile, kind: .parameters, rule: DraftRule(), isNewRule: false)
    }

    public var hasChanges: Bool {
        switch kind {
        case .settings:
            name != baseline.name || backend != baseline.backend || defaultAction != baseline.defaultAction
        case .parameters: parameters != baseline.wireGuard.map(WGParameterDraft.init)
        case .rule: rule != initialRule
        case .batch: !batchText.isEmpty || batchAction != (baseline.defaultAction == .vpn ? .direct : .vpn)
        }
    }

    public func applying(to workspace: Workspace) throws -> Workspace {
        guard let index = workspace.profiles.firstIndex(where: { $0.id == baseline.id }) else {
            throw DraftEditError.missing
        }
        guard workspace.profiles[index] == baseline, rule.id == initialRule.id else {
            throw DraftEditError.conflict
        }
        var next = workspace
        switch kind {
        case .parameters: throw WGParameterError.transactionRequired
        case .settings:
            next.profiles[index].name = name
            next.profiles[index].backend = backend
            next.profiles[index].defaultAction = defaultAction
        case .batch:
            let batch = try IPv4RuleBatch.parse(batchText)
            next.profiles[index].rules = try batch.appending(to: baseline.rules, action: batchAction)
        case .rule:
            if isNewRule { next.profiles[index].rules.append(rule) }
            else {
                guard let position = next.profiles[index].rules.firstIndex(where: { $0.id == initialRule.id }) else {
                    throw DraftEditError.missing
                }
                next.profiles[index].rules[position] = rule
            }
        }
        try next.validate()
        return next
    }
}

/// One editor for the entire window. UI actions must honour allowsWorkspaceActions.
public struct DraftEditor: Sendable {
    public private(set) var edit: DraftEdit?
    public var allowsWorkspaceActions: Bool { edit == nil }
    public var hasUnsavedChanges: Bool { edit?.hasChanges == true }
    public init() {}

    public mutating func begin(_ value: DraftEdit) throws {
        guard edit == nil else { throw DraftEditError.alreadyEditing }
        edit = value
    }

    public mutating func update(id: UUID, _ change: (inout DraftEdit) -> Void) {
        guard var value = edit, value.id == id else { return }
        let identity = value.id
        change(&value)
        // Do not permit a callback to replace the transaction identity.
        if value.id == identity { edit = value }
    }

    @discardableResult
    public mutating func cancel(discardChanges: Bool = false) -> Bool {
        guard !hasUnsavedChanges || discardChanges else { return false }
        edit = nil
        return true
    }

    public mutating func save(session: inout LocalSession, store: DraftStore) throws {
        guard let edit else { throw DraftEditError.missing }
        guard session.selectedID == edit.baseline.id else { throw DraftEditError.conflict }
        let next = try edit.applying(to: session.workspace)
        // Preserve both the edit buffer and the accepted session on a failed save.
        if next != session.workspace { try session.commit(next, store: store) }
        self.edit = nil
    }
}
