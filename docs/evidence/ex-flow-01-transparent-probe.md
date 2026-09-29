# EX-FLOW-01：Transparent Proxy 元数据探针与 first-match 核心

日期：2026-09-29。基线 `5fa4738`，Rule V2 已存在。用户要求第三方 VPN 规则以软件名、域名和 IP 为主要输入，因此本批验证 flow 层是否能提供应用/hostname 信息，而不是用路由表伪装按 App 隔离。

## Apple API 依据（2026-09-29 查阅）

- NETransparentProxyProvider：`handleNewFlow` 返回 false 时，flow 继续与最终目的地通信；connect-by-name flow 不绕过 DNS。https://developer.apple.com/documentation/networkextension/netransparentproxyprovider
- NEAppProxyFlow：提供 `metaData` 与 `remoteHostname`；后者只在 hostname 建连 API 场景可用。https://developer.apple.com/documentation/networkextension/neappproxyflow
- NEFlowMetaData：定义 sourceAppSigningIdentifier / sourceAppAuditToken，但 Apple 文档把 metadata 的存在描述在 per-app VPN 语境，因此 Transparent Proxy 是否稳定获得来源 App 不能只靠 API 名称推断，必须真机测。https://developer.apple.com/documentation/networkextension/neflowmetadata
- Network.framework 支持 requiredInterface，用于后续 FLOW-02 的物理出口候选；本批未建立远端连接。https://developer.apple.com/documentation/network/nwparameters

## 实现

新增 `Packages/ExternalFlow`：

- ExternalFlowCore：将 Rule V2 编译成 flow first-match 判定。APP 规则必须额外绑定稳定 signing identifier；用户输入的软件名不直接成为执行身份。
- ExternalFlowProvider：`ExternalTransparentProbeProvider`。首批只设置 outbound TCP Transparent Proxy 匹配、观察 flow metadata、累计脱敏计数，并始终返回 false；UDP/QUIC 留待后续单独验证。
- provider message `probe-report-v1` 只返回计数，不含真实 App ID、hostname、IP、端口或流量。
- 明确没有 `NWConnection`、flow open/read/write、数据复制或 DIRECT 出站。

新增 `external-flow-test` 和 `external-flow-build`。FLOW-01B 进一步复用项目既有 System Extension Xcode 结构，生成独立 Flow Probe App 与嵌入的 Transparent Proxy `.systemextension`，默认 unsigned，仅编译/链接并核对 provider class 映射、arm64 可执行文件和 bundle 形态；仍明确 `extension_activation=NOT_REQUESTED`、`flow_copying=NOT_IMPLEMENTED`。

## 验证边界

ExternalFlowCore 新增 5 项 XCTest 源码：应用/域名/IP first-match、hostname 缺失不误匹配、APP 未解析稳定身份阻断、停用 APP 不要求绑定、probe report 只含计数。另有 3 项 Python 合同测试，检查本地依赖、provider 始终 pass-through、没有 flow copying API，以及 builder 不安装/执行。

当前执行环境无法 clone GitHub，因此没有实际运行这些新测试，也没有 Apple SDK 类型检查。provider 源码结构及 unsigned systemextension 生成器已按当前 Apple API 编写，但只有在用户 Mac 完成 `external-flow-build` 后才能称为原生编译/链接通过；签名 entitlement 接受、Transparent Proxy manager 配置、扩展激活和真机 metadata 观察仍未验收。

## 下一步

先把 provider 打成可签名/可激活的最小系统扩展探针，测试第三方 VPN 开启时：
1. 返回 false 的 flow 是否继续保持原 VPN 路径；
2. 常见 App 的 sourceAppSigningIdentifier 是否出现且稳定；
3. URLSession/Network.framework 场景 remoteHostname 是否出现，socket/IP 直连时是否按预期缺失；
4. TCP 通过后再单独测试 UDP/QUIC；
5. 只有这些能力通过，FLOW-02 才实现匹配 flow 的物理接口远端连接和数据复制。
