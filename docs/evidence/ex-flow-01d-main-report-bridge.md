# EX-FLOW-01D：主程序配置状态与 metadata 报告桥

日期：2026-09-29。基线 `c1af962`。

## 实现

新增独立、无 ExternalCore 依赖的 `Packages/ExternalFlowWire`，供 Transparent Proxy provider、Flow Probe 容器 App 和主 External UI 共用同一份有界 schema。

Provider 原 `probe-report-v1` 改为该 wire 类型。Flow Probe App 新增“刷新并发布脱敏报告”：读取与调用 App 关联的 `NETransparentProxyManager` 配置；connected 时尝试将 connection 作为 `NETunnelProviderSession` 并调用 `sendProviderMessage`；只解码计数型 report。

Probe App 将配置数量、enabled、连接状态、时间和可选 provider 计数写入固定用户 Application Support 目录。目录 0700、文件 0600，读写拒绝 symlink/非普通文件并使用临时文件 + fsync + rename。该桥不是授权边界，也不存 raw hostname/App ID/IP/端口/payload。

主 External App 新增 `ExternalFlowBridgeModel`。它只读取 snapshot store；Flow 实验页面显示配置/连接状态和可见性计数，超过 5 分钟提示旧报告。主程序代码不调用 `startVPNTunnel` 或 `saveToPreferences`。

Apple 文档说明 Transparent Proxy 配置加载结果与调用 App 关联，因此本批刻意不让主 App 直接操作 Probe App 的 Network Extension preferences。Provider message 仅在 Probe App 自己持有的 tunnel-provider session 上尝试。

## 实际验证

在 Linux x86_64 / Swift 6.2.1 隔离目录实际执行新的 ExternalFlowWire 包：

- Debug：2 项 XCTest，0 failure；
- Release：同一 2 项 XCTest，0 failure。

覆盖 report/snapshot 边界、非法计数拒绝、本机临时目录 0700/0600 store 写入/读回，以及持久化文本中没有示例 hostname、App ID、Applications 路径。Debug/Release 是同一组测试，不累计成 4 项。

第一次测试副本因把 Swift 源码压成单行导致 `!=` 词法失真，随后改为保持源码空白后重跑；又发现 XCTest autoclosure 不能包含 actor `await`，已修正测试后最终 Debug/Release 通过。上述中间失败不计为产品缺陷。

## 未验证

当前环境没有 Apple SDK，因此以下仍 NOT RUN：

- `NETransparentProxyManager.connection` 在 Transparent Proxy 配置上是否可转换为 `NETunnelProviderSession`；
- provider message 真机 round-trip；
- System Extension 签名、批准与启动；
- App Signing ID / remoteHostname 在真实第三方 VPN 下的可见比例；
- 主程序 macOS SwiftUI 实际渲染。

如果 session cast 不成立，Probe App 仍会发布配置/连接状态，但 providerReport 为空；不得把空报告当作“没有 hostname/App ID”。
