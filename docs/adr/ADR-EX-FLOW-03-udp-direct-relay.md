# ADR-EX-FLOW-03：Transparent Proxy UDP DIRECT relay 数据面

日期：2026-10-15。状态：Accepted（实现离线完成，真机未验证）。关联 ADR-EX-FLOW-02（TCP relay）、ADR-EX-INT-08（pause 语义）、ADR-EX-INT-09（隔离守卫）。

## 背景

ADR-EX-FLOW-02 只拦截 outbound TCP，明确"不实现 handleNewUDPFlow"。后果：DOMAIN 规则匹配的 App 在真机上仍优先走 QUIC（UDP/443）经 VPN 出口，TCP DIRECT relay 很少被触发——域名分流对浏览器类流量实际不生效。要让 APPLICATION/DOMAIN 规则对真实流量成立，必须处理 UDP。

## 决定

1. **拦截面增加 outbound UDP。** `NETransparentProxyNetworkSettings.includedNetworkRules` 在现有 TCP 规则旁增加一条 UDP 规则。未匹配的 UDP flow 与 TCP 一样返回 `false` 交还系统/VPN，不计数为 relay。
2. **UDP 接管判定的匹配维度收窄。** `NEAppProxyUDPFlow` 在 `handleNewFlow` 时没有远端 IP（只有逐 datagram 的 endpoint）。因此 UDP flow 只在 **APPLICATION 或 DOMAIN 类规则匹配**（signing identifier / remoteHostname）时被接管；仅由 IP-CIDR 规则命中的意图不接管 UDP（拿不到目的地址，不能先接管再后悔）。IP-CIDR 规则继续只作用于 TCP。这是有意的非对称，写入文档与 GUI 文案，不静默。
3. **UDP relay 是 endpoint 键控的有界 NAT。** 接管后打开 flow，`readDatagrams` 按远端 endpoint 分组，每个 endpoint 一条绑定物理接口的 `NWConnection`（UDP）；响应 datagram 经 `writeDatagrams` 写回 flow 并保留来源 endpoint。单 flow 远端 endpoint 上限 8，单 datagram 上限 65535 字节，超限关闭 flow 并计数。
4. **空闲超时是 UDP 的唯一正常结束。** UDP 无 EOF：默认 75 秒无 datagram 即关闭 flow，计为 completed（不是 failed）；错误/取消仍 fail-closed。App 后续报文由 NE 投递新 flow。
5. **fail-closed 与 pause 语义不变。** 匹配 DIRECT 的 UDP flow 在打开/转发失败、超限、pause（隔离守卫）时一律关闭，不回落 VPN 路径。复用 `ExternalFlowRelayGate.decide`（protocol 无关）与同一并发注册表（UDP flow 计入同一 maxConcurrent=64）。
6. **DNS 不经 relay。** UDP/53 等系统解析流量不匹配用户规则时照常走 VPN，本 ADR 不改 DNS 路径；域名解析结果因此仍可能来自 VPN 出口区域，这是已记录的已知边界，不是泄漏（VPN 内解析恰是隐私期望）。
7. **报告仍只增计数。** `ExternalFlowProbeReport` 只加 UDP relay 计数维度；不记录 endpoint、域名、App ID 或 payload。

## 后果

- DOMAIN/APPLICATION 规则首次对 QUIC 等 UDP 流量生效，浏览器 DIRECT 域名出口与 TCP 一致；不再需要"封 UDP/443 强制回退 TCP"的间接手段。
- `tests/external_flow/test_contracts.py` 的"无 UDP"守卫同步改为"UDP 仅 endpoint 键控 relay、无 payload 记录、界限存在"；构建摘要升级（版本号由实现时定为 `external-flow-build-v5`，flow_copying 标记相应调整）。
- IP-CIDR 不接管 UDP 的非对称、DNS 路径不变、睡眠/切网中途行为，均写入 roadmap 剩余验收项；真机出口对照（STUN 绑定回包读出口 IP）通过前不宣称 UDP 分流可用。
