# VPN-Splitter

面向 macOS 的 VPN 分流客户端与第三方 VPN 兼容层：把“连接 VPN”与“选择哪些流量走 VPN”分开，使用统一规则和诊断管理不同 VPN 来源。

**当前状态：Design Draft 1.0，尚无可运行应用或发行包。** 产品默认值已确认；技术路线需要按 S0–S5 在真实 Mac 上验证，任何文档中的功能均不代表已实现。

## 目标平台与产品边界

首发 macOS 26.0+、Apple Silicon arm64；Swift/SwiftUI + 纯 Swift PolicyCore；Developer ID 签名公证后通过 GitHub Release/DMG 发行。新 macOS 大版本需要重新验证。

可以保存多个配置，一次只激活一个分流会话。主场景是默认 DIRECT、指定目标 VPN。项目不提供 VPN 服务器、订阅或第三方认证破解。

| VPN 来源 | 谁建立连接 | v0.1 目标 |
| --- | --- | --- |
| WireGuard `.conf` | VPN-Splitter | Managed Include/Bypass、IPv4 CIDR、DNS |
| OpenVPN `.ovpn` | VPN-Splitter | 常见认证、服务器配置审核、本地 IPv4 分流 |
| 现有官方/定制客户端 | 原客户端 | 经验证的全局 VPN + DIRECT 例外，受限实验性 |

核心限制：域名分流采用明确标注的 DNS-derived 方式，不保证共享 IP 下严格隔离；DOMAIN-SUFFIX 只提供 Managed 固定 CIDR 覆盖组合。External 默认不改第三方 DNS，也不承诺默认直连的 Include 模式。

v0.1 不提供按 App/进程、多 VPN 叠加、完整 IPv6、REJECT 执行或系统级 Kill Switch。隧道断开后系统可能直连，不能把“不主动改写规则”当作防泄漏保证。不支持的策略必须拒绝启用，不静默跳过。

## 从这里开始

**[完整方案草案：docs/plan-v0.1.md](docs/plan-v0.1.md)** 是开发入口。

| 文档 | 内容 |
| --- | --- |
| [需求规范](docs/requirements-v0.1.md) | 能力矩阵、需求编号、UI 和首发范围 |
| [技术架构](docs/architecture.md) | 模块、target、三后端、状态机、事务恢复 |
| [规则与 DNS](docs/policy-dns-spec.md) | first-match、域名/地址冲突、TTL、IPv6 和断线合同 |
| [安全与发行](docs/security-distribution.md) | Keychain、Helper、签名、公证、许可、卸载 |
| [测试计划](docs/test-plan.md) | 测试 ID、受控目标、真机证据、发布门槛 |
| [开发路线图](docs/roadmap.md) | S0–S5 任务、依赖、交付和停止条件 |
| [研究记录](docs/research.md) | 一手来源、候选项目、依赖准入 |
| [ADR-001](docs/adr/ADR-001-v0.1-baseline.md) | 已接受决策及待验证细节 |
| [证据模板](docs/evidence/README.md) | 验证记录与脱敏要求；当前无测试通过记录 |

## 开发顺序

```text
S0 真实场景 / External 小验证
 -> S1 签名最小工程 / PolicyCore / WireGuard
 -> S2 DNS / 受限域名分流
 -> S3 OpenVPN
 -> S4 External 工程化 / 统一产品
 -> S5 稳定性 / 安装发行 / 原工作流验收
```

总跟踪：[Issue #1](https://github.com/xiaodou997/VPN-Splitter/issues/1)。下一任务是 S0-01，不是同时 Fork 三个项目或开始完整 UI。

目前不提供虚构的安装、构建或测试命令。S1 建立可运行工程后会记录实际工具链和操作步骤。

## 安全与许可证

不要向公共仓库或 Issue 上传有效 VPN 配置、私钥、密码、认证令牌或未脱敏抓包。真实联网验证在有授权的测试 Mac 上执行；公开记录只保留脱敏材料。

自有代码使用 [MIT License](LICENSE)。第三方组件各自的许可证、修改、通知和源码提供义务单独审查；参考项目不自动成为依赖。开发约定见 [AGENTS.md](AGENTS.md)。
