// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct FlowProbeApp: App {
    var body: some Scene {
        WindowGroup("VPN-Splitter Flow Probe") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Flow Bypass 能力探针").font(.title2).bold()
                Text("该构建仅用于验证 Transparent Proxy system extension 能否加载并观察脱敏 flow 元数据。")
                Text("默认构建不会注册或激活扩展，也不会复制、重定向或修改网络流量。")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(width: 560, height: 220, alignment: .topLeading)
        }
    }
}
