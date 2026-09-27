// SPDX-License-Identifier: MIT
import Foundation
import ExternalCore
import ExternalExecution
import CExternalRoute
#if os(macOS)
import Darwin
#endif

/// Explicit foreground engineering tool, NOT a daemon/XPC fallback for the GUI.
/// Building or launching with no arguments never changes networking. No automatic
/// privilege escalation, shell commands, arbitrary file requests or secret inputs.
@main
struct ExternalLeaseMain {
    static func main() {
        #if os(macOS)
        let code = run(Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(code)
        #else
        print("E_PLATFORM: the External foreground executor requires macOS 26+ arm64; network=NOT_APPLIED")
        #endif
    }
    #if os(macOS)
    private static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else { usage(); return 0 }
        if command == "--help" { usage(); return 0 }
        guard ["inspect", "apply", "audit", "clear-absent-marker"].contains(command), arguments.count <= 9,
              arguments.allSatisfy({ $0.utf8.count <= 64 }) else { usage(); return 64 }
        do {
            if command == "audit" || command == "clear-absent-marker" {
                guard arguments.count == 1 else { usage(); return 64 }
                let journal = try ExternalLeaseFileJournal.foregroundHost()
                let candidates = try journal.auditCandidates()
                let observed = try ExternalSystemSnapshotReader().capture()
                let present = candidates.filter { item in observed.routes.contains { row in
                    row.destination.prefixLength >= item.destination.prefixLength && item.destination.contains(row.destination.networkAddress)
                } }
                print("audit_candidates=\(candidates.count) present_or_ambiguous=\(present.count) route_writes=NONE")
                if command == "clear-absent-marker" {
                    try journal.clearAuditedAbsence(routes: candidates, observation: observed, uptime: ProcessInfo.processInfo.systemUptime)
                    print("journal_marker=CLEARED_AFTER_ABSENCE; routes_and_dns=NOT_MODIFIED")
                }
                return present.isEmpty ? 0 : 2
            }
            guard arguments.count >= 2 else { usage(); return 64 }
            if command == "apply" {
                guard getuid() == 0, geteuid() == 0, isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                    throw ExternalLeaseFailure.consentRequired
                }
            }
            let observed = try ExternalSystemSnapshotReader().capture()
            let plan = try ExternalLeasePlan.prepare(rules: arguments.dropFirst().joined(separator: "\n"),
                observation: observed, uptime: ProcessInfo.processInfo.systemUptime, clock: er_continuous_seconds())
            print("External IPv4 Bypass · 60 秒前台实验；没有验证实际出口。")
            print("物理接口：\(plan.preview.topology.physical.interface)；原 VPN 接口线索：\(plan.preview.topology.tunnelInterface)")
            for proposal in plan.preview.proposals {
                print("\(proposal.destination) → \(proposal.gateway) / \(proposal.interface) · \(proposal.disposition.rawValue)")
            }
            guard command == "apply" else { print("network_settings=NOT_APPLIED"); return 0 }
            // Lock/marker and native socket are owned by this process; no IPC caller can
            // provide a plan, receipt, gateway or interface on the root execution path.
            let journal = try ExternalLeaseFileJournal.foregroundHost()
            let driver = try NativeExternalRouteDriver(tunnel: plan.preview.topology.tunnelInterface)
            er_install_stop_handlers()
            print("将添加上列直连例外；不改 DNS、不停止原 VPN。只适用于无路由争用的本机受控测试。")
            print("异常退出/强制终止不能保证自动清理；存在原生 compare/delete 竞争窗口。")
            print("30 秒内输入 APPLY 并回车才开始；回车、Ctrl-C、租约到期或网络变化会请求撤销：")
            fflush(nil)
            guard er_console_confirm() == 1 else { print("cancelled=BEFORE_WRITES"); return 0 }
            let session = ExternalLeaseTransaction(plan: plan, driver: driver, journal: journal,
                now: { er_continuous_seconds() }, cancelled: { er_stop_requested() != 0 })
            session.start(consent: true)
            if session.state == .active {
                print("route_add_ack_and_readback=PASS; traffic_paths=NOT_VERIFIED; dns_writes=NONE")
                while session.state == .active {
                    if er_console_poll() != 0 { session.stop(); break }
                    session.poll()
                }
            }
            session.stop()
            print("state=\(session.state.rawValue) owned_receipts_remaining=\(session.ownedCount) snapshot_comparison=\(session.postObservation.rawValue)")
            print("traffic_paths=NOT_VERIFIED; no_system_restore_guarantee=true")
            if let failure = session.failure { print("failure=\(failure.rawValue)") }
            return session.state == .closed && session.failure == nil ? 0 : 2
        } catch {
            let code = (error as? ExternalLeaseFailure)?.rawValue ?? (error as? ExternalError)?.rawValue ?? "unavailable"
            print("External operation stopped: \(code). No automatic retry, privilege escalation, route flush or DNS fallback.")
            return 2
        }
    }
    #endif
    private static func usage() {
        print("""
        VPNExternalLease inspect <IPv4/CIDR> ...  只读检查，不申请权限
        VPNExternalLease apply <IPv4/CIDR> ...    需要本机管理员启动及终端 APPLY 确认；最多 8 项 /24–/32、60 秒
        VPNExternalLease audit                   管理员只读核查崩溃遗留标记；不删除路由
        VPNExternalLease clear-absent-marker     仅在全部候选及更具体路由均不存在时删除本工具标记；不改网络
        此工具不是一键 GUI Helper，不使用 WG 签名，也不绕过企业强制策略。不要用 sudo 构建或启动预览 GUI。
        """)
    }
}
