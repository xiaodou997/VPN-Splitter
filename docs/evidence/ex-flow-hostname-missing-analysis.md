# Flow hostname 缺失分析（467/177 样本）

日期：2026-10-17（分析）；数据：2026-09-29 FLOW-01F 采集（git `65dd139`），非 10-15。关联 [FLOW-01F](ex-flow-01f-native-activation-attempt.md)、[FLOW-02](ex-flow-02-realmachine.md)、[FLOW-03 UDP](ex-flow-03-udp-relay-realmachine.md)。本文件是只读分析结论，不产生新真机能力。

## 问题

FLOW-01F 样本：TCP flow 467 条，App ID 可见 467（100%），hostname 可见 177（约 38%），290 条缺失。为什么缺？

## 结论

**remoteHostname 有无的唯一决定因素是建连 API**：应用用 connect-by-name（URLSession / NWConnection(hostname:) / CFStream）建连 → NE 元数据带 hostname；用 BSD socket + getaddrinfo + connect(IP) → 内核只看到 IP，必然为 nil（Apple NEAppProxyFlow.remoteHostname 文档定义）。

缺失主因排序：

1. **跨平台/自带网络栈应用 connect-by-IP**（Chrome/Electron、WeChat 等 IM、node/python、远控工具）——后台 TCP 流量主力，解释 62% 缺失的大头。
2. **IP 字面量直连**（http://IP/、LAN 设备、固定 IP 推送服务）——任何 API 都没有 hostname。
3. **自带加密 DNS（DoH/DoT）**——绕过系统 resolver 后只能 connect-by-IP；与第 1 类高度重叠。

排除的非原因：ECH（remoteHostname 不嗅探 SNI）、VPN 共存（无 VPN 37% vs 有 VPN 38%，几乎相同）、fake-ip（本机实测主 resolver 198.18.0.1 返回真实 IP，不发 fake-ip）、QUIC（467 采集时点 provider 为 TCP-only 构建，UDP 未进分母）。

聚合数据点：无 VPN 基线 ~37% 可见、+StrongVPN ~38%、FLOW-02 curl 密集窗口 ~60%、FLOW-03 重启后小样本 9/8（89%）。

## 对产品行为的影响

hostname=nil 时 DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD 规则不命中，flow 回落 systemDefault 留在 VPN 路径（ExternalFlowPolicy.swift:87-106，有测试锁定"缺失不误匹配"）。**缺失导致少命中（静默降级留 VPN），不会误命中——安全方向正确。**

## 可改善性

- 被动 DNS 嗅探回填：不可行。:53 已在拦截层排除；pass-through 模式读不到 DNS 应答字节；接管 DNS 违反边界且实测 fake-ip 接管导致解析失败。
- TLS SNI 嗅探回填：鸡生蛋问题（DOMAIN 规则需要 hostname 来决定是否接管）。"先接管全部再判定"属新架构，不建议 MVP 阶段做。
- **现实补偿（已有路径）**：hostname 缺失大户正好是 APPLICATION 规则覆盖对象（不依赖 hostname，FLOW-03 已真机通过）；域名需求由 EX-INT-10 路由层 Helper 解析互补（已真机通过，见 [EX-INT-10 证据](ex-int-10-route-domain-realmachine.md)）。

## 后续

各 App 类可见率的精确分布需要受控对照实验（固定 App × 固定目标），前提是把 probe report 扩展为按 signing ID 分桶的有界计数（不含原始 hostname/IP）——隐私敏感 schema 变更，须先立 ADR。建议立项 EX-FLOW-04（hostname 缺失受控分析 + 分桶计数报告），不附带"先接管后判定"架构变更。
