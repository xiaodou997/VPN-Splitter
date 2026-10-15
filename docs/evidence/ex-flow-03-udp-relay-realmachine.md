# EX-FLOW-03：UDP DIRECT relay 真机验证（第一轮）

日期：2026-10-15（约 12:40–13:20 +0800）。代码：main `9b7d1ad`。ADR：docs/adr/ADR-EX-FLOW-03-udp-direct-relay.md。环境：macOS 26 arm64、StrongVPN（utun4，0/1 + 128/1）在线。关联 [FLOW-02 TCP 真机证据](ex-flow-02-realmachine.md)。

## 结论

- **UDP relay 数据面真机通过（LAN 目标）**：匹配 APPLICATION 规则的 UDP flow 被接管，provider 经 `NWConnection`（UDP，绑 en0）转发并保留来源 endpoint 回写，STUN 双向往返成功。
- **互联网 DIRECT（TCP/UDP 同）在 StrongVPN kill switch 下不可用，fail-closed 正确**：provider 自建连接报 `unsatisfied (No network route), interface: en0`，匹配 flow 被关闭不回落 VPN。对照：内核 host route 方式（EX-INT-03B route-trial）同日可出公网——**互联网绕过只能走路由层，接口绑定层被该 VPN 策略拦截**。
- **发现并修复一个真实设计缺陷（已修）**：DNS UDP flow 的 `remoteHostname` 是被查询域名，会被 DOMAIN 规则匹配接管；而 UDP flow 接管前无远端端口 API（SDK 头文件核实只有 `localFlowEndpoint`）。VPN fake-ip resolver（198.18.0.1）经物理接口不可达，fail-closed 导致 curl DNS 解析失败。修复：`excludedNetworkRules` 在拦截层排除目的端口 53（TCP/UDP）。
- **DNS 排除真机验证**：新 provider 处理 105 条 flow 中 0 条目的 :53（旧 provider 同窗口约 282 条）；curl 域名解析恢复正常。
- **APPLICATION 规则匹配成立**：`dev.vpn-splitter.stuncheck`（Developer ID 签名测试工具，tests/dev/stuncheck.c）被 NE 正确上报并匹配；python3 对照不受影响（VPN 出口）。
- **循环检查**：provider 自建连接未被自身代理回捕（每次测试 relayStarted 恰好 +1）。

## 时间线与数据

1. 签名构建 `0.1+20261015.0443`（扩展 sha256 `5b14d4b3…`），公证 `d35c11e5…` Accepted、staple 通过；首次激活失败 `OSSystemExtensionErrorDomain#8`（未公证），公证后激活成功——**sysex 激活确实要求公证**，与 FLOW-01F 结论一致。
2. 桥文件写入 4 条规则（含 `application: dev.vpn-splitter.stuncheck`），重载 + 重启探针，`rulesLoaded=4`。
3. UDP 互联网样本 `stun.l.google.com:19302`：provider accepted → 替代连接 `No network route` → relayUDPFailed=1，客户端超时（fail-closed）✓；python3 对照出口 216.131.73.244（VPN）✓。
4. TCP 域名样本 `curl https://ipinfo.io`：首轮因 DNS flow 被 DOMAIN 规则劫持而失败（发现上述缺陷）；修复重建（`0.1+20261015.0505`，公证 `a797adf3…` Accepted）后 DNS 恢复，TCP flow 被接管但替代连接同样 `No network route` → fail-closed ✓。
5. UDP LAN 样本：本机 STUN 替身服务（tools/dev/stun_server.py，192.168.2.28:9999）→ `stun=OK` 双向往返，relayUDPStarted=2 ✓。
6. 现场恢复：桥文件还原为原 3 条规则（0600）、重载 + 重启探针（rulesLoaded=3、connected）、隔离守卫重新开启。

## 边界

- 互联网 DIRECT（TCP/UDP）能否工作取决于第三方 VPN 的 kill switch/策略；在 StrongVPN 当前配置下按设计不可用。这与 route-trial（内核路由层）形成能力分工：路由层可出公网但按目标 IP；Flow 层按 App/域名但受 VPN 接口绑定策略限制。
- UDP relay 的睡眠/切网中途行为、endpoint 上限压力、QUIC 长连接样本未在本轮覆盖。
- hostname 缺失率（FLOW-01 观察到约 38%）对 DOMAIN 规则命中率的影响仍未做受控分析。
