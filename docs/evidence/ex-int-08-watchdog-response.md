# EX-INT-08：watchdog 阶段二（VPN 异常响应）真机证据

日期：2026-10-15。关联 [ADR-EX-INT-08](../adr/ADR-EX-INT-08-watchdog-response.md)、[ADR-EX-FLOW-02](../adr/ADR-EX-FLOW-02-tcp-direct-relay.md)（provider message 只读声明在此修订）、[ex-int-07-vpn-watchdog.md](ex-int-07-vpn-watchdog.md)。

## 范围

阶段二交付三件事：provider relay 热暂停（fail-closed）、Flow Probe App 显式暂停/恢复按钮、预览 App 异常横幅（一键停止 Helper 会话 + 引导暂停 relay）。全部动作须用户显式点击，无静默自动。

## 离线回归

- `dev.sh external-test` 全绿（ExternalCore Debug+Release + tests/external 22 项，watchdog 合同新增横幅接线断言，model 禁耦合断言不变）。
- `dev.sh external-flow-test` 全绿（ExternalFlow/ExternalFlowWire Debug+Release + tests/external_flow 12 项）：新增 `ExternalFlowRelayGateTests` 4 例（无策略/未匹配/暂停关闭匹配流/接口缺失拒绝）与 wire 暂停字段向后兼容用例；合同断言 provider message 写面仅限 `relay-pause-v1`/`relay-resume-v1` 两个无参数动词、暂停不写 preferences、按钮无自动触发。

## 真机执行（macOS 26 arm64，StrongVPN 在线）

构建链：`external-flow-build --sign`（Developer ID，extension sha256 `a6ec0942…`，CFBundleVersion `20261014.2310`）→ notarytool 提交 `75d430b4-76b6-4173-be21-c66c94a026fa`（Accepted）→ staple → 替换 /Applications/VPN-Splitter-FlowProbe.app → `.replace` 激活（同 team 无二次授权）。

1. 启动探针 → 发布报告：`connected / pass`，rulesLoaded=3，relayPaused=false。
2. 点「暂停 DIRECT relay」：
   - 匹配目标 `http://192.168.2.1/`（IP-CIDR 规则命中）→ curl (55) Broken pipe，**连接被关闭而非直连**（fail-closed ✓）
   - 未匹配对照 `https://www.apple.com/` → 200（经原 VPN 路径，不受影响 ✓）
   - 报告：relayPaused=true，relayRefusedPaused=2，relayStarted=0
3. 点「恢复 DIRECT relay」：匹配目标 → 200（relay 直连恢复）；报告 relayPaused=false，relayStarted=1。
4. 预览 App（ad-hoc 外部运行实例）监测中，USER_REPORTED 断开 StrongVPN：黄色横幅「VPN 状态异常：第三方 VPN 的隧道路由形态消失…」在概览页顶部出现，含「停止 Helper 分流会话」「知道了」两个按钮；点「知道了」横幅消除。重连后事件列表记录 vpnDisconnected → vpnReconnected，横幅自动清除。
5. 停止监测、停止探针；未写路由、未改 DNS、无残留。

## 边界与未验证

- Route 侧响应仅"撤销例外"，不阻断联网（黑洞/REJECT 属边界外）；VPN 断开后被撤销例外的目标回到系统默认路径。
- relay 暂停是运行时状态，重启探针即恢复；预览 App 不能直达 provider，暂停必须在 Flow Probe App 内点击。
- 「停止 Helper 分流会话」本次在无活动会话下验证（本地 invalidate）；有真实已应用路由时的联动撤销属 route-trial 闭环范围。
- VPN"假在线"（形态正常但断流）仍不可识别，属后续主动探测 ADR。
