// SPDX-License-Identifier: MIT
#if os(macOS)
import SwiftUI
import ExternalCore

struct ExternalProfilesPanel: View {
    @ObservedObject var profiles: ExternalProfilesModel
    var body: some View {
        GroupBox("本机规则方案 · EX-INT-03A") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Menu("选择已保存方案（\(profiles.editor.workspace.profiles.count)/16）") {
                        ForEach(profiles.editor.workspace.profiles) { item in
                            Button(item.name) { profiles.select(item.id) }
                        }
                    }.disabled(profiles.editor.workspace.profiles.isEmpty || profiles.busy)
                    Button("新建") { profiles.newProfile() }.disabled(!profiles.editor.loaded || profiles.editor.mustReload || profiles.busy)
                    Button("重新载入") { profiles.reload() }.disabled(profiles.busy)
                    if profiles.busy { ProgressView().controlSize(.small) }
                }
                Text(profiles.message).font(.callout).textSelection(.enabled)
                if let draft = profiles.editor.draft {
                    HStack {
                        TextField("方案名称", text: Binding(get: { profiles.editor.draft?.name ?? "" }, set: profiles.editName))
                        Text(profiles.hasUnsavedChanges ? "未保存" : "已保存").font(.caption)
                    }
                    Text("DIRECT 规则 · 从上到下检查 · 支持 IP、域名与应用选择器；停用项不进入计划")
                        .font(.caption)
                    ForEach(Array(draft.rules.enumerated()), id: \.element.id) { index, rule in
                        HStack {
                            Toggle("启用", isOn: Binding(get: {
                                profiles.editor.draft?.rules.first { $0.id == rule.id }?.enabled ?? false
                            }, set: { profiles.editRule(rule.id, enabled: $0) })).labelsHidden()
                                .accessibilityLabel("启用第 \(index + 1) 条规则")
                            Text("\(index + 1)").font(.caption).frame(width: 22)
                            Text(rule.kind.rawValue).font(.caption.monospaced()).frame(width: 112, alignment: .leading)
                            TextField("规则值", text: Binding(get: {
                                profiles.editor.draft?.rules.first { $0.id == rule.id }?.target ?? ""
                            }, set: { profiles.editRule(rule.id, text: $0) }))
                                .font(.system(.body, design: .monospaced))
                            Button("上移") { profiles.moveRule(rule.id, by: -1) }.disabled(index == 0)
                            Button("下移") { profiles.moveRule(rule.id, by: 1) }.disabled(index + 1 == draft.rules.count)
                            Button("移除") { profiles.removeRule(rule.id) }
                        }
                    }
                    Text("每行一条。裸 IP/CIDR 兼容旧格式；也可写 DOMAIN,example.com / DOMAIN-SUFFIX,example.com / DOMAIN-KEYWORD,google / APP,Telegram。").font(.caption)
                    TextEditor(text: $profiles.batchText).font(.system(.body, design: .monospaced))
                        .frame(height: 90).border(.secondary)
                    HStack {
                        Button("加入规则列表") { profiles.addBatch() }.disabled(profiles.batchText.isEmpty)
                        Spacer()
                        Button("放弃编辑") { profiles.discard() }.disabled(!profiles.hasUnsavedChanges)
                        Button("复制方案") { profiles.duplicate() }.disabled(profiles.editor.mustReload)
                        Button("删除方案") { profiles.deleteSelected() }
                            .disabled(!profiles.editor.workspace.profiles.contains { $0.id == draft.id } || profiles.editor.mustReload)
                        Button("保存方案") { profiles.save() }.disabled(!profiles.canSave)
                    }
                    Text(profiles.hasEnabledFlowRules
                        ? "当前含域名/应用规则：已保存但 Route Bypass 整体禁止应用，不会静默忽略。后续 Flow Bypass 将按 hostname / 稳定 App 身份执行。"
                        : "当前全部启用规则可由 IPv4 Route Bypass 继续预检；网关、冲突和 Helper 授权仍须另查。")
                        .font(.footnote)
                } else {
                    Text("新建方案后加入直连目标；再次打开应用会载入上次保存的选择。")
                }
            }.padding(8).disabled(profiles.busy)
        }
    }
}
#endif
