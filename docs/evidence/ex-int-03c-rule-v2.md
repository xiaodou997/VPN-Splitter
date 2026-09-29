# EX-INT-03C：Rule V2 与应用/域名规则方向

日期：2026-09-29。用户补充：日常分流主要按软件名、域名和 IP，而非只记 IP；希望接近 mihomo 的规则体验。

本批升级 External 规则文档：IP-CIDR、DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、APPLICATION。批量框兼容裸 IP/CIDR，并接受 TYPE,value 形式；APPLICATION 当前保存的是用户搜索词，不作为运行身份。后续应用目录选择器需解析为稳定 bundle/signing identity。

为避免能力误报，现有 Route Bypass 只要发现任何启用的域名/应用规则就整体返回 ruleNeedsFlowBackend；Helper 预检按钮也因此不可用。没有静默跳过非 IP 规则。旧 external-profiles-v1 在解码时迁成 v2，缺失 kind 的旧规则按 IP-CIDR 处理；未来 schema 仍拒绝。

隔离验证环境：Linux x86_64、Swift 6.2.1。实际新规则/迁移模型以 Swift 6、strict-concurrency=complete、warnings-as-errors 编译通过；小型 harness 验证 IP 规范化、DOMAIN 大小写/末尾点、SUFFIX 的 *. 归一、KEYWORD、APPLICATION、混合规则阻断 Route Bypass、TYPE,value 批量解析，以及 v1 -> v2 解码/重新编码。该 harness 只替代 IPv4CIDR 的最小解析依赖，不是完整 ExternalCore SwiftPM、Apple SDK 或 GUI 测试。

同步需求、规则规范和 roadmap，并采用 ADR-EX-RULE-01 的双执行层。没有安装 Network Extension、Helper、修改路由、DNS、恢复标记或用户文件。Mac 原生页面、旧方案实际迁移和 Flow Bypass 均待后续验证。