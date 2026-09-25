# ADR-013：WireGuard 的网络设置生成边界

日期：2026-09-25。状态：Accepted（WG-INT-01 离线准备，不授权真实执行）。任务 S1-04/S1-06 部分；测试 T-M01–M05；Refs #1。承接 ADR-001、ADR-006 和 ADR-012；不改变 S0–S5 退出条件。

## 背景

LocalDev 已有配置、凭据、规则和模拟生命周期，但正式 PacketTunnel 仍是有意拒绝连接的 S1 骨架。下一步应建立真实协议后端与系统策略之间的适配层，而不是继续扩充模拟状态。

固定审查 WireGuard 官方源码 revision `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`。官方 [commit](https://git.zx2c4.com/wireguard-apple/commit/?id=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1) 与 [镜像](https://github.com/WireGuard/wireguard-apple/tree/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1) 对应同一 2023-02-15 提交。这是可复查的源代码基线，不是对 macOS 26 的兼容或安全推荐，不是新的构建依赖。

[PacketTunnelSettingsGenerator](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift) 同时生成协议 UAPI 与系统设置，并把接口网段和 Peer AllowedIPs 加入 includedRoutes。直接使用默认结果会绕过我们的 first-match 编译意图。系统路由必须另行产生，协议范围保持原样。

## 决策

新增独立 `Packages/ManagedSettings`。纯目标将既有约束编译结果转成不可变的 IPv4 设置草稿；Apple 目标只创建 NEPacketTunnelNetworkSettings / NEIPv4Settings / NEDNSSettings 对象。LocalDev 不链接 Apple 目标；正式 Provider 本轮也不链接或调用它。禁止把 planning-only 结果直接接到系统写入 API。

Include：includedRoutes 取最终 VPN 分区；excludedRoutes 取最终 DIRECT 分区。Bypass：includedRoutes 为 /0，excludedRoutes 为最终 DIRECT 分区。采用全体 DIRECT 排除是为了显式表达接口网段内也可能存在直连意图；Apple 对接口 connected-route 的实际优先级仍须测试。DIRECT 仅表示不进入本 Managed 隧道，不保证物理网卡出口或覆盖其他 VPN。两组总条数受 2048 上限约束。

接口地址保留主机位，与路由网络地址分开。计划必须具备与输入一致的端点和接口地址保护，完整 Peer ID/顺序/AllowedIPs 必须等于编译时输入。规划和 Apple 对象构造都检查 session/backend/generation/networkEpoch；对象构造还比较完整输入，防止同上下文下替换 DNS、MTU 或端点。维护 generation/epoch 是未来控制器的职责，本库没有探测“当前网络”的能力，不构成 TOCTOU 或真实应用事务保证。

DNS 没有默认参数：调用方明确选择保留系统 DNS，或在 Bypass 下选择默认隧道 DNS。后者要求非空、有上限、不重复的 IPv4 DNS 地址、具名 VPN DNS 约束及 VPN 选路。Include 不允许该“全 DNS”选项，避免无意扩大接管范围；DOMAIN/matchDomains 的受限域名方案继续留给 S2。保留系统 DNS 不保证私有域可解析或不泄漏，必须在未来真实连接确认中告知。

显式 MTU 保留 576–65535 范围，不静默截断；自动模式仅使用上游 macOS 的 80 字节 overhead 候选，未验证路径可用性。IPv6 无对象输出，输入投影必须先拒绝未覆盖地址族/主机名，不能静默丢字段。

## 没有作出的保证

无协议核心下载/构建/链接、密钥传递、NE 激活、真实 DNS/路由写入、实际出口或撤销确认。没有新工作区版本、Keychain 访问组、第三方运行依赖或发行许可结论。`reference.json` 是审查清单，不能作为可发行依赖锁文件使用。

上游 Adapter 还有必须处理的接入门槛：设置超时后继续、更新时未检查 wgSetConfig 返回值、文件描述符查找的归属、端点/运行态配置日志，以及 start/update/restart 都必须经明确的策略入口且无上游默认回退。见 [接入指南](../managed-wireguard.md)。本轮记录并固定这些差异，不声称已打补丁。

## 验证

T-M01 上下文、完整输入与 Peer 一致性；T-M02 独立解释 emitted routes 与 PolicyCore 的每个分区边界比较；T-M03 显式 DNS/MTU、缺失基础设施和资源限制；T-M04 macOS 原生对象字段及独立分配；T-M05 无系统写入、无远端构建依赖、脚本失败即停与审查清单完整性。结果见 [本轮证据](../evidence/managed-settings-01.md)。

原生对象测试不需要签名，但第一次真实 Managed 联调仍需要开发签名与系统授权；Developer ID/公证留到发行。源码回退使用后继提交，不改写历史、不删用户数据。
