// SPDX-License-Identifier: MIT
#if os(macOS)
import SwiftUI
import ExternalCore

enum ExternalSidebarSection: String, CaseIterable, Identifiable {
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
    @Binding var selection: ExternalSidebarSection?

    var body: some View {
        NavigationSplitView {
            List(ExternalSidebarSection.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.systemImage).tag(item)
            }
            .navigationTitle("VPN-Splitter")
            .navigationSplitViewColumnWidth(min: 170, ideal: 205, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
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
            ExternalOverviewPage(model: model, profiles: profiles, helper: helper, selection: $selection)
        case .rules:
            ExternalRulesPage(profiles: profiles)
        case .session:
            ExternalSessionPage(model: model, profiles: profiles, helper: helper)
        case .recovery:
            ExternalRecoveryPage(helper: helper)
        case .flow:
            ExternalFlowPage(profiles: profiles)
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

struct ExternalOverviewPage: View {
    @ObservedObject var model: ExternalModel
    @ObservedObject var profiles: ExternalProfilesModel
    @ObservedObject var helper: ExternalHelperModel
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
                                Text("\(item.destination) → \(item.gateway) / \(item.interface) · \(item.disposition.rawValue)")
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
    private var flowRules: Int {
        profiles.editor.draft?.rules.filter { $0.enabled && $0.kind.requiresFlowBackend }.count ?? 0
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ExternalPageHeader(title: "Flow 实验",
                    subtitle: "验证按应用和域名识别 flow 的能力；当前探针始终放行，不复制或改写真实流量。")
                GroupBox("FLOW-01 状态") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("当前方案 Flow 规则") { Text("\(flowRules)") }
                        LabeledContent("TCP metadata 探针") { Text("代码已接入，待签名系统扩展真机验证") }
                        LabeledContent("DIRECT flow copying") { Text("未实现") }
                        LabeledContent("UDP / QUIC") { Text("后续单独验证") }
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
