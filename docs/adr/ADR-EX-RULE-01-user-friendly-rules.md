# ADR-EX-RULE-01：用户友好规则与双执行层

日期：2026-09-29。状态：Accepted。替代此前“v0.1 不做按 App/进程规则”的排队假设；不改变 External 只做 DIRECT 例外、不绕过企业策略的边界。

## 决策

用户通常记得软件名和域名，而不是 IP。统一规则输入增加 IP-CIDR、DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、APPLICATION。文本可采用接近 mihomo 的逐行形式，但内部仍保存类型化结构，不承诺 mihomo 配置/订阅兼容。

External 分为两种执行能力：

1. Route Bypass：现有 PF_ROUTE 目标地址例外。首批只执行 IP-CIDR；未来可选 DNS-derived 精确 DOMAIN。它不能区分来源应用，也不能完整发现任意后缀。
2. Flow Bypass：新增研究/实现方向，优先验证 NETransparentProxyProvider。按 flow 的来源应用和 remote hostname 做 first-match；匹配 DIRECT 的流由 provider 创建绑定当前物理接口的出站连接，未匹配流交还系统继续走原第三方 VPN。

应用规则的用户输入是“软件名模糊搜索”，执行身份不是模糊字符串。首选把搜索结果固定为 bundle/signing identifier；显示名仅用于 UI。命令行进程名通配/正则作为后续高级能力。

## 安全边界

任何启用的 DOMAIN-SUFFIX、DOMAIN-KEYWORD、APPLICATION 在 Flow Bypass 未通过真机前都不可执行。Route Helper 遇到它们必须整体拒绝，禁止只执行剩余 IP 规则。

Flow Bypass 必须单独验证：与第三方 VPN 共存、TCP/UDP/QUIC、DNS/DoH 限制、requiredInterface 物理出口、切网/睡眠、来源身份、签名与系统授权。无法稳定绑定物理接口或出现循环/争用则保持不可用。

## 迁移

本机规则文档升级为 external-profiles-v2。旧 v1 读取时每条规则按 IP-CIDR 迁移；只在下一次正常保存时写回 v2。未来版本仍拒绝降级覆盖。