# 规则、DNS 与失败语义规范

版本：Design Draft 1.0；2026-09-23。适用需求：RULE、DNS、FAIL。  
本文定义开发合同，不表示已有对应解析器或路由执行器。

## 1. 三个不同层次

必须区分：

- 规则意图：例如名称应使用 VPN。
- 编译计划：某些目的 IPv4 地址被编译为 VPN 路由。
- 运行观察：当前系统设置和实际连接是否满足已声明的覆盖范围。

IP 路由不携带原始 hostname。NEDNSSettings.matchDomains 选择解析域，不能自动生成域名的数据路由；Packet Tunnel 也不是自动提供应用/域名元数据的代理接口。[Apple 路由与 Packet Tunnel 说明](https://developer.apple.com/videos/play/wwdc2025/234/)；[matchDomains](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains)。

因此 v0.1 不提供严格 L7 分流，不解析 HTTPS/SNI 来伪造保证，不做 TLS 中间人。

## 2. 规则与标准化

| 类型 | 语义 | v0.1 限制 |
| --- | --- | --- |
| IP-CIDR | 目的地址属于 CIDR | IPv4；执行能力需当前后端支持 |
| DOMAIN | 标准化后的完整域名相等 | 仅 DNS-derived 地址分流，显式 opt-in |
| DOMAIN-SUFFIX | 域名等于后缀，或以点分隔的子域 | 仅 Managed 的固定 CIDR 覆盖组合 |
| MATCH | 未匹配时的默认动作 | 配置内用 defaultAction 表示，不再存一条重复 MATCH |
| IP-CIDR6 | IPv6 CIDR | 可解析为禁用草稿；v0.1 不执行 |

动作是 DIRECT、VPN；REJECT 保留在模型，但启用时返回不支持。不能用一个不可达网关假装实现 REJECT。

域名转换为确定的 ASCII/IDNA 表示、比较时不区分大小写、规范化末尾点；拒绝 URL、端口、路径、空标签和非法通配符。不自行实现不完整的 IDNA 算法，S2 固定使用实现和测试集。

DOMAIN-SUFFIX,example.com 同时包含 example.com 与 a.example.com，不包含 notexample.com。UI 若接受 *.example.com，必须解释并转换语义，不能偷偷改变是否包含根域。

CIDR 规范化为网络地址加前缀长度。输入带主机位时预览规范化结果；禁止模糊的缩写 IPv4 表示。保留稳定 ruleId、显示名称、enabled、来源、顺序。

## 3. 顺序、冲突与 CIDR 编译

用户语义是 first-match。后端路由的最长前缀优先不能改变这一语义。

概念算法：先将规则转换为可表达的地址集合；按顺序对每条规则集合减去已被前面规则覆盖的部分；剩余区域赋予本条动作；其余使用 defaultAction。最终合并同动作的等价 CIDR，生成无歧义的有效区域及来源映射。

例如：

```text
1. IP-CIDR,10.0.0.0/8,DIRECT
2. IP-CIDR,10.42.0.0/16,VPN
默认 DIRECT
```

第 2 条完全被遮蔽，不能因为 /16 更具体就在系统中生效。编译器应给出被遮蔽诊断。

反转两条顺序时，10.42/16 走 VPN，10/8 其余地址 DIRECT；允许拆分 CIDR 或采用已验证等价的 included/excluded 组合，不能依赖未测试的嵌套重包含行为。

Managed Include 输出精确 VPN 有效区域；Managed Bypass 可用默认 VPN 路由加规范化的 DIRECT 排除集合，也可用等价 CIDR 分区。具体编码必须通过两个后端的路径测试。External 仅表达保持原默认 VPN 的 DIRECT 例外，其他要求返回 E_CAPABILITY_UNSUPPORTED。

### 不可表达冲突

```text
a.example -> VPN    -> 198.51.100.10
b.example -> DIRECT -> 198.51.100.10
```

已知两个域名共用地址且要求不同出口时拒绝新计划；不能靠域名顺序让其中一个被误路由。域名与 CIDR 混合规则也要检查：如果用户意图要求同一地址根据名称区分而底层只按地址选路，必须拒绝，或要求用户明确改为地址级意图。

同动作共享地址可以合并，但需要引用计数和来源集合。未知的其他域名也可能使用该 IP；系统无法发现所有未知共享关系，故没有冲突报告不代表精确域名隔离。

## 4. 基础设施路由与拓扑保护

用户规则之外存在隧道 Endpoint、隧道地址、VPN DNS、物理网关和系统必要网络。执行前生成具名的 InfrastructureRequirement，并在预览中说明作用。

- WireGuard 的 VPN 目标必须属于协议 AllowedIPs 所能选择的 peer。超出时阻断，不自动扩大 peer 权限。
- OpenVPN 的服务器路由信息是配置/可达性线索，不是任意目标一定可达的证明。
- Endpoint 的外层传输不能递归进入自身隧道；优先使用协议后端/Network Extension 合法的 underlay 机制，在 S1/S3 验证。
- VPN DNS 地址必须存在正确路径；DNS 地址被显式 DIRECT 规则覆盖时不能默默改回 VPN。
- 物理 LAN 与企业网段重叠时显示冲突及实际路由，无法同时满足的策略拒绝。不得无提示地把整个本地网段挪进隧道。
- 保护本机、loopback、链路必要地址与系统保留流量；广泛默认规则的必要例外必须预览，不称为无例外全局转发。

控制面例外不能以“隐藏高优先级规则”消失在 UI 中。默认规则与已声明的必要例外可以共同组成计划；与用户明确相反的目的地址要求冲突时阻断。

## 5. DNS 模式

### 5.1 Managed Include

将明确的企业域交给审核后的 VPN DNS，其他名称沿用系统解析选择。使用 NEDNSSettings.matchDomains，默认不把企业域加入搜索后缀；确需短名称搜索另行配置，避免隐式扩展查询。

VPN DNS 地址对应路由在正式查询前就必须可达。企业域解析失败时，本应用的解析服务不自动回退公共 DNS。操作系统、其他程序或应用自带解析器的行为不属于此条可全面控制的范围。

### 5.2 Managed Bypass

Apple 文档说明：隧道成为默认路由时，VPN DNS 可成为默认 resolver，matchDomains 的限制不能按 Include 行为直接套用。[来源](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains?changes=_3_1&language=objc)

v0.1 默认使用审核后的 VPN DNS，不承诺 DIRECT 目标的 DNS 也走物理网络；UI 明示“数据路径 DIRECT，DNS 可能仍经 VPN”。没有可用 VPN DNS 时必须让用户明确选择保留系统 DNS 并显示限制，不能悄悄换成公共解析器。

S2 必须分别验证默认路由表示方式和 resolver 的实际选取，不能仅检查配置对象里的 matchDomains 字符串。

### 5.3 External

只读观察第三方 resolver 配置，不写系统全局 DNS、不创建 /etc/resolver 文件、不删除第三方 resolver、不主动清空系统 DNS 缓存。名称解析采用当前系统选择的 resolver；数据 DIRECT 与 DNS DIRECT 是不同能力。

## 6. 精确 DOMAIN：DNS-derived 模式

此模式是基于已获得地址的全局目的 IP 分流，不是按连接携带的 hostname 分流。首次使用需确认：共享 IP 会扩大影响，应用独立解析、旧缓存、CDN 差异和 IPv6 会导致覆盖缺口。

### 6.1 实现目标

对显式配置的精确名称，NameResolutionService 使用系统解析选择进行初次解析和更新，返回原始问题名、A/AAAA、CNAME 链（可获得时）、有效期来源、时间和网络 epoch。不假定系统 DNS 配置快照就是每条查询的实际 resolver 证据；不能观测到的信息标为 unknown。

S2 首选验证系统 DNS-SD/解析接口的记录通知与 TTL 获取能力。具体 API 和线程模型在证据中固定。如果实现只能得到 getaddrinfo 风格的地址快照而没有可信更新/有效期，就不能把随意定时刷新称为 TTL 正确实现，也不能通过自动 DOMAIN 验收。

### 6.2 生命周期

1. 解析成功并满足地址族、配置可达性、冲突和资源限制后，将地址集合编译成带来源的 /32 路由。
2. 每条映射记录 ruleId、原名、地址、resolver 证据、获得时间、有效期、epoch 和 generation。AAAA 用于覆盖警告，不自动安装 IPv6 路由。
3. 按可验证的有效期刷新；网络变更、DNS 设置变更、VPN 重连、睡眠恢复时重新确认。回调携带旧 epoch/generation 时丢弃。
4. CNAME 的归属仍是原始查询名；不得把 CNAME 目标擅自变成新的独立用户规则。有效期须考虑链上的约束；资料不完整则标记限制。
5. 同 IP 多来源引用计数；某个名称失效不能删除其他有效规则仍需的地址路由。
6. NXDOMAIN、超时、零 TTL、无法获取可靠有效期、记录超限或重绑定到受保护地址时，不增加新路由；已有映射到期后不无限延长。
7. 映射失效或产生新冲突时，撤回本规则可安全撤回的派生部分，标记 Degraded 并通知；静态 CIDR 仍可继续。首个计划存在阻断错误则整体不启动。

到期撤回后连接按剩余规则和默认路由处理，不提供 fail-closed。已经建立的连接、应用自己保存的 DNS 缓存不会随路由表同步失效；以新建连接为验收对象。

### 6.3 明确不覆盖的情况

应用 DoH/DoT、硬编码 IP、代理/Private Relay、自带 DNS 缓存、查询得到不同 CDN 地址、未知共享 IP、应用绑定接口、IPv6 和既有连接可能不遵循本应用的名称映射。不得记录为精确命中成功。

不通过全量 DNS 劫持或 Packet Tunnel 内置伪 DNS 服务偷偷扩大范围。若后续要实现任意后缀自动发现，必须另立 DNS Proxy/透明代理等架构 ADR，并验证 macOS、签名、第三方共存和隐私影响。

## 7. DOMAIN-SUFFIX：固定网段覆盖组合

v0.1 仅为 Managed 提供“企业域 + 明确 CIDR + VPN DNS”组合：

```text
企业后缀：corp.example
用户确认的覆盖网段：10.42.0.0/16
解析器：10.42.0.53，通过 VPN
```

编译结果包括后缀 resolver 选择和整个覆盖 CIDR 的 VPN 路由。必须说明：该网段的其他名称及直接 IP 访问同样走 VPN，并非只放行后缀域名；后缀解析到网段外的地址不因名称自动获得路由。

配置不得只填一个后缀就宣称系统已经知道所有子域。无 coverageCIDRs 的后缀数据路由规则拒绝激活；仅 DNS 域选择应放在 DNS 配置中，不伪装成数据路由规则。发现企业名称落在声明范围外时诊断需指出，由用户明确更新范围。

## 8. IPv6 与断线合同

v0.1 的可执行数据路由范围为已验收的 IPv4。IPv6 未管理的默认选项名为 unmanaged-with-warning，不是 DIRECT 保证：真实去向仍可能受系统或原客户端影响。

- 首次连接、状态页、规则预览、导出报告均显示 IPv6 未覆盖。
- 后端不支持 IP-CIDR6 时拒绝启用，不忽略配置中的有效 IPv6 规则。
- 不通过全局禁用 IPv6、错误过滤 AAAA 或修改 PF 来掩盖缺口。
- 需要 IPv6-only/NAT64 等网络但后端未经验证时报告不支持环境，不假装已连接。
- 要求 strict-domain、all-address-families 或 fail-closed 的策略直接返回 E_GUARANTEE_UNSUPPORTED。

不主动把 VPN 规则改成 DIRECT，并不等于系统不会在隧道消失后直连。扩展崩溃、认证失败、租约到期、规则过期和卸载均不提供系统级阻断；UI 不使用“绝不泄漏”描述。

## 9. 配置合同与示例

运行时存储采用带 schemaVersion 的类型化 JSON，不把类似 mihomo 的字符串列表当内部真相。规则文本导入仅为将来的 UI 便利，不承诺 mihomo 兼容。未知版本阻断，迁移先备份安全元数据；秘密值不出现在 JSON。

以下是目标数据合同的示意，不是现成导入文件：

```json
{
  "schemaVersion": 1,
  "profileId": "company-wg",
  "source": {"kind": "wireguard", "configurationRef": "local-profile-id"},
  "policy": {
    "defaultAction": "DIRECT",
    "ipv6Policy": "unmanaged-with-warning",
    "failurePolicy": "no-system-kill-switch",
    "domainMode": "dns-derived-opt-in",
    "rules": [
      {"id": "corp-net", "type": "IP-CIDR", "value": "10.42.0.0/16", "action": "VPN", "enabled": true}
    ]
  },
  "dns": {
    "mode": "split",
    "vpnServers": ["10.42.0.53"],
    "matchDomains": ["corp.example"],
    "privateFallback": "none"
  }
}
```

目标 PolicyPlan 至少包含 schemaVersion、sessionId、generation、networkEpoch、backendId、IPv4 有效区域、DNSPlan、InfrastructureRequirement、逐规则解释、限制、输入摘要。摘要用于检测一致性，不代替 IPC 身份验证。

初始工程保护阈值：最多 1,000 条用户规则、256 个活动精确域名、每名 32 个活动地址、编译后 2,048 条路由；这是待 S2/S4 压测的设计上限，不是性能成绩。超限阻断而非截断。更改阈值须更新测试和文档。

## 10. 稳定诊断代码

E_CAPABILITY_UNSUPPORTED、E_GUARANTEE_UNSUPPORTED、E_DOMAIN_IP_CONFLICT、E_RULE_UNREPRESENTABLE、E_PEER_UNREACHABLE_RANGE、E_INFRASTRUCTURE_CONFLICT、E_DNS_UNAVAILABLE、E_DNS_MAPPING_EXPIRED、E_NETWORK_EPOCH_CHANGED、E_EXTERNAL_ENFORCED_OR_CONFLICT、E_ROUTE_OWNERSHIP_AMBIGUOUS、E_LIMIT_EXCEEDED。

错误记录携带相关 ruleId、脱敏原因、是否可重试和可执行的纠正建议；不包含密码、私钥或完整敏感配置。
