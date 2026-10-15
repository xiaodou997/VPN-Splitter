# EX-INT-03B sustained 长会话真机证据（协议 v2 构建 + 双出口流量对照）

日期：2026-10-15（约 11:05–11:17 +0800）。关联 [持续试用版证据](ex-int-03b-sustained-preview.md)（2026-09-30 旧构建约 136 秒真机，但当时未证明双路径流量，且首候选有停止回复竞态）、[双出口对照证据](ex-int-03b-route-trial-dual-egress.md)（同机 60 秒有限试用版）。

## 范围

在当前 main（`ad97f12`）同源的 **sustained + route-trial 显式编译构建**上真机验证：持续会话越过旧 60 秒绝对上限后仍保活，且目标真实流量全程走物理宽带出口、对照保持 VPN，用户停止后自动撤销、零残留。

## 环境

- macOS 26 arm64；StrongVPN 在线（utun4 idx=20 持 0/1 + 128.0/1，网关 100.64.8.1；utun0–3 无 inet 地址）
- 控制 App：/Applications/VPN-Splitter-ExternalControl.app，即 `control.vny9o8r1` 构建（`external-helper-build --route-trial --sustained`，Developer ID Application: SHIYU FENG (V6M88BQG7C) 签名，TeamID V6M88BQG7C，本次未公证、本机自用）；内嵌 Helper sha256 `8e435307…c2d` 与构建目录一致
- Helper v2 沿用既有系统批准；测试前在 Settings 注销旧 Helper 并用新构建重新注册，通信探针 hello+status 往返 idle/none 通过
- 目标：ifconfig.me（`--resolve` 钉死 34.160.111.145）；对照：ident.me（不在例外内）
- Flow Probe 探针与隔离守卫全程运行但不干扰（其规则与 34.160.111.145 无交集）

## 执行与结果

1. 预检：Helper 重新检查网络后提案 `34.160.111.145/32 → 192.168.2.1 / en0 · wouldAdd`，prepared。
2. 第一次应用被 Helper 拒绝：`stage=targetGET reason=targetPath decode_field=0 mutation_attempts=0`——路径约束不通过即失败关闭、**零写入**，未部分应用。同一分钟前台只读 probe 通过；约 1 分钟后原样重试即成功，判定为 VPN 路由瞬时状态导致的保守拒绝（fail-closed 行为本身符合设计：不确定就不写）。
3. 第二次应用成功（约 11:12:40）：状态 active，`stage=add reason=none mutation_attempts=1`。
4. 立即验证：`route -n get 34.160.111.145` → en0/192.168.2.1；目标出口 **183.208.20.139**（家庭宽带）；对照 ident.me → **216.131.73.244**（VPN）。
5. **约 125 秒后**（11:14:45，已越过旧 60 秒绝对上限）：路由仍 en0/192.168.2.1，目标出口仍 **183.208.20.139**，对照仍 **216.131.73.244** ✓ sustained 保活成立，心跳续约与 GUI 状态轮询正常。
6. 手动停止（GUI「停止 / 撤销」，约 11:16:02）：状态 closed，`stage=delete reason=none reply_type=2 mutation_attempts=2`（1 ADD + 1 DELETE）；目标路由回 utun4/100.64.8.1，出口回 **216.131.73.244** ✓。
7. 恢复页「核查恢复状态（只读）」→ **noRecovery** ✓ 零残留。

## 结论

GUI → 认证 Helper → 现场确认 → ADD → **持续约 125 秒双出口流量** → 手动停止 → DELETE → 零残留审计的 sustained 链路在协议 v2 当前构建上真机通过。叠加 2026-09-30 旧构建的 136 秒证据，sustained 模式不再标"未上真机"。

## 边界

- 约 2 分钟样本，不声称小时级稳定性；睡眠/切网中途撤销、多目标、多物理路径仍未覆盖。
- 观察到一次瞬时 targetPath fail-closed 拒绝（零写入、可重试）；根因未定性，疑似 VPN 路由瞬时状态，留作后续观察项。
- route_trial 仍为编译时显式开关、默认禁用；本次构建未公证，仅限本机自用。
