// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

public struct PolicyPreview: Sendable {
    public let plan: IPv4PolicyPlan
    public let profileID: UUID
    public let constrainedPlan: ConstrainedIPv4PolicyPlan?
    public var boundaryText: String { constrainedPlan == nil ? Self.boundary : WireGuardPlanning.boundary }
    public var overrides: [CompiledIPv4Route] { constrainedPlan?.overrides ?? plan.overrides }
    public static let boundary = "仅规则意图预览；未检查基础设施/peer，未解析 DNS，未验证出口。IPv6 未覆盖，无 Kill Switch。"

    public static func compile(_ profile: ProfileDraft) throws -> Self {
        try Workspace(profiles: [profile], schemaVersion: profile.credential != nil ? 3 : (profile.wireGuard == nil ? 1 : 2)).validate()
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
        let policy = IPv4Policy(defaultAction: profile.defaultAction.policyAction, rules: rules)
        let constrained = try profile.wireGuard.map { try WireGuardPlanning.compile(policy, metadata: $0, context: context) }
        let plan = try constrained?.userIntent ?? IPv4PolicyCompiler.compile(policy, capabilities: capabilities, context: context)
        return Self(plan: plan, profileID: profile.id, constrainedPlan: constrained)
    }

    public var text: String {
        var lines = [boundaryText, "", "默认：\(plan.defaultAction.rawValue)", "例外路由（未安装）："]
        lines += overrides.map { "\($0.cidr) → \($0.action.rawValue)" }
        if overrides.isEmpty { lines.append("无") }
        if let constrainedPlan {
            lines.append("\n默认策略的配置基础设施例外（不是用户规则改写）：")
            for item in constrainedPlan.infrastructureEvaluations where !item.defaultExceptionCIDRs.isEmpty {
                lines.append("\(item.requirement.id)：\(item.defaultExceptionCIDRs.map(\.description).joined(separator: ", ")) → \(item.requirement.role.requiredAction.rawValue)")
            }
            lines.append("\nVPN 区域的 Peer 分配（不证明可达）：")
            lines += constrainedPlan.peerAssignments.map { "\($0.cidr) → \($0.peerID)" }
        }
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
        if let constrainedPlan {
            let decision = constrainedPlan.decision(for: address)
            let peer = decision.wireGuardPeerID.map { "；Peer：\($0)" } ?? ""
            let infrastructure = decision.infrastructureIDs.isEmpty ? "" : "；配置约束：" + decision.infrastructureIDs.joined(separator: ", ")
            return "用户规则预期 \(result.action.rawValue)；命中\(source)。配置约束后预期 \(decision.action.rawValue)\(peer)\(infrastructure)。仅配置提供的拓扑，未探测真实出口。"
        }
        return "预期 \(result.action.rawValue)；命中\(source)。未发起连接探测。"
    }

    /// Never stringify arbitrary errors or user-supplied selectors into diagnostics.
    public static func errorText(_ error: any Error) -> String {
        if let error = error as? WGImportError { return error.code.rawValue }
        if let error = error as? DraftError { return error.rawValue }
        if let error = error as? PolicyCompilationError {
            return error.diagnostics.map { "\($0.code.rawValue)：\($0.reason)" }.joined(separator: "\n")
        }
        return "E_LOCALDEV_OPERATION"
    }
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
        if selectedID != id { selectedID = id; invalidate(reason: .selectionChanged) }
    }
    public mutating func invalidate(reason: SimulationNote = .interrupted) {
        preview = nil; connection.cancel(reason: reason)
    }
    public mutating func commit(_ next: Workspace, store: any WorkspacePersistence) throws {
        try store.save(next)
        workspace = next
        if !workspace.profiles.contains(where: { $0.id == selectedID }) {
            selectedID = workspace.profiles.first?.id
        }
        invalidate(reason: .configurationChanged)
    }
    public mutating func compile() throws {
        invalidate(reason: .rechecked)
        guard let profile else { throw DraftError.noProfile }
        preview = try PolicyPreview.compile(profile)
    }
    public mutating func beginSimulation() throws -> UUID {
        guard connection.canStart else { throw SimulationCommandError.alreadyActive }
        preview = nil; connection.prepare()
        do {
            guard let profile else { throw DraftError.noProfile }
            let compiled = try PolicyPreview.compile(profile)
            preview = compiled
            let token = connection.begin()
            connection.bind(profileID: profile.id, context: compiled.plan.context)
            return token
        } catch {
            connection.rejectPolicy()
            throw error
        }
    }

    @discardableResult
    public mutating func receiveSimulation(_ signal: SimulationSignal, attempt: SimulationAttempt) -> Bool {
        guard selectedID == attempt.profileID, let preview, preview.profileID == attempt.profileID,
              preview.plan.context.check(against: attempt.context) == .current else { return false }
        return connection.receive(signal, attempt: attempt)
    }

    public mutating func finishSimulation(token: UUID, success: Bool) {
        guard let attempt = connection.attempt, attempt.id == token else { return }
        receiveSimulation(success ? .connected : .authenticationFailed, attempt: attempt)
    }

    public mutating func requestSimulationStop() -> UUID? { connection.requestStop() }
    @discardableResult
    public mutating func finishSimulationStop(token: UUID) -> Bool { connection.finishStop(token: token) }
    public mutating func cancelSimulation(reason: SimulationNote = .interrupted) { connection.cancel(reason: reason) }
    public mutating func clearSimulationHistory() { connection.clearHistory() }
}
