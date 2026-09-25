# VPN-Splitter

面向 macOS 的 VPN 分流客户端与第三方 VPN 兼容层，把“连接 VPN”与“哪些流量走 VPN”分离。

**开发入口统一为 `main`。当前不是可用 VPN 发行版。** S0 已有一个用户实测的 IPv4 DIRECT/VPN 切换及恢复样本；PolicyCore 与 T-P10 有纯逻辑实现；S1-01 最小 App/System Extension 已入库，等待真机编译、签名和加载。合并不等于验收通过。

## 现在从这里开始

**[S1-01 真机构建与签名操作](docs/s1-01-build.md)**

```sh
/bin/bash tools/s1/build.sh preflight
/bin/bash tools/s1/build.sh unsigned
```

先在 macOS 26+ / arm64、完整 Xcode 与 macOS SDK 26+ 上执行。两条命令分别成功后再继续，均不安装 App、不激活扩展、不改路由/DNS。源码无第三方构建依赖。后续开发签名、Applications 安装、用户批准、Provider 日志和清理均见上面的文档。没有协议后端的 Provider 有意拒绝连接，不能拿“失败”冒充已进入 Provider，须匹配专用日志。

核心可独立测试，不需要 VPN 或签名账号：

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
| [研究](docs/research.md) / [ADR-001](docs/adr/ADR-001-v0.1-baseline.md) / [ADR-002](docs/adr/ADR-002-signing-spike.md) / [ADR-006](docs/adr/ADR-006-policycore-infrastructure-and-peer-validation.md) | 决策及技术验证 |

总跟踪：Issue #1。S0 与 PolicyCore 的原工作分支已合入，提交历史与证据保留；远端分支删除需要支持该操作的客户端。

```sh
# 先核查；不修改远端分支。
/bin/bash tools/cleanup-merged-branches.sh --check
# 明确删除两条已合入、且仍为审核时 SHA 的远端工作分支；不碰本地 worktree/分支。
/bin/bash tools/cleanup-merged-branches.sh --delete-merged
```

任何检查失败都停止，不 force reset、不 git clean。现有 main 有本地修改或不相关提交时先保留工作，再处理合并。

## 安全与许可证

真实配置、私钥、密码、令牌、签名资料、未脱敏日志不进仓库或公开 Issue。`.local/` 和 `Signing.local.xcconfig` 仅留本机，忽略规则不是隐私安全保证。自有代码为 [MIT](LICENSE)，依赖另审查。开发约定见 [AGENTS.md](AGENTS.md)。
