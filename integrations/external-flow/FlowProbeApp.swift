// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct FlowProbeApp: App {
    @StateObject private var control: FlowProbeController
    @StateObject private var guard_: FlowProbeGuard

    init() {
        let controller = FlowProbeController()
        _control = StateObject(wrappedValue: controller)
        _guard_ = StateObject(wrappedValue: FlowProbeGuard(controller: controller))
    }

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
                Section("4 · VPN 隔离守卫（试验）") {
                    HStack {
                        TextField("探测目标 host:port", text: $guard_.probeTarget)
                            .disabled(guard_.running)
                        Toggle("断流探测", isOn: $guard_.probingEnabled)
                            .disabled(guard_.running)
                    }
                    HStack {
                        Button("开启守卫") { guard_.start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(guard_.running)
                        Button("关闭守卫") { guard_.stop() }
                            .disabled(!guard_.running)
                    }
                    Text(guard_.status)
                    Text("守卫运行期间：只读观察第三方 VPN 路由形态，可选对探测目标做 VPN/物理双路 TCP 对照（只握手、不发送数据）；判定 VPN 断开或断流时自动执行与上方按钮相同的 relay 暂停（fail-closed，规则内连接无法访问公网），恢复后自动解除。需要本 App 保持运行；不写入任何持久状态；关闭守卫不会自动解除已存在的暂停。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
            .frame(minWidth: 720, minHeight: 430)
        }
    }
}
