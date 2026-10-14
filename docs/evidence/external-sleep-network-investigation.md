# EX-INT-03B 睡眠后网络故障初查

日期：2026-09-30，Asia/Shanghai。本地调查，不同步 GitHub。

## 实际观察

- 测试前管理员 CLI audit：候选 0、残留/歧义 0，无路由写入。
- 同一授权单目标 GUI prepare、ADD ACK/readback 成功，目标 utun8→en0。
- 14:20:55 左右请求系统睡眠；脚本在系统真正进入睡眠之前已观察目标回 utun8。脚本的 wake_observation_wall 只是返回后采样时间，不能当作真实唤醒时间。
- pmset 记录 14:21:00 Software Sleep，14:30:54 DarkWake，14:31:08 再睡眠，14:36:38 用户唤醒。
- StrongVPN 日志 14:30:54 Inactivity timeout / SIGUSR1 soft ping-restart；14:50:38 CONNECTED,SUCCESS。没有证据证明此间每一秒都完全断网，也不能从这些记录确定重连由何操作触发。
- 本次 14 点时段未找到 Can't assign requested address、Network is unreachable、No route to host 等错误。旧日志存在前日 OpenVPN misc.c:785 assertion，但不能归因于本次故障。
- 后续 GUI recoveryAudit：候选 1、当前残留/歧义 0；目标 utun8。待恢复 marker 尚保留，睡眠闭环不能标 PASS。
- 后续独立 HTTPS example.com 请求严格 TLS 验证返回 200；仅证明采样时此路径已可用。

## 用户报告与分析边界

用户报告睡眠后全机断网，关闭/重开 VPN 无效，执行 network-recover.sh --reset 后恢复（USER_REPORTED）。已只读审阅脚本，没有执行 reset。它同时退出两家 VPN、终止部分后台进程、刷新 DNS、重启 mDNSResponder/configd/networkextensiond；因此无法用一次整体重置的结果定位单个根因。

候选原因包括第三方隧道重连异常、路由/源地址或 DNS 状态过期、网络过滤/kill switch、系统网络服务状态异常；均未独立证实。现有证据支持睡眠与 VPN 保活中断相关，不支持唯一根因结论。utun 数量及 activated enabled 扩展本身不是故障证据。

脚本用历史最后一次 CONNECTED 判 healthy 并非当前可达性检测；其最后成功提示也没有逐项核验重启成功，不能替代探测。

## 后续验证

保留恢复标记用于调查；只允许现有二次新鲜缺席核查后清 marker，不从 marker 重建删除权限。暂停主动睡眠/切网重现，先分析本工具 marker 遗留原因。下一次网络故障须在 reset 前采集物理路径、有限路由、系统 DNS、无 DNS 的 TCP 对照及 VPN 后台事件，并用与本工具未运行时的对照区分原因。原始网络数据只留本机忽略目录。

初查阶段只增加证据文档；后续诊断改动和构建结果见下。第三方恢复/重启系统服务超出现有有限路由 Helper 的职责；如增加独立恢复功能须另写 ADR、明确用户操作与影响，不自动执行整体 reset。

## EX-INT-03B 撤销诊断补全（同日）

源码检查发现 stop() 的观察/持久化异常被保守转为 recoveryRequired，但没有记录具体阶段；App 在睡眠时断开后无法再读取原连接的最终结果。此次仅补充固定枚举类别诊断：删除前观察、所有权核对、删除回执、删除后观察/读回、journal 写入/结束。只保留首个异常，不记录地址、接口、规则、原始错误描述。Helper 在 closed/recoveryRequired 时写一条系统 notice 日志，包含状态、类别、回执数量和快照比较。未改变删除权限、状态迁移、重试或 marker 清除条件。

合成测试复现“DELETE ACK 后 changedDuringRead”：路由已不存在，但回执仍待确认、journal 不 finish、状态 recoveryRequired；重复 stop 不再 DELETE，也不借后续快照一致提升为成功。另一测试验证删除前观察失败时不写路由。这些证明机制可能性，不证明本次真机根因。

验证：ExternalExecution Debug/Release 各 42 tests / 0 failures，Python 26 tests 通过；ExternalControl Debug/Release 各 27 tests / 0 failures，Helper Python 15 tests 通过。实际 Apple SDK release VPNExternalHelper（显式 route-trial 编译选项、warnings-as-errors）编译链接通过。最后调整 only alreadyAbsentJournal 阶段标签也包含在该原生构建。新版本未签名、公证、安装或真机复验；现有安装保持原版本。

管理员只读读取现存 marker 第 2 行起的事件仍待系统授权，未清 marker。未重置网络。GitHub 同步继续暂停。

## 旧标记取证与安全清理

管理员只读读取事件行实际返回 willAdd、addAcknowledged、addReadback、willRemove，没有 removeReadback。它将范围收敛为删除意图记录之后未完成撤销确认，仍不能区分删除回包、后续观察或 journal 错误，不能确定路由由哪个过程最终删除。随后 GUI 再次审计候选 1 / 残留 0，调用既有二次新鲜观察清理成功；UI 确认仅清 marker，未删路由或改 DNS。前文“尚保留”是调查时点状态，现已安全清除。

## 诊断版签名部署与普通撤销验证

候选 control.m56j9i7t Developer ID route-trial 构建通过；Apple 公证 38493629-a4dc-4199-a2ae-6b7c6fa6a313 Accepted，staple/validate 通过。旧 App 经 GUI quiesce/注销并退出，安装前保留本机旧版本副本。安装后 strict codesign、公证票据验证通过；注册 enabled、核查 noRecovery。

单目标普通会话取得 ADD ACK/readback，独立接口 utun8→en0，正常停止 DELETE ACK / mutations=2，closed/none/owned=0/unchanged，独立接口回 utun8，后续 noRecovery。系统日志实际持久记录 `lease_terminal state=closed code=none owned=0 comparison=unchanged cleanup=none`。这验证诊断版部署与正常日志通道；尚未进行新版睡眠复验，不关闭睡眠或第三方 VPN 故障根因门槛。

## 诊断版真实睡眠复验：本工具干净结束，第三方内核异常

用户现场确认可唤醒后执行。15:19:09 前后单目标 ADD ACK/readback、en0 成功；15:19:10.301 Helper 系统日志为 closed / code=none / owned=0 / comparison=unchanged / cleanup=none，独立目标查询回 utun8。15:19:14 pmset 确认 Software Sleep，15:27:29 确认用户唤醒（495 秒）。因此是睡眠通知触发的睡前撤销成功样本，不是路由跨睡眠保留样本；不消除上一轮的未明失败。唤醒后 GUI audit=noRecovery。

StrongVPN 15:27:29–30 记录 Inactivity timeout 和 SIGUSR1 soft ping-restart；15:29:20 记录 FATAL Assertion failed at misc.c:785 (es)。只读查询 OpenVPN 后台进程数 0、旧版 GUI 仍在。当前 default=en0，未见 0/1 或 128.0/1 全隧道路由；独立 HTTPS 请求严格验证成功 200。目标当前 en0 是 VPN 隧道已退出后的系统路径，不能误判为本工具 /32 残留。未执行 reset、未终止 VPN 进程、未重启系统服务。

运行的 GUI 为 /Applications/StrongVPN Client.app（1.2.0 build 200），其内置二进制版本字符串 OpenVPN 2.3.16，2017-05-19 构建。本机另有 StrongVPN.app 2.4.5 build 142651，含不同版本核心，但本次运行的不是该 GUI，未切换、升级或替换厂商文件。

OpenVPN 官方历史 ticket 670（https://community.openvpn.net/openvpn/ticket/670）记录同一 misc.c:785(es) 断言：2.3.x 重启期间退出路径可能将空 env_set 传给环境设置，导致异常退出；上游称 2.4+ 环境处理不同。当前旧版本、ping-restart 与相同断言高度吻合，是具体候选缺陷，但未取得本机调用栈和触发信号，不能认定已证明完全相同的竞态。尤其当前网络可用，尚未复现用户描述的“退出 VPN 后仍全机断网”，该症状根因保持未定。

本轮没有新的源码变更。已验证的新结果是本工具睡前正常撤销和结束日志、睡后 noRecovery，以及第三方后台实际异常。不可据此宣称通用睡眠稳定性或第三方故障已修复。

## 用户确认后的收敛范围

2026-09-30 用户明确暂停 StrongVPN 调查，接受本工具本次睡眠撤销及唤醒核查为通过，继续自身软件开发。此结论有 closed/owned0/cleanup=none 和 noRecovery 原生证据支持；不将首次恢复标记异常改写为成功，不宣称所有睡眠条件均通过。WireGuard 与未来 OpenVPN 自有后端单独测试睡眠/重连。第三方修复、升级/切换客户端及全机重置不占当前主线。
