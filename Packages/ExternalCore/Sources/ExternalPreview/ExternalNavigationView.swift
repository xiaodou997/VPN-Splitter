// SPDX-License-Identifier: MIT
#if os(macOS)
import SwiftUI
import ExternalCore

enum ExternalSidebarSection: String, CaseIterable, Identifiable, Hashable {
    case overview, rules, session, recovery, flow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .rules: return "规则"
        case .session: return "分流会话"
        case .recovery: return "恢复"
        case .flow: return "Flow 实验"
        }
    }
    var systemImage: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .rules: return "list.bullet.rectangle"
        case .session: return "arrow.triangle.branch"
        case .recovery: return "cross.case"
        case .flow: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct ExternalRootView: View {
    @ObservedObject var model: ExternalModel
    @ObservedObject var profiles: ExternalProfilesModel
    @ObservedObject var helper: ExternalHelperModel
    @ObservedObject var flowBridge: ExternalFlowBridgeModel
    @ObservedObject var watchdog: ExternalWatchdogModel
    @Binding var selection: ExternalSidebarSection?

    var body: some View {
        NavigationSplitView {
            List(ExternalSidebarSection.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .navigationTitle("VPN-Splitter")
            .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 240)
        } detail: {
            VStack(spacing: 0) {
                if let alert = watchdog.activeAlert {
                    ExternalWatchdogAlertBanner(event: alert, watchdog: watchdog, helper: helper)
                }
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                if selection == .overview || selection == .session {
                    Button {
                        model.detect(previewRules: false)
                    } label: {
                        Label("检测网络", systemImage: "network")
                    }.disabled(model.busy)
                }
                if selection == .session {
                    Button {
                        preview()
                    } label: {
                        Label("预览规则", systemImage: "eye")
                    }.disabled(!canPreview)
                    Button {
                        helper.stop()
                    } label: {
                        Label("停止", systemImage: "stop.circle")
                    }
                }
                if selection == .recovery {
                    Button {
                        helper.auditRecovery()
                    } label: {
                        Label("核查恢复", systemImage: "stethoscope")
                    }.disabled(helper.busy)
                }
                if selection == .flow {
                    Button {
                        flowBridge.reload()
                    } label: {
                        Label("读取探针报告", systemImage: "arrow.clockwise")
                    }.disabled(flowBridge.busy)
                }
            }
        }
        .onChange(of: profiles.changeID, initial: true) { _, _ in
            model.cancel(); helper.invalidate(); model.rules = profiles.enabledRules
        }
        .onChange(of: profiles.batchText) { _, _ in
            model.cancel(); helper.invalidate()
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            ExternalOverviewPage(model: model, profiles: profiles, helper: helper, watchdog: watchdog, selection: $selection)
        case .rules:
            ExternalRulesPage(profiles: profiles)
        case .session:
            ExternalSessionPage(model: model, profiles: profiles, helper: helper)
        case .recovery:
            ExternalRecoveryPage(helper: helper)
        case .flow:
            ExternalFlowPage(profiles: profiles, flowBridge: flowBridge)
        }
    }

    private var canPreview: Bool {
        !model.busy && !profiles.busy && !profiles.editor.mustReload &&
        !profiles.hasUnsavedChanges && !profiles.enabledRules.isEmpty
    }
    func preview() {
        guard canPreview else { return }
        model.rules = profiles.enabledRules
        model.detect(previewRules: true)
    }
}

private struct ExternalPageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle).bold()
            Text(subtitle).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// ADR-EX-INT-08: VPN anomaly banner. Responses are explicit clicks only:
/// stopping the Helper session revokes applied route exceptions (recovery
/// semantics, never a blackhole); pausing the Flow relay requires the Flow
/// Probe App because this process holds no Network Extension session.
private struct ExternalWatchdogAlertBanner: View {
    let event: ExternalWatchdogEvent
    @ObservedObject var watchdog: ExternalWatchdogModel
    @ObservedObject var helper: ExternalHelperModel
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("VPN 状态异常：" + watchdog.eventSummary(event)).font(.headline)
                Text("可在此停止 Helper 分流会话（只撤销本工具添加的路由例外，不阻断联网）；Flow DIRECT relay 的暂停需在 Flow Probe App 点「暂停 DIRECT relay」，暂停后匹配的 TCP/UDP flow 会被关闭而不是直连。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("停止 Helper 分流会话") { helper.stop() }.disabled(helper.busy)
            Button("知道了") { watchdog.dismissAlert() }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.yellow.opacity(0.12))
    }
}

struct ExternalOverviewPage: View {
    @ObservedObject var model: ExternalModel
    @ObservedObject var profiles: ExternalProfilesModel
    @ObservedObject var helper: ExternalHelperModel
    @ObservedObject var watchdog: ExternalWatchdogModel
    @Binding var selection: ExternalSidebarSection?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ExternalPageHeader(title: "第三方 VPN 分流",
                    subtitle: "原 VPN 继续负责连接和认证；VPN-Splitter 只管理经过验证的 DIRECT 例外。")
                HStack(alignment: .top, spacing: 16) {
                    statusCard("规则方案", systemImage: "list.bullet.rectangle",
                               value: profiles.editor.workspace.selected?.name ?? "未选择",
                               detail: profiles.hasUnsavedChanges ? "存在未保存修改" :
                                "\(profiles.editor.draft?.enabledRules.count ?? 0) 条启用规则")
                    statusCard("网络", systemImage: "network",
                               value: model.observation == nil ? "未检测" : "已取得快照",
                               detail: model.message)
                    statusCard("Helper", systemImage: "lock.shield",
                               value: helper.registration,
                               detail: helper.cleanupUnconfirmed ? "有清理/恢复状态待确认" : "无未确认清理")
                }
                GroupBox("VPN 状态监测（只读）") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("状态") {
                            Text(watchdog.running ? "监测中 · \(watchdog.healthTitle)" :
                                 (watchdog.health != nil ? "已停止 · 最后判定：\(watchdog.healthTitle)" : "未监测"))
                        }
                        Text(watchdog.health != nil ? watchdog.healthDetail : watchdog.message)
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if !watchdog.events.isEmpty {
                            Divider()
                            ForEach(watchdog.events.prefix(8)) { record in
                                Text(watchdog.eventSummary(record.event)).font(.caption)
                            }
                        }
                        HStack {
                            if watchdog.running {
                                Button("停止监测") { watchdog.stop() }
                            } else {
                                Button("开始监测") { watchdog.start() }.buttonStyle(.borderedProminent)
                            }
                            Text("只读提示：不自动暂停规则、不撤销路由；睡眠/唤醒自动停止。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("检测当前网络") { model.detect(previewRules: false) }.disabled(model.busy)
                        .buttonStyle(.borderedProminent)
                    Button("编辑规则") { selection = .rules }
                    Button("进入分流会话") { selection = .session }
                    if helper.cleanupUnconfirmed { Button("处理恢复") { selection = .recovery } }
                }
                GroupBox("当前能力") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("IP/CIDR：Route Bypass 主线", systemImage: "checkmark.circle")
                        Label("域名 / 应用：Flow Bypass 开发中", systemImage: "flask")
                        Label("IPv6、系统级 Kill Switch、任意进程正则：当前不承诺", systemImage: "exclamationmark.triangle")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(ExternalCore.ExternalPreview.boundary).font(.footnote).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
    private func statusCard(_ title: String, systemImage: String, value: String, detail: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: systemImage).font(.headline)
                Text(value).font(.title3).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }.frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        }
    }
}

struct ExternalRulesPage: View {
    @ObservedObject var profiles: ExternalProfilesModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExternalPageHeader(title: "规则", subtitle: "按 IP、域名或应用组织 DIRECT 规则；保存规则本身不会修改网络。")
                ExternalProfilesPanel(profiles: profiles)
            }.padding(24)
        }
    }
}

struct ExternalSessionPage: View {
    @ObservedObject var model: ExternalModel
    @ObservedObject var profiles: ExternalProfilesModel
    @ObservedObject var helper: ExternalHelperModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExternalPageHeader(title: "分流会话",
                    subtitle: "先检测和预览，再由 Helper 重新核对并应用。不会断开原第三方 VPN。")
                HStack {
                    Button("检测网络（只读）") { model.detect(previewRules: false) }.disabled(model.busy)
                    Button("重新检测并预览") {
                        model.rules = profiles.enabledRules
                        model.detect(previewRules: true)
                    }.disabled(model.busy || profiles.busy || profiles.editor.mustReload ||
                               profiles.hasUnsavedChanges || profiles.enabledRules.isEmpty)
                    Button("清除本次检测") { model.cancel() }
                }
                Text(model.message).textSelection(.enabled)
                if let snapshot = model.observation {
                    GroupBox("网络快照") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("IPv4 路由 \(snapshot.routes.count) 条")
                            Text("物理路径：" + snapshot.physicalPaths.map { "\($0.interface) → \($0.gateway)" }.joined(separator: ", "))
                            Text("隧道候选：" + snapshot.interfaces.filter { $0.isUp && $0.isTunnelCandidate }.map(\.name).joined(separator: ", "))
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }
                }
                if let preview = model.preview {
                    GroupBox("路由预览 · 尚未应用") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("VPN：\(preview.topology.pattern.rawValue) / \(preview.topology.tunnelInterface)")
                            ForEach(preview.proposals) { item in
                                Text("\(String(describing: item.destination)) → \(String(describing: item.gateway)) / \(item.interface) · \(item.disposition.rawValue)")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                ExternalHelperSessionPanel(helper: helper, profiles: profiles)
            }.padding(24)
        }
    }
}

struct ExternalRecoveryPage: View {
    @ObservedObject var helper: ExternalHelperModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExternalPageHeader(title: "恢复",
                    subtitle: "只核查本工具留下的恢复记录；没有强制删路由、route flush 或恢复整张旧路由表。")
                ExternalRecoveryPanel(helper: helper)
            }.padding(24)
        }
    }
}

struct ExternalFlowPage: View {
    @ObservedObject var profiles: ExternalProfilesModel
    @ObservedObject var flowBridge: ExternalFlowBridgeModel
    private var flowRules: Int {
        profiles.editor.draft?.rules.filter { $0.enabled && $0.kind.requiresFlowBackend }.count ?? 0
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExternalPageHeader(title: "Flow 实验",
                    subtitle: "验证按应用和域名识别并直连 TCP/UDP flow 的能力；FLOW-02/03 数据面已实现，真机验证前不宣称可用。")
                GroupBox("FLOW-02 · DIRECT relay 试验通道") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("导出 DIRECT 规则到 Flow 桥") {
                                if let draft = profiles.editor.draft { flowBridge.exportRules(profile: draft) }
                            }
                            .disabled(flowBridge.busy || profiles.editor.draft == nil)
                        }
                        Text("导出只写本机 Flow 桥文件（仅试验通道，不含凭据或流量内容）；之后到 Flow Probe App 点「重载规则并更新探针配置」，重启探针后生效。匹配 DIRECT 的 TCP/UDP flow 将由 provider 经物理接口直连，失败即关闭，不回退到 VPN；UDP 只按应用/域名规则接管，仅 IP-CIDR 命中的 UDP flow 仍走原 VPN。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("FLOW-01D · 探针状态") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("当前方案 Flow 规则") { Text("\(flowRules)") }
                        Text(flowBridge.message).font(.callout).textSelection(.enabled)
                        if let snapshot = flowBridge.snapshot {
                            LabeledContent("配置数量") { Text("\(snapshot.configurationCount)") }
                            LabeledContent("配置启用") { Text(snapshot.configurationEnabled ? "是" : "否") }
                            LabeledContent("连接状态") { Text(snapshot.connectionStatus) }
                            LabeledContent("Provider message") { Text(snapshot.providerMessageStatus ?? "not_attempted") }
                            LabeledContent("报告时间") { Text(snapshot.capturedAt.formatted(date: .numeric, time: .standard)) }
                            if let report = snapshot.providerReport {
                                Divider()
                                LabeledContent("观察到的 TCP flows") { Text("\(report.tcp)") }
                                LabeledContent("带 App Signing ID") { Text("\(report.withSourceSigningIdentifier)") }
                                LabeledContent("带 remoteHostname") { Text("\(report.withRemoteHostname)") }
                                LabeledContent("带 remote endpoint") { Text("\(report.withRemoteEndpoint)") }
                                LabeledContent("App 身份可观察") { Text(report.appIdentityObservable ? "部分可见" : "未证实") }
                                LabeledContent("Hostname 可观察") { Text(report.hostnameObservable ? "部分可见" : "未证实") }
                                Divider()
                                LabeledContent("DIRECT 规则已装载") { Text("\(report.rulesLoaded)") }
                                LabeledContent("Relay 开始 / 进行中") { Text("\(report.relayStarted) / \(report.relayActive)") }
                                LabeledContent("Relay 完成 / 失败 / 取消") {
                                    Text("\(report.relayCompleted) / \(report.relayFailed) / \(report.relayCancelled)")
                                }
                                LabeledContent("因接口/上限拒绝") {
                                    Text("\(report.relayRefusedInterface) / \(report.relayRefusedLimit)")
                                }
                                LabeledContent("UDP relay 开始 / 进行中") {
                                    Text("\(report.relayUDPStarted) / \(report.relayUDPActive)")
                                }
                                LabeledContent("UDP relay 完成 / 失败 / 取消") {
                                    Text("\(report.relayUDPCompleted) / \(report.relayUDPFailed) / \(report.relayUDPCancelled)")
                                }
                                LabeledContent("UDP relay 因上限拒绝") { Text("\(report.relayUDPRefusedLimit)") }
                            } else {
                                Text("当前快照没有 provider 运行报告；可能未启动、未连接，或连接对象不支持 provider message。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Button("读取最新本机报告") { flowBridge.reload() }.disabled(flowBridge.busy)
                            Button("清除本窗口显示") { flowBridge.clearView() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("能力边界") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("TCP DIRECT relay") { Text("已实现（试验，真机未验证）") }
                        LabeledContent("UDP DIRECT relay") { Text("已实现（试验，真机未验证）") }
                        LabeledContent("UDP 接管范围") { Text("仅应用/域名规则；IP-CIDR 不接管 UDP") }
                        LabeledContent("DNS") { Text("路径不变，未匹配 UDP/53 走原 VPN") }
                        LabeledContent("未匹配 flow") { Text("交还系统 / 原 VPN 路径") }
                        Text("主程序只读 Flow Probe App 发布的脱敏本机快照，并只在显式点击时导出规则到本机 Flow 桥；不控制其 Network Extension 配置。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("应用名称的模糊匹配用于搜索和选择；真正执行会绑定稳定 App signing identity，而不是长期保存脆弱的进程显示名。")
                    .foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}

struct ExternalSettingsView: View {
    @ObservedObject var helper: ExternalHelperModel
    var body: some View {
        Form {
            ExternalHelperSettingsPanel(helper: helper)
            Section("安全边界") {
                Text("授权 Helper 不等于允许应用规则。实际分流仍需预检、核对和本次明确确认。")
                Text("默认构建不开放路由写入。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 360)
        .padding()
    }
}
#endif
