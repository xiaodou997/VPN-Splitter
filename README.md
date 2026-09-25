# VPN-Splitter

面向 macOS 的 VPN 分流客户端与第三方 VPN 兼容层，把“连接 VPN”与“哪些流量走 VPN”分离。

**开发入口统一为 `main`，当前为 LD-03B LocalDev，不是可用 VPN 发行版。** 本轮统一模拟连接、取消/停止、超时、失败重试与配置失效流程；保留 WireGuard 参数编辑、批量规则、搜索及 Keychain 恢复。最新回归和未验项见 [LD-03B 证据](docs/evidence/localdev-03b-lifecycle.md)。用户此前只确认 LD-02C 显示正常，不能据此认定新版 GUI 或真实 Keychain 已验收；不需要历史补丁或 ZIP。

## 现在从这里开始

先保存并完整退出旧 LocalDev，在仓库根目录执行（macOS 26+ / arm64、完整 Xcode 与 SDK 26+）：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash tools/localdev/build.sh run
```

有未提交修改或分支分叉时保留工作并停止，不 reset、clean 或强制覆盖。无需先运行中间版本。窗口顶部应显示“本地开发模式：不接管网络”和 LD-03B。

独立普通 App 使用 ad-hoc 本地签名，不需要 Team ID / VPN profile，不嵌入或激活 Packet Tunnel。提供规则编辑与检查、WireGuard .conf 结构报告、用户确认后的本机 Keychain 保存/读取、重新导入与可重试清理。真实 VPN、Endpoint 名称解析、物理网络探测和 .ovpn 导入尚未实现。Keychain 读回不是认证结果，模拟成功不是 VPN 已连接。

展开“开发工具”可选择正常成功、认证失败、连接超时、成功后中断。每次先检查已保存策略，检查失败不启动模拟定时器；连接等待超过 3 秒结束尝试，取消/停止立即拒绝旧回调，失败只允许手动重试。最近 32 条固定事件仅留内存；“模拟网络变化”是手动注入，不探测系统。模拟不读取 Keychain，也不改变配置或网络。详见 [模拟流程与人工清单](docs/localdev-simulation.md)。

已导入的 WireGuard 策略可在展开区域点击“编辑参数”，调整接口/DNS 地址、监听端口、MTU、端点和保活间隔。AllowedIPs、Peer 身份/顺序和密钥不可在此修改。仅结构策略不访问 Keychain；有关联凭据时通过新随机引用读回验证后再清理旧项，不先删除旧凭据。详见 [参数编辑与恢复](docs/localdev-wireguard-editing.md)。

指南：[LocalDev 操作](docs/localdev.md)、[批量规则与布局验收](docs/localdev-rules.md)、[WireGuard 范围检查](docs/localdev-wireguard.md)、[Keychain 与恢复](docs/localdev-keychain.md)。先用仓库中的 `tests/fixtures/wireguard/synthetic-ipv4.conf` 和 `synthetic-reimport.conf` 验证，不上传真实配置或密钥。原 .conf 不会被修改或删除，必须继续保管。

源码更新不迁移草稿。旧 v1/v2 可以读取；确认结构导入至少使用 v2，首次凭据事务准备记录升级 v3，即使其后授权失败。旧程序会拒绝 v3，不手改版本、清空工作区或恢复旧 JSON 来回退。LD-03B 不新增工作区或凭据记录版本，不持久化模拟状态或过程记录。

统一离线回归，不触碰真实 Keychain 或网络：

```sh
/bin/bash tools/localdev/test.sh
```

已通过的 S1 `preflight` / `unsigned` 不要求重跑；原 unsigned 产物仍不可安装。首次真实 Managed 联调前再按 [S1-01 签名操作](docs/s1-01-build.md) 恢复开发签名；Developer ID、公证和 DMG 更晚处理。调序依据见 [ADR-007](docs/adr/ADR-007-localdev-before-signing.md)。

PolicyCore 完整独立测试仍按其自身入口执行：

```sh
swift test --package-path Packages/PolicyCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/PolicyCore -c release -Xswiftc -warnings-as-errors
```

## 产品边界

首发 macOS 26.0+ / arm64；Swift/SwiftUI + 纯 Swift PolicyCore；目标发行方式是 Developer ID 签名公证后的 GitHub Release/DMG。新系统大版本单独验证。多配置、单活动会话；主场景默认 DIRECT、指定目标 VPN。

| 来源 | 连接者 | v0.1 目标（不是已全部实现） |
| --- | --- | --- |
| WireGuard .conf | VPN-Splitter | Managed Include/Bypass、IPv4 CIDR 与 DNS |
| OpenVPN .ovpn | VPN-Splitter | 常见认证、服务器配置审核和本地分流 |
| 现有官方/定制客户端 | 原客户端 | 经验证的全局 VPN + DIRECT 例外 |

不提供按 App/进程、多 VPN 叠加、完整 IPv6、REJECT 执行或系统级 Kill Switch。域名能力是受限 DNS-derived，不保证共享 IP 严格隔离；后缀只做 Managed 固定 CIDR 组合。External 不承诺 Include，默认不改第三方 DNS。不支持的策略拒绝启用。

## 设计、实现与证据

| 入口 | 内容 |
| --- | --- |
| [完整方案](docs/plan-v0.1.md) | 总目标与阶段门槛 |
| [需求](docs/requirements-v0.1.md) / [架构](docs/architecture.md) | 范围、组件与进程边界 |
| [规则与 DNS](docs/policy-dns-spec.md) | first-match、冲突、TTL、失败语义 |
| [安全与发行](docs/security-distribution.md) | 权限、凭据及发行原则 |
| [路线图](docs/roadmap.md) / [测试](docs/test-plan.md) | S0–S5、任务和验收 |
| [PolicyCore](Packages/PolicyCore/README.md) | 纯逻辑 API，不能直接安装为系统路由 |
| [S0 样本](docs/evidence/s0-single-target-user-result.md) | 用户实测与收尾缺口 |
| [T-P10](docs/evidence/s1-tp10-tests.md) / [S1-01](docs/evidence/s1-01-scaffold.md) | 真实执行与未测范围 |
| [LocalDev 整合](docs/evidence/localdev-main-integration.md) / [LD-02C](docs/evidence/localdev-02c-layout-and-batch.md) / [LD-03A](docs/evidence/localdev-03a-parameters.md) | 历史整合、布局/规则与参数编辑的回归和未验项 |
| [LD-03B](docs/evidence/localdev-03b-lifecycle.md) / [ADR-012](docs/adr/ADR-012-localdev-simulation-lifecycle.md) | 模拟生命周期、超时/取消边界及最新回归 |
| [ADR-008](docs/adr/ADR-008-localdev-edit-transactions.md) / [ADR-009](docs/adr/ADR-009-wireguard-structural-import.md) / [ADR-010](docs/adr/ADR-010-localdev-keychain-transactions.md) / [ADR-011](docs/adr/ADR-011-wireguard-parameter-editing.md) | 编辑事务、导入、凭据恢复及参数换绑 |
| [研究](docs/research.md) / [ADR-001](docs/adr/ADR-001-v0.1-baseline.md) / [ADR-002](docs/adr/ADR-002-signing-spike.md) / [ADR-006](docs/adr/ADR-006-policycore-infrastructure-and-peer-validation.md) | 架构决策及技术验证 |

总跟踪：Issue #1。S0 与 PolicyCore 原工作分支已合入，历史与证据保留。可选的远端已合并分支清理仍独立于日常更新：

```sh
# 先核查；不修改远端分支。
/bin/bash tools/cleanup-merged-branches.sh --check
# 明确删除两条已合入、且仍为审核时 SHA 的远端工作分支；不碰本地 worktree/分支。
/bin/bash tools/cleanup-merged-branches.sh --delete-merged
```

任何检查失败都停止，不 force reset、不 git clean。分支清理不影响阶段验收，也不是更新 LocalDev 的前提。

## 安全与许可证

真实配置、私钥、密码、令牌、签名资料、未脱敏日志不进仓库或公开 Issue。`.local/` 和 `Signing.local.xcconfig` 仅留本机，忽略规则不是隐私安全保证。自有代码为 [MIT](LICENSE)，依赖另审查。开发约定见 [AGENTS.md](AGENTS.md)。
