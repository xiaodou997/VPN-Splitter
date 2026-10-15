// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct FlowProbeApp: App {
    @StateObject private var control = FlowProbeController()

    var body: some Scene {
        WindowGroup("VPN-Splitter Flow Probe") {
            Form {
                Section("1 · System Extension") {
                    Text(control.extensionStatus)
                    Button("请求激活 System Extension") { control.activateExtension() }
                        .disabled(control.busy)
                }
                Section("2 · Transparent Proxy 配置") {
                    Text(control.configurationStatus)
                    HStack {
                        Button("检查配置") { control.refreshConfiguration() }
                        Button("保存禁用状态的探针配置") { control.saveProbeConfiguration() }
                        Button("移除探针配置") { control.removeProbeConfiguration() }
                    }.disabled(control.busy)
                    HStack {
                        Button("重载规则并更新探针配置") { control.reloadRules() }
                    }.disabled(control.busy)
                    Text("规则来自主 App「Flow 实验」页显式导出的 Flow 桥文件；无规则时 provider 保持 pass-through 探针。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("3 · TCP 探针 / DIRECT 试验") {
                    HStack {
                        Button("启动探针") { control.startProbe() }.buttonStyle(.borderedProminent)
                        Button("停止探针") { control.stopProbe() }
                        Button("刷新并发布脱敏报告") { control.publishSnapshot() }
                    }.disabled(control.busy)
                    HStack {
                        Button("暂停 DIRECT relay") { control.setRelayPaused(true) }
                        Button("恢复 DIRECT relay") { control.setRelayPaused(false) }
                    }.disabled(control.busy)
                    Text("暂停用于第三方 VPN 异常等场景：暂停后匹配 DIRECT 的 TCP flow 被关闭而不是直连（fail-closed），未匹配 flow 不变；暂停只存在于运行中的 provider，重启探针即恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("未写入规则时 provider 对所有 flow 返回 false。写入 DIRECT 规则后，匹配的 TCP flow 由 provider 经物理接口直连复制（FLOW-02 试验）；未匹配 flow 仍走系统/VPN 路径。")
                        .foregroundStyle(.secondary)
                    Text("发布只写本机用户目录中的计数/状态快照；不会写 hostname、App ID、IP、端口或报文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(minWidth: 720, minHeight: 430)
        }
    }
}
