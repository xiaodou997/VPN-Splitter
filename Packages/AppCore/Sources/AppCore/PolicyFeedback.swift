// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

/// Localized, bounded explanations. No arbitrary Error descriptions or input echo.
public struct CheckIssue: Equatable, Sendable {
    public let ruleID: UUID?
    public let text: String
    public let code: String
}

public enum PolicyFeedback {
    public static func mode(_ action: DraftAction) -> String {
        switch action {
        case .direct: "仅指定目标走 VPN"
        case .vpn: "除指定目标外走 VPN"
        case .reject: "未支持的默认动作：阻止"
        }
    }

    public static func action(_ action: DraftAction) -> String {
        switch action {
        case .direct: "直连"
        case .vpn: "走 VPN"
        case .reject: "阻止（未支持）"
        }
    }

    public static func ruleHint(_ rule: DraftRule) -> String? {
        if rule.match != .ipv4 || rule.action == .reject {
            return rule.enabled ? "含未支持的类型或动作：请修改或禁用，否则无法检查。" : "未支持的草稿，已禁用；不会参与检查。"
        }
        guard rule.enabled else { return nil }
        return validIPv4Rule(rule) ? nil : "请填写 IPv4 地址或网段，如 198.51.100.7 或 198.51.100.0/24。"
    }

    private static func validIPv4Rule(_ rule: DraftRule) -> Bool {
        let value = rule.value.trimmingCharacters(in: .whitespaces)
        return (try? IPv4CIDR(value.contains("/") ? value : value + "/32")) != nil
    }

    public static func message(_ error: any Error) -> String {
        if let error = error as? SimulationCommandError { return error.message }
        if let error = error as? WGParameterError { return error.message }
        if let error = error as? RuleBatchError { return error.message }
        if let error = error as? CredentialError { return error.message }
        if let error = error as? WGImportError { return error.message }
        if let error = error as? DraftEditError {
            switch error {
            case .alreadyEditing: return "请先保存或取消当前编辑，再进行其他操作。"
            case .conflict: return "该策略已发生变化，未覆盖新数据。请保留需要的输入，取消后重新编辑。"
            case .missing: return "编辑对象已不存在，未重新创建或覆盖数据。请取消后重新选择。"
            }
        }
        guard let error = error as? DraftError else { return "操作未完成，请检查策略；原始错误不会显示在这里。" }
        switch error {
        case .invalidIPv4: return "地址格式不正确，请填写 IPv4 地址，如 198.51.100.7。"
        case .invalidDraft: return "草稿格式不正确。名称不能为空，字段须为单行，名称不超过 160 字节，目标不超过 255 字节。"
        case .tooLarge: return "超过本地草稿上限：100 份策略、每份 1000 条规则、总计 2 MiB。"
        case .unsupportedVersion: return "草稿版本不受支持，请保留原文件，不要重置数据。"
        case .readFailed: return "无法读取草稿。为保护原文件，已禁止写入，请按操作文档恢复。"
        case .writeFailed: return "保存失败，输入仍保留。请检查本地目录权限和磁盘空间后重试。"
        case .noProfile: return "请先选择或新建一份策略。"
        }
    }

    public static func issues(_ error: any Error, profile: ProfileDraft) -> [CheckIssue] {
        if let error = error as? WGImportError, error.code == .planning, let metadata = profile.wireGuard {
            return metadata.compatibilityIssues.filter(\.blocksPlanning).map {
                CheckIssue(ruleID: nil, text: $0.message, code: $0.code)
            }
        }
        if let draftError = error as? DraftError, draftError == .invalidIPv4 {
            return profile.rules.enumerated().compactMap { index, rule in
                guard rule.enabled, rule.match == .ipv4, !validIPv4Rule(rule) else { return nil }
                return CheckIssue(ruleID: rule.id, text: "第 \(index + 1) 条规则：IPv4 地址或网段格式不正确，请编辑该规则。",
                                  code: DraftError.invalidIPv4.rawValue)
            }
        }
        if let compilation = error as? PolicyCompilationError {
            return compilation.diagnostics.map { diagnostic in
                let position = profile.rules.firstIndex { $0.id.uuidString == diagnostic.ruleID }
                let ruleID = position.map { profile.rules[$0].id }
                let prefix = position.map { "第 \($0 + 1) 条规则：" } ?? "策略设置："
                let reason: String
                switch diagnostic.reason {
                case "domain_requires_s2", "suffix_requires_s2": reason = "域名规则尚未实现，请修改为 IP / 网段或禁用此草稿。"
                case "ipv6_unavailable": reason = "IPv6 尚未覆盖，请禁用此草稿；不表示系统 IPv6 流量已受保护。"
                case "reject_action_unavailable", "reject_default_unavailable": reason = "阻止动作尚未支持，请改为直连 / VPN，或禁用规则。"
                case "vpn_region_outside_allowed_ips": reason = "走 VPN 的范围超出配置 Peer 的 AllowedIPs（包括配置 DNS 所需范围）。请检查规则和原配置；不会自动扩大 AllowedIPs。"
                case "explicit_rule_conflicts_with_infrastructure": reason = "规则与配置中的端点直连、接口本机地址直连或 DNS 走 VPN 要求冲突。请调整显式规则；不会偷偷覆盖它。"
                case "contradictory_infrastructure": reason = "配置中的端点、DNS 或接口地址存在相反的出口要求，不能生成无歧义的约束计划。"
                case "ambiguous_peer_prefix": reason = "多个 Peer 声明了相同前缀；请在原配置中解决归属，不按配置顺序猜测。"
                case "policy_mode_unavailable": reason = "此能力预设不支持当前模式。External 仅允许“除指定目标外走 VPN”。"
                default: reason = "当前策略无法完成检查，请修改规则或查看错误码。"
                }
                return CheckIssue(ruleID: ruleID, text: prefix + reason, code: diagnostic.code.rawValue)
            }
        }
        return [CheckIssue(ruleID: nil, text: message(error), code: PolicyPreview.errorText(error))]
    }
}
