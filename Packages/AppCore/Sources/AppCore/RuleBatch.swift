// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

/// Import errors identify a line, never echo its contents (which may be private).
public enum RuleBatchError: Error, Equatable, Sendable {
    case empty, inputLimit, ruleLimit, unsupportedAction
    case invalidIPv4(line: Int)

    public var message: String {
        switch self {
        case .empty: "请每行填写一个 IPv4 地址或网段；空行和以 # 开头的注释不算规则。"
        case .inputLimit: "批量输入不能超过 64 KiB，请拆成较小的批次。"
        case .ruleLimit: "保存后每份策略最多 1000 条规则；没有导入任何一条，请减少本批数量。"
        case .unsupportedAction: "批量添加只支持走 VPN 或直连，不支持阻止动作。"
        case .invalidIPv4(let line): "第 \(line) 行不是有效的 IPv4 地址或网段；请修正后再保存，没有导入任何一条。"
        }
    }
}

/// One target per line. Pure parsing: no file I/O, DNS, network, or workspace writes.
/// Order and duplicates are intentionally preserved to maintain first-match intent.
public struct IPv4RuleBatch: Equatable, Sendable {
    public static let byteLimit = 64 * 1024
    public let targets: [String]
    public let normalizedCount: Int
    public let duplicateCount: Int

    public static func parse(_ input: String) throws -> Self {
        guard input.utf8.count <= byteLimit else { throw RuleBatchError.inputLimit }
        var text = input
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var targets: [String] = []
        var normalized = 0
        var duplicates = 0
        var seen = Set<IPv4CIDR>()
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let value = rawLine.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("#") { continue }
            guard targets.count < CompilationLimits.ruleCeiling else { throw RuleBatchError.ruleLimit }
            let cidr: IPv4CIDR
            do { cidr = try IPv4CIDR(value.contains("/") ? value : value + "/32") }
            catch { throw RuleBatchError.invalidIPv4(line: index + 1) }
            let canonical = value.contains("/") ? cidr.description : cidr.networkAddress.description
            if canonical != value { normalized += 1 }
            if !seen.insert(cidr).inserted { duplicates += 1 }
            targets.append(canonical)
        }
        guard !targets.isEmpty else { throw RuleBatchError.empty }
        return Self(targets: targets, normalizedCount: normalized, duplicateCount: duplicates)
    }

    /// New IDs prevent a batch from replacing any existing rule. No implicit de-dup.
    public func appending(to existing: [DraftRule], action: DraftAction) throws -> [DraftRule] {
        guard action == .vpn || action == .direct else { throw RuleBatchError.unsupportedAction }
        guard existing.count <= CompilationLimits.ruleCeiling,
              targets.count <= CompilationLimits.ruleCeiling - existing.count else { throw RuleBatchError.ruleLimit }
        return existing + targets.map { DraftRule(value: $0, action: action) }
    }
}

/// A filtered display never becomes the source of compilation, sorting or saving.
public enum RuleSearch {
    public static func indices(in rules: [DraftRule], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(rules.indices) }
        return rules.indices.filter { index in
            let rule = rules[index]
            let fields = [rule.value, rule.match.rawValue, rule.action.rawValue,
                          PolicyFeedback.action(rule.action), rule.enabled ? "已启用" : "已禁用"]
            return fields.contains { $0.lowercased().contains(needle) }
        }
    }
}
