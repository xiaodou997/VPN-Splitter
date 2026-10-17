# EX-INT-10 域名路由真机证据（Helper 侧域名解析 + sustained 刷新）

日期：2026-10-17（约 14:38–14:47 +0800）。关联 [ADR-EX-INT-10](../adr/ADR-EX-INT-10-route-domain-resolution.md)、[sustained 真机证据](ex-int-03b-sustained-realmachine.md)（静态 IP-CIDR 的 sustained 链路）、[双出口对照证据](ex-int-03b-route-trial-dual-egress.md)。

## 范围

在当前 main（`f0da634`）同源的 sustained + route-trial 显式编译构建上真机验证：**DOMAIN 规则**经 Helper 预检时的系统 resolver 解析为 /32 直连提案，现场确认后应用，目标域名流量（不钉 IP、DNS 自然解析）走物理宽带出口，对照保持 VPN，跨过一次 60 秒后台重解析周期后路由保持，手动停止自动撤销、零残留。

## 环境

- macOS 26 arm64；StrongVPN 在线（utun4，OpenVPN TCP，0/1 + 128.0/1 接管默认路由，网关 100.64.8.1；VPN 出口 216.131.73.244；物理宽带出口 183.208.20.139）
- 控制 App：/Applications/VPN-Splitter-ExternalControl.app，即 `control.mnk2yfh8` 构建（`external-helper-build --route-trial --sustained`，Developer ID Application: SHIYU FENG (V6M88BQG7C)，TeamID V6M88BQG7C，本次未公证、本机自用）；/Applications 内二进制 sha256 与构建目录一致（`abbf1f91…a2`）
- Helper：测试前在 Settings 注销旧 Helper 并以当前构建重新注册（enabled）；「测试 Helper 通信（只读）」探针通过——签名校验、root 对端检查、hello 与 status 往返均成功，服务状态 idle / none
- 规则方案「域名分流测试」：单条 `DOMAIN ifconfig.me`（域名分流验证）；对照 ident.me 不在任何规则内
- 测试方法说明：curl 均不钉 IP，让系统 DNS 自然解析，使命中与否完全取决于 Helper 写入的 /32 路由

## 执行与结果

1. 预检：Helper 重新检查网络并解析域名，提案显示 `34.160.111.145/32 (ifconfig.me) → 192.168.2.1 / en0 · wouldAdd`，状态 prepared，`domain_rules=1 domain_routes=1 truncated=no`（来源域名标注在提案行内）。
2. 15 秒确认窗口内勾选 + 开始：状态 active，`stage=add reason=none mutation_attempts=1`。
3. 立即验证（约 14:44）：
   - `route -n get 34.160.111.145` → gateway 192.168.2.1 / interface en0 ✓
   - `curl https://ifconfig.me` → **183.208.20.139**（宽带）✓
   - `curl https://ident.me` → **216.131.73.244**（VPN）✓
4. **约 70 秒后**（已跨过 60 秒后台重解析周期）：路由仍 en0/192.168.2.1，ifconfig.me 出口仍 **183.208.20.139**；GUI 会话仍 active（status 轮询 reply_type=7），重解析 diff 未误删自有路由 ✓。
5. 手动停止（GUI「停止 / 撤销」）：状态 closed，`stage=delete reason=none reply_type=2 mutation_attempts=2`（1 ADD + 1 DELETE），剩余回执 0，快照 unchanged；`route -n get 34.160.111.145` 回 VPN 的 128.0/1（gateway 100.64.8.1），ifconfig.me 出口回 **216.131.73.244** ✓。
6. 恢复页「核查恢复状态（只读）」→ **noRecovery** ✓ 零残留。
7. Helper 统一日志佐证：`lease_terminal state=closed code=none owned=0 comparison=unchanged cleanup=none`（2026-10-17 14:46:41 +0800）。

## 结论

DOMAIN 规则 → Helper 侧系统 DNS 解析 → /32 直连提案（来源标注）→ 现场确认 → ADD → 持续双出口（跨 60 秒重解析）→ 手动停止 DELETE → 零残留审计的全链路在真机通过。EX-INT-10 不再标"真机未验证"；在第三方 VPN kill switch 拦截接口绑定直连的环境里，**域名分流的可行路径是路由层（本证据），不是 Flow 接口绑定层**（FLOW-02/03 互联网 fail-closed 结论不变，两者分工见 roadmap）。

## 边界

- 单域名、单 A 记录目标（ifconfig.me 当前只解析到 34.160.111.145），未覆盖多 IP 域名、解析漂移（refresh diff 增删路径虽被 60 秒周期执行但本次解析结果未变化）、DOMAIN-SUFFIX apex、解析失败整体拒绝的真机触发。
- 约 70 秒样本，不声称小时级稳定性。
- route_trial 仍为编译时显式开关、默认禁用；本次构建未公证，仅限本机自用。
- DOMAIN-KEYWORD / APPLICATION 仍整体拒绝；Flow 层按 App/域名分流在互联网方向仍受 kill switch 限制。
