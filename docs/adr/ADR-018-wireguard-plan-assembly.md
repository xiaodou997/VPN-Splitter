# ADR-018：从实际 WireGuard 配置组装分流设置

日期：2026-09-26。状态：Accepted（WG-INT-06 接线代码，未批准运行/发行）。
任务 S1-04/S1-05 部分；T-WGF01–04；Refs #1。承接 ADR-001/013/017。

## 决策

原有配置与规则核心、系统设置工厂及 Adapter 绑定不能通过一个静态示例草稿
来假装已经关联。本批新增实际组装入口，而不是新的模拟连接场景。

`ManagedSettings.PreparedWireGuardPlan` 接收不含密钥的完整网络字段、用户规则、
同一 PlanContext 的显式 underlay 快照和显式 DNS 选择。自动生成端点/接口/DNS
约束及按位置编号的 Peer 表，调用真实 IPv4ConstrainedPolicyCompiler，再生成
ManagedSettingsDraft。用户规则不由 AllowedIPs 自动替代，也不改协议 AllowedIPs。

underlay 只能提供 physicalGateway/physicalLAN/systemReserved，不得提供协议 Peer
或代填端点/DNS/接口角色；其标识重新按位置编号。空 underlay 是显式的“没有提供
观察值”，不是已探测网络，也不是允许执行的完整网络快照。

全部配置地址族必须被检查：IPv6、主机名/缺失端点、搜索域、无效端口或超限内容
拒绝，不过滤掉后继续。接口主机位保持不变。MTU nil/0 为已有 automaticOverhead80
候选，其余需有效显式值。此组装器不替代原 .conf 导入校验或服务器认证。

DNS 延续 AppCore 的约束：配置 DNS 的地址仍要求可经 VPN 到达；选择“保留系统
DNS”不安装 resolver、不代表 DNS 不泄漏。“使用配置作为默认 DNS”只允许 Bypass
且必须有非空配置 DNS；不增加 Split DNS/搜索域/域名分流能力。

`integrations/wireguard/ManagedWireGuardAssembly.swift` 从真实 TunnelConfiguration
投影所有网络字段，冻结协议快照，构造必选运行绑定、描述符回调和策略设置回调。
每次设置请求重新投影并比较，设置对象构造前后复查版本；原有 Adapter 继续比较
密钥和完整协议字段。原始日志在该工厂回调处丢弃，不扩展为安全诊断接口。

该源文件被复制进已有隔离链接探针，显式声明本地 PolicyCore 依赖，无远端新依赖。
不修改正式 Provider、LocalDev 或用户数据；不调用 start/update/系统设置应用。
提供配置与描述符的可信来源、控制层失效和退出观察仍须正式 Provider 接线。

## 验收与边界

48eee07 的原生构建是单独的 USER_REPORTED PASS；不能覆盖本批新增源代码。
新组装逻辑的真实 PolicyCore 测试和接线测试见本批证据。Apple 类型检查及完整
新候选链接仍需后续 Mac 执行。没有新增语言、工具安装、工作区/凭据格式或权限。
签名继续暂停到首次真实联调前；撤回用后继提交，不删除缓存、密钥或用户配置。
