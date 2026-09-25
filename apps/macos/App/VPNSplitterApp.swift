// SPDX-License-Identifier: MIT
import SwiftUI
import PolicyCore

@main
struct VPNSplitterApp: App {
    @StateObject private var model = SpikeController()
    var body: some Scene {
        WindowGroup("VPN-Splitter · S1") {
            VStack(alignment: .leading, spacing: 16) {
                Text("S1-01 · 签名与扩展加载验证").font(.title2)
                Text("尚未接入 WireGuard/OpenVPN。本工程不安装流量路由或 DNS 设置，启动测试预期返回受控错误。")
                Text("PolicyCore: \((try? IPv4CIDR("198.51.100.7/24"))?.description ?? "unavailable")")
                Text(model.extensionStatus)
                Text(model.profileStatus)
                HStack {
                    Button("1. 激活扩展") { model.activate() }
                    Button("2. 保存测试配置") { model.saveProfile() }
                    Button("刷新状态") { model.refresh() }
                }.disabled(model.busy)
                Toggle("我已断开其他 VPN；本机允许扩展测试，并有本地恢复入口", isOn: $model.confirmed)
                Button("3. 测试 Provider 启动（预期失败）") { model.startSmoke() }
                    .disabled(model.busy || !model.confirmed)
                HStack {
                    Button("停止本测试会话") { model.stop() }
                    Button("移除本测试配置") { model.removeProfile() }
                    Button("停用本扩展") { model.deactivate() }
                }.disabled(model.busy)
                Text(model.message).textSelection(.enabled)
                Text("只有日志出现 S1_PROVIDER_REACHED，才证明进入了 Provider。连接失败本身不算通过。")
                    .font(.footnote)
            }.padding(24).frame(minWidth: 720, minHeight: 430)
        }
    }
}
