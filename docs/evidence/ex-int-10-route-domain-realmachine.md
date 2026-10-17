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

## 补充：长时稳定性第一次运行（同日稍后，16:43–16:48）

为取分钟级以上样本，同方案再次发起 sustained 会话并以每 60 秒 curl 对照记录。结果：会话在约 **4.5 分钟后被 Helper 以 `networkChanged` 保守终止**（16:47:43 统一日志 `lease_terminal state=closed code=networkChanged owned=0 comparison=changed cleanup=none`），快照诊断为 `interfaces_changed=false physical_paths_changed=false dns_changed=false routes_added=3 routes_removed=2`，增删行形态均为 `p32/f=UHLWI(i)/if=en/gw=other`——即物理接口上**临时克隆邻居行（WASCLONED 内核缓存）整条出现/消失**，接口、物理路径、DNS 均无变化。路由自动撤销、目标回 VPN、零残留，fail-closed 方向正确；但 ADR-EX-INT-04 的 epoch 视图（仅归一化 i 标志、不忽略行增删）把这类内核缓存抖动判为网络变化，使 sustained 在正常流量下脆弱。该发现促成 ADR-EX-INT-11（epoch 豁免精确 flags 为 UHLWI/UHLWIi 的 /32 克隆行），修复后重跑。

## 补充：长时稳定性第二次运行（同日 17:34–18:04，含 ADR-EX-INT-11 修复）

`7551638` 重建 App+Helper、注销重注册（探针通过，idle/none）后发起第二次 sustained 会话，每 60 秒记录目标路由接口与双出口（`.local/ex-int-11-stability.log`，124 个样本）。结果：会话存活约 **30 分钟**（17:34–18:04，较第一次 4.5 分钟明显延长），随后仍被 `networkChanged` 保守终止（18:04:22 `lease_terminal state=closed code=networkChanged owned=0 comparison=changed cleanup=none`）。终止前 29 个样本全部 iface=en0、目标出口 183.208.20.139、对照 216.131.73.244；终止后目标回 VPN 出口，对照全程不变——fail-closed 零残留方向再次确认（GUI 状态 closed，剩余回执 0）。

关键诊断：快照计数 `routes_added=0 routes_removed=3`，但 route_shapes 只展示前 2 条且均为已豁免形态 `p32/f=UHLWI/if=en/gw=other/expired=true`——**第三条被删除行被渲染截断隐藏**，epoch 视图差集（真正的触发集合）不可见。据此提交 `a5858a2`：networkChanged 诊断追加 `epoch_added/epoch_removed`（豁免后差集形状，上限 4 条并计数溢出），raw 字段不变。随后以该构建重跑第三次（run3）。

## 补充：Helper/App 二进制核验（run2/run3 通用）

两次运行前均比对 /Applications 与构建目录二进制 sha256 一致，并以 launchd `lease_terminal` 日志 pid 确认运行中的 Helper 为当前注册构建；探针通过的 `idle / none` 往返即针对该二进制。

## 补充：长时稳定性第三次运行（同日 20:07–22:01，含 epoch 差集诊断）

`a5858a2` 构建重注册后发起第三次 sustained 会话，每 60 秒双出口对照（`.local/ex-int-11-stability-run3.log`，120 个样本）。结果：

- **20:07–21:12（约 65 分钟，61 个样本）全程稳定**：目标路由 en0、目标出口 183.208.20.139（宽带）、对照 216.131.73.244（VPN），零漂移。为目前最长样本（4.5 分钟 → 30 分钟 → 65 分钟）。
- 21:12 起对照出口开始超时（VPN 劣化，用户同期报告 VPN 不可用）；21:19 起目标亦超时；**22:01:23 会话以 `observationFailed`（changedDuringRead）保守终止**——utun4 正在拆除，快照读取中途变化，属真实网络事件，fail-closed 方向正确。终止时 owned=0、cleanup=none、mutation_attempts=2（ADD+DELETE 各一次）。
- 终止后确认：utun4 消失，两出口均回宽带（宽带 IP 已由 183.208.20.139 变为 183.208.21.82，ISP 动态分配）。非软件缺陷导致的中断。

并行 en0 WASCLONED 行采样（每 5 秒，`.local/en0-churn-sample2.log`）：**整个窗口内克隆邻居行零生灭**（局域网安静），故本轮未对豁免形成新的压力；豁免在 churn 下的有效性仍以 run2 的 30 分钟为最新证据。run2 中"第三条被隐藏的被删行"因本轮无 networkChanged 终止而未获得形态数据，待下次带 churn 的运行由 epoch_added/epoch_removed 字段揭示。

## 阶段结论

三次运行合计：修复前 4.5 分钟被内核缓存抖动误杀；豁免修复后 30 分钟（被未知第三行终止，诊断已增强）；本轮 65 分钟零 churn、因真实 VPN 断开而正确终止。**真实网络变化（VPN 隧道拆除）触发保守撤销的链路已在真机验证**；2 小时不间断样本与"churn 发生时被豁免"的加长样本仍需 VPN 恢复后重跑。
