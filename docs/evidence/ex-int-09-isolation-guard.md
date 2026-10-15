# EX-INT-09：VPN 隔离守卫（Isolation Guard）真机证据

日期：2026-10-15。关联 [ADR-EX-INT-09](../adr/ADR-EX-INT-09-isolation-guard.md)、[ADR-EX-INT-08](../adr/ADR-EX-INT-08-watchdog-response.md)、[ex-int-07-vpn-watchdog.md](ex-int-07-vpn-watchdog.md)、[ex-int-08-watchdog-response.md](ex-int-08-watchdog-response.md)。

## 范围

在 Flow Probe App 新增「4 · VPN 隔离守卫（试验）」：用户显式点击开启后，守卫复用 watchdog 只读采集判断第三方 VPN 路由形态，并可选对探测目标做 VPN/物理双路裸 TCP 对照探测（只握手、不发送数据）；判定 VPN 断开（路由形态消失）或断流（VPN 路径连续 2 次探测失败，约 8 秒）时，自动执行与手动按钮相同的 `relay-pause-v1`（fail-closed：匹配 DIRECT 的 TCP flow 被关闭，不能访问公网），VPN 恢复后自动 `relay-resume-v1`。只自动解除守卫自己发起的暂停；不持久化任何状态；不阻止系统睡眠；Route 侧不做隔离。

## 离线回归

- `dev.sh external-flow-test` 全绿（ExternalFlow/ExternalFlowWire Debug+Release warnings-as-errors + tests/external_flow 13 项）：新增 `ExternalFlowGuardLogicTests` 7 例（路由丢失即暂停/恢复即解除、断流需连续 2 次失败、单次失败不暂停、探测暂停首次成功即解除、路由丢失覆盖探测暂停、路由恢复不清除探测暂停、手动暂停不被接管）与 `test_int09_isolation_guard_is_explicit_bounded_and_fail_closed` 合同（守卫禁持久化/禁阻止睡眠/禁路由 DNS 变更、执行仅限两个既有动词、UI 无 `.onAppear`/`.task` 自动启动）。
- `dev.sh external-test`（22 项）、`dev.sh external-helper-test`（15 项）、`dev.sh external-execution-test` 全绿，无牵连。

## 真机执行（macOS 26 arm64，StrongVPN 在线开局）

构建链：`external-flow-build --sign`（Developer ID，extension sha256 `f7e0767f…`，CFBundleVersion `20261015.0048`）→ notarytool 提交 `1a6e990f-e03d-449c-a48f-89ed11e435e7`（Accepted）→ staple → 替换 /Applications/VPN-Splitter-FlowProbe.app。第一次构建暴露 FlowProbeGuard.swift 两处编译错误（actor `load()` 缺 `await`、`IPv4Address` 类型歧义），修复后第二次构建通过——离线回归不编译 App 侧源码，此类错误只能由 Xcode 构建发现。

1. 启动探针 → 发布报告：`connected / pass`，rulesLoaded=3，relayPaused=false。
2. 基线：规则内 `http://192.168.2.1/` → 200（DIRECT relay）；对照 `https://www.apple.com/` → 200（VPN 路径）。
3. 点「开启守卫」（探测目标默认 `captive.apple.com:80`，断流探测开启）→ 状态「守卫运行中：路由形态在线；relay 未暂停。」
4. USER_REPORTED 断开 StrongVPN → 约 8 秒内守卫状态变为「路由形态不可识别；relay 已暂停（routeFormLost）」：
   - 规则内 `http://192.168.2.1/` → curl (55)，**连接被 fail-closed 关闭，无法访问网络** ✓
   - 对照 `https://www.apple.com/` → 200（规则外流量走物理路径，不受影响）✓
   - 报告：relayPaused=true，relayRefusedPaused=1（正好对应被关闭的 curl），relayStarted=1
5. USER_REPORTED 重连 StrongVPN → 约 8 秒内守卫状态变为「VPN 路径可达；relay 未暂停。」（路由形态恢复 → 自动解除 → 探测循环确认 VPN 路径可达）：
   - 规则内 `http://192.168.2.1/` → 200（DIRECT relay 恢复）✓
   - 报告：relayPaused=false，relayStarted=2
6. 全程未写路由、未改 DNS、未动 preferences；守卫与探针保持运行（用户功能）。

## 边界与未验证

- "假在线/断流"（路由形态正常但 VPN 路径死）判定链（`vpnPathDead`、连续 2 次失败阈值、恢复后解除）只有纯逻辑单测覆盖；真机断开走的是 `routeFormLost` 路径。真机运行中探测循环确实执行过（重连后状态文案为「VPN 路径可达」），但人为制造"连着但断流"的 VPN 故障没有安全可复现手段，未做真机触发。
- 探测目标命中 DIRECT 规则的拒绝启动（防探针被自己的 relay 暂停误伤）只有离线逻辑与合同覆盖，未真机触发。
- 手动暂停不被守卫接管、守卫暂停/解除指令未送达时的下轮自动重试（undoPause/undoResume）只有单测覆盖。
- 守卫需要 Flow Probe App 保持运行；macOS 睡眠期间不工作（不阻止睡眠）；App 退出后 provider 维持当时的暂停状态，重启探针可清除。
