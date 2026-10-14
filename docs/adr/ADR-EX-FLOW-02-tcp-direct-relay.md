# ADR-EX-FLOW-02：Transparent Proxy TCP DIRECT relay 数据面

日期：2026-10-14。状态：Accepted（实现离线完成，真机未验证）。关联 ADR-EX-RULE-01、EX-FLOW-01；证据见 docs/evidence/ex-flow-02-tcp-relay-implementation.md。

## 背景

EX-FLOW-01 的 `ExternalTransparentProbeProvider` 只观察 flow 元数据并恒返回 `false`（pass-through），证明了 Transparent Proxy 与第三方 VPN 共存、来源 App signing identifier 与部分 hostname 可见。要执行 APPLICATION/DOMAIN 类规则，provider 必须对匹配的 TCP flow 建立替代连接并复制数据（FLOW-02）。ADR-EX-RULE-01 已规定：匹配流由 provider 创建绑定当前物理接口的出站连接，未匹配流交还系统；能力无法稳定验证时保持不可用，不得退化为全局 IP 路由。

## 决定

1. **仅 TCP。** 拦截规则不变（仅 outbound TCP），不实现 `handleNewUDPFlow`，不做 UDP/QUIC relay。DNS/DoH 不在本轮范围。
2. **判定同步、执行异步。** `handleNewFlow` 内只做计数、构造 descriptor（来源 signing identifier、remoteHostname、从 remote endpoint 解析的目的 IPv4）和 `ExternalFlowPolicy` 求值：`systemDefault` 或物理接口未就绪时返回 `false`；`direct` 时返回 `true` 并把 flow 交给 relay 引擎异步打开和复制。
3. **物理接口唯一性。** 用 `NWPathMonitor` 维护当前物理接口（wifi/wiredEthernet 恰好一个）；零个或多个时 DIRECT 判定一律不可用（返回 `false`），不猜测、不退化。不使用 netstat 子进程。
4. **fail-closed。** 匹配 DIRECT 但打开/复制失败时关闭该 flow，连接断开并计数；不回退到 VPN 路径冒充成功。规则本意是"该目标必须直连"，静默改走 VPN 会违反用户显式意图。
5. **循环避免双保险。** DIRECT 连接用 `requiredInterface` 绑定物理接口；同时依赖 NE 机制——provider 进程自建连接不被自身透明代理回捕。后者是真机必验项，验证失败则本能力整体保持不可用。
6. **界限。** 并发 DIRECT flow 上限 64，单块读 64KB，空闲超时 75 秒；超限/超时关闭并计数。payload 不落盘、不进日志、不进报告。
7. **规则通道是显式试验桥，不是授权。** 主 App 用户点击导出后写 `~/Library/Application Support/io.github.xiaodou997.VPNSplitter.FlowProbeBridge/rules.json`（0600、原子写、有界校验），Flow Probe App 用户点击重载后写入 providerConfiguration。同一用户下其他进程理论上可伪造该文件；它只决定 DIRECT 意图集合，不授予任何新权限，provider 侧仍做完整编译校验，无效规则集整体拒绝并回退纯探针。
8. **报告仍为纯计数。** `ExternalFlowProbeReport` 只新增 relay 计数与规则装载状态；不记录域名、App ID、IP、端口或报文。

## 后果

- APPLICATION/DOMAIN-* 规则的执行路径首次存在，但在真机完成出口对照、循环检查与共存验证前，不宣称可用；AGENTS.md 的"未验证不开放执行"边界继续成立。
- `tests/external_flow/test_contracts.py` 的 NWConnection 禁令随实现同步放开，改守"无 UDP、无 payload 记录、界限存在"；构建摘要升级 `external-flow-build-v4` / `flow_copying=TCP_ONLY_TRIAL`。
- UDP/QUIC、DNS、睡眠/切网、VPN 重连、hostname 缺失受控分析仍为独立的后续验证项。
