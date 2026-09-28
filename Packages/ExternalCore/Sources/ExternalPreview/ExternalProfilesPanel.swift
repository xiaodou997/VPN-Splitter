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
                    Text("IPv4 DIRECT 例外 · 从上到下检查 · 停用项不进入预览")
                        .font(.caption)
                    ForEach(Array(draft.rules.enumerated()), id: \.element.id) { index, rule in
                        HStack {
                            Toggle("启用", isOn: Binding(get: {
                                profiles.editor.draft?.rules.first { $0.id == rule.id }?.enabled ?? false
                            }, set: { profiles.editRule(rule.id, enabled: $0) })).labelsHidden()
                                .accessibilityLabel("启用第 \(index + 1) 条规则")
                            Text("\(index + 1)").font(.caption).frame(width: 22)
                            TextField("IPv4 / CIDR", text: Binding(get: {
                                profiles.editor.draft?.rules.first { $0.id == rule.id }?.target ?? ""
                            }, set: { profiles.editRule(rule.id, text: $0) }))
                                .font(.system(.body, design: .monospaced))
                            Button("上移") { profiles.moveRule(rule.id, by: -1) }.disabled(index == 0)
                            Button("下移") { profiles.moveRule(rule.id, by: 1) }.disabled(index + 1 == draft.rules.count)
                            Button("移除") { profiles.removeRule(rule.id) }
                        }
                    }
                    Text("批量加入 IPv4 地址 / CIDR，每行一条（全部规则合计最多 64 条）").font(.caption)
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
                    Text("保存只校验格式并保留顺序；网关、当前网络冲突、范围和 Helper 授权仍须另查。空方案或全部停用时不能预览。")
                        .font(.footnote)
                } else {
                    Text("新建方案后加入直连目标；再次打开应用会载入上次保存的选择。")
                }
            }.padding(8).disabled(profiles.busy)
        }
    }
}
#endif
