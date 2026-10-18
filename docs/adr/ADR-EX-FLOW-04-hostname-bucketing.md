# ADR-EX-FLOW-04：hostname 可见率分桶计数（受控实验前置）

日期：2026-10-18。状态：Accepted（离线决策；代码未实现，报告 schema v2 未落地，无真机实验数据）。关联：[ADR-EX-RULE-01](ADR-EX-RULE-01-user-friendly-rules.md)（Flow 层规则语义）、[ADR-EX-INT-10](ADR-EX-INT-10-route-domain-resolution.md)（域名路由层互补路径）、[hostname 缺失定性分析](../evidence/ex-flow-hostname-missing-analysis.md)。

## 背景

FLOW-01 元数据验证已定性：remote hostname 是否可见唯一取决于来源应用的建连 API（connect-by-name 才有 hostname；BSD socket + getaddrinfo + connect(IP) 恒 nil），整体可见率约 38%，大头是 Chrome/Electron、IM、node/python 等自带网络栈应用。缺失时 DOMAIN 类规则不命中、flow 留原 VPN——安全方向正确（少命中、不误命中），但"多少比例的流因此无法用 DOMAIN 规则命中"只有定性结论，没有分应用类型的量化分布。

EX-FLOW-04 受控实验要回答：固定应用 × 固定目标矩阵下，各类来源的 hostname 可见率分布，作为 Flow 层 DOMAIN 规则定位（优先补强还是文档化受限）的数据输入。分桶计数是报告 schema 的隐私敏感变更，必须先立 ADR（roadmap 已列此前置）。

## 决策

1. **只加计数，不加内容**：`ProbeCounters.record(_:)` 增加按来源分桶的**有界计数**（每桶 total/tcp/udp/withRemoteHostname 四个计数器），不记录原始 hostname、remote endpoint、flow 内容；分桶键是来源 signing identifier，不是显示名、不是路径。
2. **桶数有界**：最多 64 个显式桶 + 1 个 `other` 溢出桶（按出现顺序先到先得，溢出合并计入 `other`，不静默丢弃、不拒绝运行）。单计数沿用现有 10,000,000 上界。
3. **本地与发布分离**：
   - 本地 `snapshot.json`（0600）含原始 signing identifier 桶键，供本机主 App 展示与实验统计；
   - 「刷新并发布脱敏报告」路径必须剥离原始桶键，只发布粗类聚合直方图（browser / electron / dev-runtime / system / other，按仓库内置 signing identifier 前缀映射表归类），映射表不含任何本机数据。**原始 signing identifier 不出本机文件。**
4. **schema 版本**：报告格式 `external-flow-probe-v1` 升 `external-flow-probe-v2`，新增 `buckets` 字段；`validated()` 增加桶数、键长（≤128）、计数上界校验。旧版本读取端拒绝降级解码（既有约定）。
5. **计数点不变的安全语义**：hostname=nil 时 DOMAIN 规则不命中、flow 留原 VPN 的行为不变（ExternalFlowPolicy 既有测试锁定）；新增一个诊断计数 `domainRuleSkippedHostnameNil`（规则本可命中来源但 hostname 缺失而未命中，仅计数），用于量化补偿需求，不改变任何转发决策。
6. **实验协议**（EX-FLOW-04 执行时遵循）：固定应用 × 固定目标矩阵（curl/URLSession 类、Chrome/Electron、python/node、IP 字面量、自带 DoH 应用），无规则纯探针跑固定窗口，对照 FLOW-01F 38% 基线；构建须签名+公证且 CFBundleVersion 递增（ex-flow-02 教训）。通过判定：给出各类来源可见率分布表，验证"缺失=少命中不误命中"在安全上等价，并形成 Flow 层 DOMAIN 规则定位结论（补强或文档化）。

## 安全边界

- 纯计数，无 per-flow 日志，无 hostname/IP/Signing ID 内容上报。
- 原始桶键只存在于 0600 本地 snapshot；发布物只有粗类直方图。
- schema v2 未实现并真机验证前，任何"按应用可见率"数字都不得引用为能力声明。

## 涉及代码点（实现清单）

1. `Packages/ExternalFlow/Sources/ExternalFlowProvider/ExternalTransparentProbeProvider.swift` `ProbeCounters.record` 分桶计数。
2. `Packages/ExternalFlowWire/Sources/ExternalFlowWire/ExternalFlowProbeWire.swift` 报告 schema v2 + `validated()` 上界。
3. `ExternalFlowRelayGate` / `ExternalFlowRelayEngine` 增加 `domainRuleSkippedHostnameNil` 计数点（仅计数）。
4. 主 App Flow 实验页展示分桶结果（本地读取）与粗类直方图（发布路径）。
5. 合同测试：`tests/external_flow/test_contracts.py` 报告键清单、`ExternalFlowWireTests` schema/validated 测试、分桶有界与溢出合并测试。

## 任务与验收

- EX-FLOW-04A：schema v2 + 计数点 + 合同测试（离线，`external-flow-test` 通过）。
- EX-FLOW-04B：签名+公证构建 Flow Probe App，真机受控实验，证据入 docs/evidence/ex-flow-04-*.md。前置：Flow Probe 扩展激活链可用（FLOW-02/03 已有先例）。
