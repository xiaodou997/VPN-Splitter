# ManagedSettings — WG-INT-01

WireGuard 接入准备中的网络设置对象生成层。不是模拟连接，不建立隧道，也不是可直接安装的运行计划。纯 Swift `ManagedSettings` 依赖未修改的 PolicyCore；macOS 专属 `ManagedSettingsApple` 创建真实 NetworkExtension 类型的对象，但没有调用应用设置的 API。

详细范围、入口和原生测试：[接入指南](../../docs/managed-wireguard.md)。决策：[ADR-013](../../docs/adr/ADR-013-managed-settings-preparation.md)。

`ManagedSettingsDraft.prepare` 只接受 `ConstrainedIPv4PolicyPlan` 和明确的 `SettingsInput`：接口地址、全部已知 IPv4 端点、协议 Peer 范围、DNS 选择、MTU 和会话上下文。它不会从 AllowedIPs 生成系统路由；Included/Excluded 路由只能来自 PolicyCore 的最终动作分区。无 VPN 区域时拒绝创建草稿，不能偷偷变为全局 VPN。

`PacketTunnelSettingsFactory.makeForInspection` 必须再次提供当前输入并检查一致性，然后创建 Apple 对象。不配置 `NEVPNManager`，不调用 Provider，也不修改接口或 DNS。调用方负责拒绝 IPv6/未解析主机名等未覆盖输入，不可用 `compactMap` 丢弃后冒充完整配置。所有返回值保留 inspection-only 限制。

```sh
# 从仓库根目录运行；不要求签名资料。
/bin/bash tools/managed/test.sh
```

Linux 执行 26 项纯 Swift 测试与离线合同检查；macOS 还编译 Apple target 并执行 4 项原生对象测试。测试不需要真实配置、Keychain 或扩展激活。原生对象正确不证明路由、DNS 或真实出口正确。
