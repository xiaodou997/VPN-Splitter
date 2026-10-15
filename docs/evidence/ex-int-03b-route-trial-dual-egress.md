# EX-INT-03B route-trial：真实双出口流量对照证据

日期：2026-10-15（约 10:20–10:27 +0800）。关联 [协议 v2 真机证据](ex-int-03b-protocol-v2-realmachine.md)（上次闭环未测目标实际流量）、[原生路由证据](ex-int-03b-helper-route-native.md)。

## 范围

上次 route-trial 真机验证了 GUI → 认证 Helper → ADD → 内核读回 → 自动撤销 → 零残留审计，但"目标实际流量（双出口对照）未测"。本次补齐：证明被例外的目标**真实流量**确实从物理宽带出口出去，而非仅路由表形态变化。

## 环境

- macOS 26 arm64；StrongVPN 在线（utun4 持 0/1 + 128.0/1，网关 100.64.8.1）
- 控制 App：/Applications/VPN-Splitter-ExternalControl.app，即 `control.ih56f6nz` 构建（route_trial=COMPILED_EXPLICIT_OPT_IN，FINITE_TRIAL 60 秒，Developer ID 签名；与 main `074d528` 同源，Helper 二进制 sha256 `65974313…` 与构建目录一致）
- Helper v2（io.github.xiaodou997.VPNSplitter.ExternalHelper.v2）沿用既有系统批准，注册状态 enabled
- 目标：ifconfig.me（`--resolve` 钉死 34.160.111.145，避免 DNS 轮换）；对照：ident.me（不在例外内）
- Flow Probe 探针与隔离守卫全程运行但不干扰：其 DIRECT 规则（192.168.2.1/32、ipinfo.io、81.69.116.102/32）与本次目标 34.160.111.145 无交集

## 执行与结果

1. 基线：`curl --resolve ifconfig.me:443:34.160.111.145` → 出口 **216.131.73.244**（StrongVPN）。
2. 新建方案「双出口对照 ifconfig.me」，单条启用规则 `34.160.111.145/32`（IP-CIDR），保存。
3. 分流会话 → 预检：Helper 重新检查网络后提案 `34.160.111.145/32 → 192.168.2.1 / en0 · wouldAdd`，状态 prepared。
4. **USER_REPORTED**：用户在 15 秒确认窗口内亲自勾选「我已核对提案，允许本次有限 IPv4 直连例外」并点击「开始 60 秒分流」。（脚本化操作因 Toggle 需 AXPress、快照索引每秒失效、模型往返超过 15 秒窗口而不可靠；osascript 无辅助访问权限 -1719，未改系统安全设置。）
5. 应用后立即验证：
   - `route -n get 34.160.111.145` → gateway 192.168.2.1 / en0（绕过 utun4）
   - 目标出口 → **183.208.20.139**（家庭宽带，≠ VPN 出口）✓ 双出口成立
   - 对照 ident.me → **216.131.73.244**（仍走 VPN）✓ 例外范围精确
6. 约 60 秒租约到期后：
   - 目标出口回到 **216.131.73.244**（VPN）✓
   - `route -n get` → gateway 100.64.8.1 / utun4，无残留 ✓
   - 会话页：「会话结束：none，剩余回执 0，快照 unchanged」
7. 恢复页「核查恢复状态（只读）」→ **noRecovery** ✓

## 结论

GUI → 认证 Helper → 用户现场确认 → ADD → **真实流量双出口对照** → 60 秒自动撤销 → 零残留审计的完整链路在真机通过。这是"指定 IPv4 绕过全局 VPN"从路由形态到真实数据面的完整证明。

## 边界

- 单一 /32 目标、单接口（en0）、StrongVPN 单拓扑样本；多目标、多物理路径、切网/睡眠中途撤销未在本轮覆盖。
- sustained 长会话模式仍未上真机。
- 这不改变 route_trial 的默认禁用状态；本次复用的是既有显式编译开关构建。
