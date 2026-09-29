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
                }
                Section("3 · TCP metadata 探针") {
                    HStack {
                        Button("启动探针") { control.startProbe() }.buttonStyle(.borderedProminent)
                        Button("停止探针") { control.stopProbe() }
                        Button("刷新并发布脱敏报告") { control.publishSnapshot() }
                    }.disabled(control.busy)
                    Text("探针只统计 App signing ID / hostname / endpoint 是否可见；provider 对所有 flow 返回 false，不复制或改写流量。")
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
