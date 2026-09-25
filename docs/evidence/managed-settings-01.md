# WG-INT-01：网络设置生成与上游接入审查

日期：2026-09-25。基线 `450948fd62eb99978b8a7d2df23ddc4835de59aa`；任务 S1-04/S1-06 准备，T-M01–M05；Refs #1。[ADR-013](../adr/ADR-013-managed-settings-preparation.md)、[使用指南](../managed-wireguard.md)。

## 交付范围

新增 ManagedSettings 纯 Swift 对象配方和 ManagedSettingsApple 原生对象工厂。输入绑定真实 PolicyCore 约束结果、完整 Peer 范围和上下文；Include/Bypass 路由、接口主机位、显式 DNS/MTU 与拒绝路径均有代码，不是新模拟连接场景。原生工厂没有 Provider 参数或系统应用调用。尚未接到 LocalDev 或正式 PacketTunnel，界面仍为 LD-03B。

新增 reference.json：固定审查的官方 WireGuard revision 和源文件 Git blob。上游超时后继续、update 未检查返回值、描述符归属和日志等列为未完成接入门槛。没有把旧依赖版本或 MIT 顶层许可当成完整发行许可/安全审查通过，没有新增远端构建依赖或补丁。

## 本轮实际执行

环境：x86_64 Linux，Swift 6.2.1。Mac Runner 返回 404 / tunnel_client_not_seen，因此没有执行 macOS SDK、GUI 或 Keychain。普通 git clone 的网络不可用，本地测试依赖通过已读取源码重建并核对 Git blob；没有用替代算法或简化 PolicyCore 运行测试。

PolicyCore 的 Package.swift 及全部四个生产文件分别与远端的 `045bf25059ee2f6b9673b1ab9be40f839a744eaf`、`35e753651e5c490f35f53e94e600a903298fc96c`、`8eb64eff708676362eb41a0e9e5fdd641655906e`、`8ed0705906e500d554f675cabf87a0f826715a18`、`d397ac84f419283891b860cc2ec15f9ff8e3a6be` 一致。本次不修改这些文件，也不提交本地测试重建操作。

| 检查 | 本轮结果 | 边界 |
| --- | --- | --- |
| ManagedSettings Debug，warnings-as-errors | PASS，26 tests | 含参数化子用例；使用真实约束编译器 |
| ManagedSettings Release，warnings-as-errors | PASS，26 tests | 同一测试集优化构建 |
| tests/managed | PASS，7 tests | Apple target 接线、无执行 API、清单/许可哈希及命令失败停止 |
| tools/managed/test.sh | PASS，exit 0 | 完整顺序运行上述三组 |
| Apple 工厂及测试源码语法 parse | PASS | 不是 macOS SDK 类型检查 |
| Bash 语法 / git diff 空白检查 | PASS | 不是原生构建 |
| macOS 原生设置对象测试 | NOT RUN，4 项已提供 | Mac 执行统一入口时自动包含，不激活扩展 |

没有重跑旧 AppCore 的 202 项、PolicyCore 独立 79 项、S0/S1 或 LocalDev 原测试；那些生产文件及入口均未修改。旧结果不计作本轮 PASS。用户本轮仅要求继续，没有新增原生验收反馈。

T-M01：session/backend/generation/epoch 每项不匹配，完整输入改变、Peer 范围/身份不符，缺失或额外旧基础设施，全部拒绝。

T-M02：0/0 协议范围不制造 Include 默认路由；接口主机位不被网络地址替代；Bypass 的 DIRECT 排除和 first-match 保持。固定种子的 80 份策略逐一比较所有分区首尾及每份 100 个额外随机地址。独立路由表示解释器与 PolicyCore 决策一致，但不是系统路由探测。

T-M03：DNS 默认接管不能隐式出现在 Include；非空、唯一、正确的 VPN resolver 约束；显式 MTU 不截断、自动 overhead 保留；地址格式、输入/路由预算和空 VPN 计划拒绝。

T-M04：四项 macOS 原生对象测试验证地址/掩码、全部 included/excluded 字段、DNS/MTU、独立对象分配和构造前的新鲜度。Linux 不编译 Apple target，不用替身填补此项。

T-M05：生成层无系统写入、无 Keychain/联网/日志接口；Apple 与纯目标分开；执行失败不输出 PASS；MIT 副本 Git blob 与官方相同。

## 权限、未完成与回退

本轮不访问用户数据、Keychain、路由、DNS 或签名资料；没有改变工作区格式、现有 UI、模拟、Provider 或 entitlement。设置草稿及 Apple 对象只是 inspection-only，仍缺协议构建/链接、完整运行网络快照、真实 NE 应用/观察/恢复、DNS 与实际出口。

首次真实 Managed 联调前恢复开发签名，目前继续暂停。维护 main 历史；撤回用后继提交，不 reset/clean，不删除本地工作区、锁文件、凭据或原 .conf。所有新增测试均为合成地址，不需要真实 VPN 配置。
