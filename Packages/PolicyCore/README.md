# PolicyCore — S1-02 IPv4 纯逻辑实现

日期：2026-09-25。状态：首个实现切片；不是 VPN 客户端，也不是可直接下发的系统路由计划。

遵循 [规则规范](../../docs/policy-dns-spec.md) 和 [架构](../../docs/architecture.md)。源码没有第三方依赖，不使用 SwiftUI、NetworkExtension、进程启动、root API、网络、DNS、文件系统或 Keychain。测试中的 Foundation 仅用于 JSON 编解码校验。

## 构建与测试

在仓库根目录运行：

```sh
swift --version
swift test --package-path Packages/PolicyCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/PolicyCore -c release -Xswiftc -warnings-as-errors
```

Manifest 使用 `swift-tools-version: 6.0`、Swift 6 language mode、macOS 最低版本 `26.0`。本轮实际工具链为 **Swift 6.2.1 / Linux x86_64**；Swift 6.0 本身、macOS SDK、Apple Silicon 和 Xcode 的执行尚未验证。这个 Linux 测试环境不把 Linux 变为产品支持平台。首次 Mac 执行请保留 `swift --version`、`sw_vers` 和 XCTest 汇总，勿把成功编译当作扩展签名通过。

测试使用 XCTest；末尾可能另外出现 Swift Testing 的 `0 tests` 提示，应以 XCTest 的 `Executed 79 tests, with 0 failures` 为本包测试统计。没有运行 GitHub Actions，也没有加入会修改系统网络的测试。

## 本轮已实现

| 类型 | 作用 |
| --- | --- |
| `IPv4Address` / `IPv4CIDR` | 严格点分十进制、CIDR 规范化、包含关系、完整 /0 到 /32、验证式 Codable |
| `IPv4Policy` / `PolicyRule` | 顺序、稳定 ID、显示名、来源、启用状态、默认动作、保证要求 |
| `BackendCapabilities` | 调用方提供的计划能力，不是运行时探测结论 |
| `IPv4PolicyInterpreter` | 对原规则逐条做掩码判断的 first-match 参考解释器 |
| `IPv4PolicyCompiler` | 区间减法、动作归属、同动作合并、CIDR 分解、超限阻断 |
| `IPv4PolicyPlan` | 全 IPv4 的不重叠计划分区、原始规则来源、逐规则说明、限制 |
| `PlanContext` | session/backend/generation/networkEpoch 精确比对，不接受旧或未来版本 |

`DIRECT` / `VPN` 可参与编译。REJECT、DOMAIN、DOMAIN-SUFFIX、IP-CIDR6 和未知类型一旦启用，整次编译返回阻断错误，包括已经被更前规则遮蔽的情况。禁用草稿可保存这些占位匹配类型，但不声称已完成 IPv6/域名解析。域名支持仍属于 S2；严格域名隔离、全地址族和 fail-closed 保证均拒绝。

ID 是本包诊断使用的不透明标识：1–128 个 ASCII 字母、数字、`-` 或 `_`，全列表（含禁用项）唯一；用户可读名称放在 `name`。此约束是当前内存 API 的规则，不是对未来导入格式或完整 Profile schema 的冻结。错误不回显地址、域名、显示名或未知匹配内容；ID 自身仍需由调用方采用非敏感标识。

## 使用示例

```swift
import PolicyCore

let policy = IPv4Policy(defaultAction: .direct, rules: [
    PolicyRule(id: "corp-net", match: .ipv4(try IPv4CIDR("10.42.7.9/16")), action: .vpn)
])
let context = PlanContext(sessionID: "preview-1", backendID: "wireguard", generation: 1, networkEpoch: 1)
let plan = try IPv4PolicyCompiler.compile(policy, capabilities: .wireGuard, context: context)
let decision = plan.decision(for: try IPv4Address("10.42.1.2"))
// decision.action == .vpn; decision.origin == .rule("corp-net")
// plan.overrides has 10.42.0.0/16. This is not a system network change.
```

对外默认规则只使用 `defaultAction`；没有重复 MATCH 项。CIDR 有主机位时规范化，预览调用方应比较原输入与 `description` 后展示变化。

## 算法与可验证结果

规则按顺序把 CIDR 转为半开 UInt64 区间，再减去已经覆盖的区间；因此更具体的后续网段不能抢走前面的匹配。UInt64 可表达末端 `2^32`，无需枚举地址、避免 /0 与最大地址溢出。最后填补默认区域，合并相邻同动作区域，再分解为规范 CIDR。

`routes` 是全地址空间、按网络地址排序、不重叠、按动作合并后的分区；`effectiveRegions` 是保留 first-match 规则来源的独立分区。两条规则可合并为一条路由，但查询仍可解释原始命中。`ruleEvaluations` 保持原顺序，区分 disabled / fullyShadowed / partiallyShadowed / effective，并提供实际覆盖地址数量及 CIDR。

`overrides` 仅是与 `defaultAction` 不同的区域。它不是 Network Extension 的 included/excluded 设置，也不是 Helper 命令；本包故意不固定这些后端编码方式。External 默认 DIRECT 即使被调用方错误授予 Include 能力也拒绝；仅规划 Bypass。

资源阈值来自设计：输入最多 1,000 条规则（含禁用草稿）、最终规范化分区最多 2,048 条 CIDR。允许在测试/调用方降低阈值，不允许升高。上限检查在同动作合并后进行，超限抛错而非截断。这里保守地计算整个意图分区，包括默认动作区域；来源元数据不是安装路由。执行端还须在加入 Endpoint/DNS 等基础设施之后检查实际系统路由总量。

## 不得误用为已验证的执行计划

本轮返回的是 **IPv4PolicyPlan**，不是设计中完整的 `PolicyPlan`。已有基础设施/peer 检查的第二阶段入口（见下文）；尚未实现 DNSPlan、输入指纹、Profile 持久化或运行时 apply/verify。不能将本包输出直接用于修改系统路由。

Context 比对是纯函数；它不会自行观察网络变化、增加 epoch、取消异步任务或阻止不检查它的调用方。执行端必须获取当前上下文并执行检查。T-P08 目前只有纯逻辑覆盖，真实并发回调仍未验证。

可重复测试/需求追踪和未测项见 [本轮证据](../../docs/evidence/s1-policycore-tests.md)。T-P10 的 IPv4 纯逻辑约束已单独验证；S0 恢复收尾/场景等价性和 S1 签名真机不因此通过。

构建接口资料：[Swift Package Manager](https://www.swift.org/documentation/package-manager/)；[Swift language modes](https://developer.apple.com/documentation/packagedescription/package/swiftlanguagemodes)。协议与产品保证以仓库规范为准，当前 API 是实现切片而非全产品配置文件格式。


## T-P10：基础设施与 peer 检查入口

`IPv4ConstrainedPolicyCompiler.compile` 在原意图编译后处理同一上下文的 `IPv4ConstraintInput`，返回仍属 planning-only 的 `ConstrainedIPv4PolicyPlan`。

```swift
let constraints = IPv4ConstraintInput(context: context, infrastructure: [
    InfrastructureRequirement(id: "endpoint", role: .vpnEndpoint, cidr: try IPv4CIDR("198.51.100.11/32")),
    InfrastructureRequirement(id: "resolver", role: .vpnDNS, cidr: try IPv4CIDR("10.42.0.53/32")),
    InfrastructureRequirement(id: "lan", role: .physicalLAN, cidr: try IPv4CIDR("192.0.2.0/24")),
    InfrastructureRequirement(id: "loopback", role: .systemReserved, cidr: try IPv4CIDR("127.0.0.0/8"))
], wireGuardPeers: [
    WireGuardPeerRange(id: "peer-corp", allowedIPs: [try IPv4CIDR("10.42.0.0/16")])
])
let checked = try IPv4ConstrainedPolicyCompiler.compile(policy, capabilities: .wireGuard,
    context: context, constraints: constraints)
// checked.userIntent retains the original first-match decisions.
// checked.infrastructureEvaluations explains every declared default exception.
// checked.peerAssignments uses protocol longest-prefix selection, not rule order.
```

以上地址全部为合成示例，不是用户环境。调用方必须提供当前、完整的基础设施；空数组不是“环境没有基础设施”的证据。库不发现系统地址，不内置跨版本保留地址全集，不把 context 相同当授权。

显式命中规则与基础设施冲突时整体报 `E_INFRASTRUCTURE_CONFLICT`；默认区域允许具名例外并保留所有来源。加入 VPN DNS 后的全部 VPN 目的都须被 WireGuard 原 AllowedIPs 联合集合覆盖，否则 `E_PEER_UNREACHABLE_RANGE`。相同前缀跨 peer 归属歧义拒绝；嵌套前缀按最长前缀选择，不修改输入。OpenVPN/External 不套用 WireGuard 校验。

新增预算：256 项基础设施、64 peer、2,048 原始 AllowedIPs、16,384 解释 CIDR；最终动作分区及 peer 分配 CIDR 各受 maxRoutes 限制。只能降低，超限拒绝。原先纯意图 `IPv4PolicyCompiler` 保留，但不能单独作为产品应用网络设置的入口。

Endpoint 地址级例外不代表 NE 外层传输机制已选定；本机/loopback 的 DIRECT 也不代表向物理接口转发。输出仍带 `suppliedTopologyOnly`、`underlayMechanismNotValidated`、`reachabilityNotTested`。详细合同见 [ADR-006](../../docs/adr/ADR-006-policycore-infrastructure-and-peer-validation.md)，实测见 [T-P10 证据](../../docs/evidence/s1-tp10-tests.md)。
