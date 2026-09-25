# ADR-006：PolicyCore 基础设施与 WireGuard peer 范围检查

日期：2026-09-25。状态：Accepted（纯逻辑实现合同）；不代表 NE、协议集成或真实网络通过。
任务：S1-02；验收：T-P10，并回归 T-P01–P03、T-P07–P09。ADR-002–005 仍留给原计划的技术 Spike。

## 决策依据

[规则规范第 4 节](../policy-dns-spec.md) 要求具名基础设施需求、显式冲突阻断、默认策略的可见例外、WireGuard VPN 目标受原 AllowedIPs 约束。此次只实现输入已明确时的纯函数判定，不自动发现系统网络，也不修改协议配置。

## 决策

1. 保留 `IPv4PolicyCompiler` 作为用户意图编译器，新增 `IPv4ConstrainedPolicyCompiler`。后者接收同一 session/backend/generation/epoch 的 `IPv4ConstraintInput`，重新编译原规则。结果是 `ConstrainedIPv4PolicyPlan`，仍非系统可执行计划。
2. `InfrastructureRequirement` 用不透明 ID、类型和 CIDR 表达。Endpoint、VPN DNS、物理网关、本机地址必须是 /32；LAN 与系统保留范围可为网段。VPN DNS 要求 VPN，其余要求不进入该 VPN 的 DIRECT 意图。DIRECT 不表示将 loopback/本机地址转发到网卡。隧道本地接口地址由调用方作为本机地址提供；远端隧道网关不能误归为本机地址。
3. 与实际第一条命中规则相反时返回 `E_INFRASTRUCTURE_CONFLICT`，包括显式 /0；不能偷偷优先插入基础设施规则。未被用户规则匹配的默认区域可以有例外，但结果保留原意图、所有基础设施 ID、逐项 `defaultExceptionCIDRs`。同动作重叠保留全部来源，相反基础设施互相冲突时整体拒绝。
4. WireGuard 必须显式提供 peer 范围；nil 为未知，不能省略校验。空表只在最终没有任何 VPN 目的时成立。检查的是加入 DNS 等必要例外后的全部有效 VPN 区域，包括 default=VPN 的区域；并非仅检查用户输入的 VPN 规则。
5. 多 peer 按最长前缀选择，可由多个前缀/peer 联合覆盖一条用户网段。不同 peer 的相同规范前缀视为歧义而拒绝，不复刻后写覆盖；同 peer 重复项可去重计算，但原输入保留。缺口返回 `E_PEER_UNREACHABLE_RANGE`，从不扩大 AllowedIPs。该名字表示配置范围不匹配，不宣称已做链路可达性探测。
6. OpenVPN/External 不使用 WireGuard 覆盖推理；在这些后端传 peer 范围会拒绝。External 仍只能规划默认 VPN 上的 DIRECT 例外，不安装 DNS 配置，也不推断服务器可达性。
7. 除已有 1,000 条规则、2,048 条最终动作分区限制，增加独立验证预算：256 项基础设施、64 个 peer、2,048 项原始 AllowedIPs（重复项也计数）、16,384 个解释 CIDR。peer 分配表同样受 maxRoutes 限制。只允许降低阈值；超限阻断，不截断。这是计算/内存保护阈值，不是性能保证。

## 算法

收集用户有效区域、基础设施 CIDR 和 peer 前缀的所有边界，用 UInt64 半开区间表示 2^32。每个区间内部匹配集合不变，先保留 first-match，再检查/应用具名默认例外，最后确定 peer。按动作、来源和 peer 分别合并，生成完整不重叠分区，不枚举 IPv4 全空间。

错误只含静态原因及经过限制的不透明 rule/requirement/peer ID，不回显地址或密钥；调用方仍须用非敏感 ID。私有计划包含地址，不能原样导出到公开诊断。

## 未解决或不在范围

调用方必须提供完整、当前的 LAN、本机、loopback/系统范围、Endpoint 与 DNS。空 infrastructure 仅表示没有输入，不表示环境没有基础设施；库不内置跨系统版本的保留地址全集。缺失或错误的拓扑不能由纯函数检测，因此输出明确 `suppliedTopologyOnly`。

Endpoint 的地址级 DIRECT 需求是保守预览模型；NE/协议 underlay 可能只绑定外层流量，具体机制须 S1/S3 实测，不能把这里的例外直接当系统 route 命令。输入 context 相等不是签名、授权或快照完整性证明。

DNS 服务器响应、实际选路、peer 握手/回程、Endpoint 漫游、动态拓扑更新、完整 DNSPlan、IPv6 与按域名分流不在本次通过范围。产品不能只调用旧意图编译器便开始应用网络设置。

## 参考

[WireGuard 官方说明](https://www.wireguard.com/#cryptokey-routing) 区分发送时 peer 选择与接收来源检查；[上游 allowedips 测试](https://git.zx2c4.com/wireguard-go/tree/device/allowedips_test.go) 展示嵌套前缀选择。本实现未复制上游代码，相同前缀归属歧义采取项目侧拒绝策略。测试见 [T-P10 证据](../evidence/s1-tp10-tests.md)。
