# 研究记录、依据与依赖准入

更新：2026-09-23。状态：设计依据核对，不是 macOS 真机验证报告。  
执行顺序见[路线图](roadmap.md)，测试门槛见[测试计划](test-plan.md)。

## 1. 阅读方式

每个项目只围绕一个明确问题阅读：解决哪个接口/权限/生命周期问题，哪些代码可复用，修改面和许可是什么，用哪个测试证明适用于本项目。不先 Fork 整个 App，不把项目列表当作依赖清单。

本次核对现有仓库文档、关键上游源码/许可和 Apple 官方资料；没有构建协议核心、没有加载 macOS 扩展、没有复现第三方客户端行为。参考实现存在不等于本项目可行性已证明。

## 2. 一手依据

| ID | 来源 | 对方案的作用 |
| --- | --- | --- |
| A1 | [Apple：Filter and tunnel network traffic with NetworkExtension，WWDC25](https://developer.apple.com/videos/play/wwdc2025/234/) | 选择正确 NE API；路由 enforcement 和默认全隧道边界；直接改路由的兼容风险 |
| A2 | [Apple：TN3134 provider deployment](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment) | 发行形态查阅入口；本次网页正文受 JS 限制，具体 Developer ID 结论由 A3 支持 |
| A3 | [Apple DTS：Exporting a Developer ID Network Extension](https://developer.apple.com/forums/thread/737894) | System Extension、发行 entitlement、profile、签名/导出要求；记录包含 2026-06-22 更新 |
| A4 | [Apple：NEDNSSettings.matchDomains](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains?changes=_3_1&language=objc) | 区分 resolver 选择与数据路由；默认路由下 DNS 行为须独立验证 |
| A5 | [Apple：SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) | 按需 Helper/LaunchDaemon 管理候选；不等于本项目授权流程已跑通 |
| A6 | [Apple：TN3120 Packet Tunnel use cases](https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers) | 后续实现核对入口；本次该网页正文受 JS 限制，Packet Tunnel 边界同时参考 A1 |
| A7 | [Apple：Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | 后续发行流程核对入口；公证执行仍需真机/账号 |
| W1 | [WireGuard：Cryptokey Routing 概念](https://www.wireguard.com/) | AllowedIPs 不仅是系统路由，不能为分流随意改写 |
| W2 | [WireGuard Apple：PacketTunnelSettingsGenerator.swift](https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift) | 协议和系统设置耦合点、默认 DNS 行为、MIT 源文件头部 |
| O1 | [OpenVPN 3：README](https://github.com/OpenVPN/openvpn3/blob/master/README.md) | 客户端核心、macOS 构建、CLI route-nopull 研究入口；不是 NE 集成结果 |
| O2 | [OpenVPN 3：LICENSE.md](https://github.com/OpenVPN/openvpn3/blob/master/LICENSE.md) | AGPL-3.0 或 MPL-2.0 选择，发行前固定版本审查 |
| L1 | [Mozilla：MPL 2.0 FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/) | MPL 源文件、修改和分发通知审核的辅助依据；正式文本优先 |

这些是来源链接，不是自动随上游更新的产品保证。API 网页正文或运行行为未验证的部分不能标成实测。Apple 的示例/论坛也需按本项目实际 SDK 与签名环境复核。

本次关键 GitHub 文件核对的 blob SHA：W2 为 `3658956c6a036ba97b493dc694c756c4eee5b121`；O2 为 `6dad2b379b738bd8401caa96f15d6aa27ef1aa27`。它们是文件对象 SHA，不是可用于固定完整依赖的 commit SHA；S1/S3 必须另记录完整 revision 和传递依赖。

## 3. 参考项目矩阵

| 项目 | 带着什么问题读 | v0.1 定位 | 进入构建前条件 |
| --- | --- | --- | --- |
| [WireGuard Apple](https://github.com/WireGuard/wireguard-apple)；[官方仓库](https://git.zx2c4.com/wireguard-apple/) | WireGuardKit 生命周期、配置、Go 桥、设置生成适配点 | 优先直接依赖候选，小补丁可接受 | 固定 revision、逐组件许可、S1 编译与路由测试 |
| [OpenVPN 3 Core](https://github.com/OpenVPN/openvpn3) | client API、网络配置回调、NE 包通道、取消/线程 | 优先协议核心候选 | MPL 路径审查、固定版本、S3 真实认证和桥接验证 |
| [Passepartout](https://github.com/partout-io/passepartout) / [Partout](https://github.com/partout-io/partout) | Apple VPN 产品组织、配置导入、路由/DNS/授权界面 | 设计参考，不自动引入 | 需要复制时先逐文件许可审查，不推断当前工具链 |
| [VPN-Bypass](https://github.com/GeiserX/VPN-Bypass) | 物理网关识别、有限 Helper、恢复与路由验证 | External 研究参考 | 本项目 S0/S4 重做兼容性与安全验证 |
| [PIA mac-split-tunnel](https://github.com/pia-foss/mac-split-tunnel) / [desktop](https://github.com/pia-foss/desktop) | Transparent Proxy/System Extension、流级分流与恢复 | 未来架构参考，非首发基础 | 对具体问题记录精确 issue/commit/系统版本再引用 |
| [Tailscale](https://github.com/tailscale/tailscale) | 状态协调、网络变更、诊断模型 | 可选专题参考 | 不把完整产品架构直接搬入本项目 |

本次没有对矩阵中所有项目逐文件审计。特别是其他项目曾被讨论的 macOS 26 兼容问题，不能作为本项目已复现的证据，也不能推广成某类 API 必然不可用。参考项目的商标、图标、文档和测试代码同样不能无审查复制。

## 4. 关键待验证假设

| 假设 | 验证阶段 | 失败后的处理 |
| --- | --- | --- |
| 当前原客户端存在可安全添加 DIRECT 例外的路径 | S0、S4 | 停止该兼容后端；不绕过强制策略 |
| 用户的配置可在 Managed 获得等价访问 | S0、S1、S3 | 保留官方客户端需求并记录范围 |
| WireGuardKit 可小范围分离协议和系统设置 | S1 | 记录最小补丁；无法维护则重新选边界 |
| 实际签名环境能交付 Packet Tunnel System Extension | S1 | 明确缺账号/权限或构建问题；不拿未签名编译通过代替 |
| 系统解析数据能支持有界的 DOMAIN 映射/有效期 | S2 | BLOCKED 或范围变更 ADR；不自动上 DNS 劫持 |
| OpenVPN 3 可合法、可维护地嵌入 NE 包通道 | S3 | 评估有证据的替代核心/桥接，不重写协议 |
| External 有限租约/日志可安全处理普通故障 | S4 | 未通过不得开放生产写路由；歧义保守停止 |

## 5. 每项依赖的准入记录

实际引入时在对应 ADR/依赖清单记录：项目、上游 URL、固定 commit/tag、构建校验、精确许可证与文件范围、linked/vendored/reference-only、传递依赖、本地修改、源码提供与通知办法、安全更新负责人/流程、macOS/arm64 验证、签名影响和审核结论。

当前没有依赖被固定，也没有自动追踪上游 master 的生产构建。只有完成准入与该阶段测试后才能把候选改为实际依赖。
