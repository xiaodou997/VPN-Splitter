// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

public struct PolicyPreview: Sendable {
    public let plan: IPv4PolicyPlan
    public let profileID: UUID
    public static let boundary = "仅规则意图预览；未检查基础设施/peer，未解析 DNS，未验证出口。IPv6 未覆盖，无 Kill Switch。"

    public static func compile(_ profile: ProfileDraft) throws -> Self {
        try Workspace(profiles: [profile]).validate()
        let rules = try profile.rules.map { rule -> PolicyRule in
            let match: RuleMatch
            if !rule.enabled {
                // Invalid disabled drafts must remain editable; never execute them.
                match = .unsupported(type: rule.match.rawValue, value: "")
            } else {
                switch rule.match {
                case .ipv4:
                    let text = rule.value.trimmingCharacters(in: .whitespaces)
                    do { match = .ipv4(try IPv4CIDR(text.contains("/") ? text : text + "/32")) }
                    catch { throw DraftError.invalidIPv4 }
                case .domain: match = .domain(rule.value)
                case .suffix: match = .domainSuffix(rule.value)
                case .ipv6: match = .ipv6CIDR(rule.value)
                }
            }
            return PolicyRule(id: rule.id.uuidString, match: match,
                              action: rule.action.policyAction, enabled: rule.enabled)
        }
        let capabilities = profile.backend.capabilities
        let context = PlanContext(sessionID: UUID().uuidString, backendID: capabilities.backendID,
                                  generation: 0, networkEpoch: 0)
        let plan = try IPv4PolicyCompiler.compile(
            IPv4Policy(defaultAction: profile.defaultAction.policyAction, rules: rules),
            capabilities: capabilities, context: context)
        return Self(plan: plan, profileID: profile.id)
    }

    public var text: String {
        var lines = [Self.boundary, "", "默认：\(plan.defaultAction.rawValue)", "例外路由（未安装）："]
        lines += plan.overrides.map { "\($0.cidr) → \($0.action.rawValue)" }
        if plan.overrides.isEmpty { lines.append("无") }
        lines.append("\n按列表顺序评估：")
        for (index, item) in plan.ruleEvaluations.enumerated() {
            let effect: String
            switch item.effect {
            case .disabled: effect = "已禁用"
            case .fullyShadowed: effect = "完全被前序规则遮蔽"
            case .partiallyShadowed: effect = "部分被前序规则遮蔽"
            case .effective: effect = "有效"
            }
            lines.append("规则 \(index + 1)：\(effect)；有效 IPv4 地址数 \(item.effectiveAddressCount)")
        }
        return lines.joined(separator: "\n")
    }

    public func explain(_ text: String) throws -> String {
        let address: IPv4Address
        do { address = try IPv4Address(text.trimmingCharacters(in: .whitespaces)) }
        catch { throw DraftError.invalidIPv4 }
        let result = plan.decision(for: address)
        let source: String
        switch result.origin {
        case .defaultPolicy: source = "默认策略"
        case .rule(let id):
            let index = plan.ruleEvaluations.firstIndex { $0.ruleID == id }
            source = "规则 \((index ?? -1) + 1)"
        }
        return "预期 \(result.action.rawValue)；命中\(source)。未发起连接探测。"
    }

    /// Never stringify arbitrary errors or user-supplied selectors into diagnostics.
    public static func errorText(_ error: any Error) -> String {
        if let error = error as? DraftError { return error.rawValue }
        if let error = error as? PolicyCompilationError {
            return error.diagnostics.map { "\($0.code.rawValue)：\($0.reason)" }.joined(separator: "\n")
        }
        return "E_LOCALDEV_OPERATION"
    }
}

public enum MockState: String, Sendable {
    case idle = "模拟：未开始（真实网络未接管）"
    case connecting = "模拟：连接中（真实网络未接管）"
    case connected = "模拟：连接成功（不代表 VPN 已连接）"
    case failed = "模拟：认证失败（注入的测试故障）"
}

/// Tokens fence late completions after cancellation, edits and reconnects.
/// There are intentionally no network APIs or real-connected states here.
public struct MockConnection: Sendable {
    public private(set) var state: MockState = .idle
    private var token: UUID?
    public init() {}
    public mutating func begin() -> UUID {
        let next = UUID(); token = next; state = .connecting
        return next
    }
    public mutating func finish(token: UUID, success: Bool) {
        guard self.token == token, state == .connecting else { return }
        self.token = nil
        state = success ? .connected : .failed
    }
    public mutating func cancel() { token = nil; state = .idle }
}

/// UI-independent state shared by all LocalDev windows. Only workspace is persisted.
public struct LocalSession: Sendable {
    public private(set) var workspace: Workspace
    public private(set) var selectedID: UUID?
    public private(set) var preview: PolicyPreview?
    public private(set) var connection = MockConnection()
    public var profile: ProfileDraft? { workspace.profiles.first { $0.id == selectedID } }

    public init(workspace: Workspace) {
        self.workspace = workspace; self.selectedID = workspace.profiles.first?.id
    }
    public mutating func select(_ id: UUID?) {
        guard id == nil || workspace.profiles.contains(where: { $0.id == id }) else { return }
        if selectedID != id { selectedID = id; invalidate() }
    }
    public mutating func invalidate() { preview = nil; connection.cancel() }
    public mutating func commit(_ next: Workspace, store: DraftStore) throws {
        try store.save(next)
        workspace = next
        if !workspace.profiles.contains(where: { $0.id == selectedID }) {
            selectedID = workspace.profiles.first?.id
        }
        invalidate()
    }
    public mutating func compile() throws {
        invalidate()
        guard let profile else { throw DraftError.noProfile }
        preview = try PolicyPreview.compile(profile)
    }
    public mutating func beginSimulation() throws -> UUID {
        try compile()
        return connection.begin()
    }
    public mutating func finishSimulation(token: UUID, success: Bool) {
        connection.finish(token: token, success: success)
    }
    public mutating func cancelSimulation() { connection.cancel() }
}
