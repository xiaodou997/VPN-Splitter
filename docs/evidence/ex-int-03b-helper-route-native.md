# EX-INT-03B：Helper 路由真机与 XPC 错误回调修复

日期：2026-09-30。原测试版 y59aj_d8；修复后 _ljw7pff。用户已现场确认 VPN/控制条件，随后授权本轮软件测试全部操作及同一个 IPv4 目标；目标仅保留本机忽略文件，不写入仓库。GitHub 同步按用户要求暂停。

## 自动化与异常样本

用户授权 AppleScript 操作测试应用，开启辅助功能权限后已能直接读取原生 UI、操作预检/开始/停止。预检核对选中方案仅一条旧目标 /32，Helper 提案 wouldAdd/en0。初次自动化在 UI 更新时未完整取得终态；独立目标路由恢复 utun8、后续 Helper 核查 noRecovery。该次不计正常停止通过。

后续真实执行取得 active/add 成功及目标 en0，但控制 App 在 NSXPC 错误回调触发 EXC_BREAKPOINT。本机崩溃栈为 `_dispatch_assert_queue_fail` → Swift executor 检查 → `ExternalHelperClient.send` 错误闭包。目标独立确认已回 utun8，重开 App 核查 noRecovery。不能将该次意外退出直接作为完整崩溃恢复验收，也未做管理员全路由扫描；sudo 非交互审计无缓存凭据未执行。

## 修复与原生回归

对 Foundation `remoteObjectProxyWithErrorHandler` 的跨线程回调显式添加 `@Sendable`，仅通过 Task 返回 MainActor。保留所有签名、root UID、超时、单请求和失败关闭约束。

新增 `test_native_xpc.py`：使用实际客户端代码和真实匿名 NSXPCListener/NSXPCConnection，身份与 SMAppService 为显式替身。覆盖正常 hello/recoveryAudit 与服务端中断错误，Debug/-O 均通过。把旧闭包代回同一测试，两种优化级别均失败，证明回归能检出缺陷。完整 Helper 测试（ExternalControl Debug/Release + 15 项合同/原生测试）通过。

route-trial 签名原生构建 _ljw7pff 通过，公证 `0d9edcd8-6078-47d7-a7b0-0bf525a8fa58` Accepted，staple/validate 通过。旧服务经 GUI 查询/quiesce/注销后独立确认不存在，退出旧 App 后安装新候选，strict codesign 与公证票据再次通过。重新注册 enabled，恢复核查 noRecovery。

## 正常停止样本：PASS

Agent 直接从原生 UI 观察并独立查询目标路径：

- 起始目标 utun8；Helper 单 /32 wouldAdd/en0 提案匹配本机目标。
- active：添加响应及读回通过；原生 stage=add、reason=none、mutation_attempts=1；独立查询目标 en0。
- 通过“分流 → 停止 / 撤销当前会话”菜单停止。
- 终态：closed；code=none；owned=0；comparison=unchanged；stage=delete、reason=none、system_errno=0、reply_errno=0、reply_type=2、mutation_attempts=2。
- 独立查询目标回 utun8。

这是本次真实 Helper 添加/正常撤销闭环证据；尚不等于实际 HTTP 双出口、60 秒自然到期、睡眠/切网、全系统零残留或完整 External MVP。后续测试分开记录。

## 60 秒到期测试：被网络变化提前终止

已授权的单目标自然到期尝试在 active/en0 维持约 27 秒后收到 closed/networkChanged；剩余回执 0、comparison=changed、DELETE stage reason=none、reply_type=2、mutation_attempts=2，独立目标路由恢复 utun8。没有人工停止。这证明本次快照变化触发清理，**不是 60 秒自然到期 PASS**。待补充 Helper 侧脱敏快照差异，先观察网络变化，不关闭 epoch 检查。

## Helper 脱敏快照诊断

Helper 原先只转发原生路由 I/O 摘要，遗漏事务已生成的 snapshotChangeSummary / observationErrorCode。现在附加现有布尔值/计数与枚举错误码，不含目的地址、网关或 DNS；不改变严格 epoch 比较或失败行为。完整 Helper 回归 15 项通过，签名 route-trial 构建 _n38w3gd 通过，公证 `5777890c-6d70-45b7-a848-8f232d5d39a4` Accepted，staple/validate、安装后 strict codesign 通过。经安全注销/退出后更新并重新注册 enabled，GUI 核查 noRecovery。

只读观测 300 次 capture_stable=300、changed=0、errors=0（无活动路由时）。用户指定目标的 HTTP 80 HEAD 请求在 VPN 基线超时，未建立 TCP；不计真实双出口通过，已询问有效协议/端口。下一次租约诊断另行记录结果。

## App 意外退出样本

Agent 在 active/add ACK/readback、独立 en0 查询后，对唯一的控制 App 进程发送 SIGTERM（不是 GUI 正常退出路径）。约 0.42 秒后独立目标查询恢复 utun8。Helper 持续运行；重启控制 App 核查 noRecovery。此为一个失联清理样本，不等于 Helper 自身崩溃、睡眠/切网或十次稳定性循环全部通过。

第二次自然到期尝试约 47.9 秒提前 closed/networkChanged，DELETE 无错误、零回执、目标回 utun8。新增诊断为 interfaces_changed=false、physical_paths_changed=false、dns_changed=false、routes_added=1、routes_removed=1。并行用户态观察器只记录测试 /32 的添加和删除，未捕捉这次瞬态替换。心跳挂起试验随后在 apply 前因相同差异拒绝（mutation_attempts=0），未实际挂起 App。

为继续定位，事务另提供最多各两条 added/removed 的脱敏形态（前缀长度、受限旗标、en/utun/other 类别、网关类别、Expire 状态），不输出地址、MAC、接口 ID。严格比较不变。实际执行器回归及签名 Helper 原生构建通过；21__4g4m 公证 `02f51c5c-7897-48ec-a755-b8f0907c0092` Accepted、票据/签名校验通过，经安全注销后安装注册。下一次原生差异仍需实际记录，不能以诊断代码替代根因结论。

## 心跳丢失样本与路由标志定位

后续心跳测试成功进入 active/en0；Agent 对唯一控制 App 进程 SIGSTOP，约 9.99 秒目标回 utun8，再 SIGCONT 恢复 App。原生 UI 最终 closed/none、owned=0、comparison=unchanged、DELETE reason=none、mutation_attempts=2。此为单次真实心跳丢失样本，不等于系统睡眠。

另一轮自然租约在约 22.3 秒提前结束，新增形态：added=`p32/f=UHLWIi/if=en/gw=other/expired=true`，removed=`p32/f=UHLWI/if=en/gw=other/expired=true`。终态 closed/networkChanged、owned=0、DELETE 无错误，目标回 utun8；postComparison=notObserved，不能声称完整快照相同。

macOS 本机 SDK route.h 与 [Apple XNU route.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/route.h) 说明 RTF_IFREF 是接口引用标志；[Apple netstat flags 映射](https://github.com/apple-oss-distributions/network_cmds/blob/main/netstat.tproj/route.c) 将它输出为小写 i，RTF_IFSCOPE 输出为大写 I。形态相似还不能证明目的、网关等实际字段相同。因此另加入只用于诊断的 ifref_only：在完整路由集合比较中仅移除 i 后比较所有其余字段，仍保持原严格拒绝。测试覆盖纯 i 变化以及 MAC/接口/Expire 变化，后者不得误报为 ifref-only；不输出原始值。实际容错策略尚未修改，须根据原生结果及 ADR 再决定。

## IFREF-only 证据与 epoch 修复

2ys338x_ 诊断版公证 `bba4b40d-1e6e-4e7f-8ac4-01ddadd3dfc2` 通过并安装。真实租约约 52.6 秒收到 networkChanged；诊断 `ifref_only=true`，完整集合去掉小写 i 后其余字段相等，形态 UHLWI↔UHLWIi、/32、other 接口、Expire=false。DELETE/零回执、目标恢复 utun8，停止后 snapshot=unchanged，说明是瞬态引用标志误报。

先新增 ADR-EX-INT-04，再引入 ExternalRouteEpoch 独立视图，仅 /32、精确 UHLWIi→UHLWI。采集器的双读一致性、事务 epoch、停止后比较使用此视图；原始路由、规划与所有权/DELETE 读回不变。归一化键碰撞退回原始集合。Core/Execution 完整回归通过，覆盖 MAC、地址、接口、Expire、作用域、非 LLINFO/非 /32/owned flags 和重复键。额外执行器测试确认自有路由 flags+i 仍使 recoveryRequired、不删除，Debug/Release 均通过。

签名 route-trial 原生候选 u1jlrkz0 编译通过；后续公证/安装与原生 60 秒复验另记，不能以离线回归宣布租约通过。

## 修复后的自然租约到期：PASS（单样本）

u1jlrkz0 公证 `4b11be5b-5bbf-410b-9973-67c1df1458bd` Accepted；票据/严格签名验证通过，经安全注销后更新、重新注册并核查 noRecovery。Agent 重新核对单目标 /32 提案，active 后独立观察目标 en0；不发送 stop，不断开 App。

本机自动化从确认/点击前开始计时，首次捕获终态约 64.7 秒：closed/none、owned=0、comparison=unchanged、stage=delete reason=none、system_errno=0、reply_errno=0、reply_type=2、mutation_attempts=2；独立目标恢复 utun8。这是有限 60 秒租约自然终止样本，时间包含 GUI 操作、采样与清理调度，不是内核硬实时期限保证。此前被 IFREF 元数据提前中断的样本保留为失败/诊断证据，不被覆盖。

## 连续正常停止与 App 失联循环

修复版连续 10 次 GUI prepare/apply→normal stop，全部校验单目标、active/en0、closed/none、owned=0、unchanged、DELETE reason=none / mutations=2，并独立确认回 utun。任何失败即停止批次，无失败后自动重试。

随后连续 10 次 active/en0→对唯一控制 App SIGTERM→独立确认 utun→重启 App→noRecovery，全部通过。循环前后 `scutil --dns` 原始观察在本机逐字比较一致，未将 DNS 内容写入仓库。本机原始逐轮日志在 gitignored `.local/external/gui-trials/`。这是 App 失联循环，不是 Helper 崩溃、睡眠或切网循环。

## 实际应用流量与双路径样本

仅访问用户授权 IP 的标准 HTTP/HTTPS 端口与公开 HTTPS 对照 `example.com`，无账号/密码/业务载荷。

- VPN 基线：目标 HTTP 80 与 HTTPS 443 均连接超时。HTTPS 进程的 nettop 记录为 utun8/SynSent，没有成功 HTTP 响应。
- DIRECT 例外期间：HTTPS TCP 成功建立，socket 本地地址匹配 en0；严格 TLS 验证因证书 SAN 不匹配 IP 返回 curl 60，没有禁用校验，不能记作 HTTPS 业务成功。
- 独立 HTTP 试验：同一目标 TCP 连接 established，nettop 关联本测试进程并显示 en0，socket 本地地址与 en0 相同；HEAD 返回 `HTTP/1.1 200 OK`。
- 同一活动 lease 内：HTTPS 对照返回 200、证书验证成功，socket 本地地址匹配 utun8，远端查询路由也为 utun8。
- 正常停止：closed/none、owned=0、unchanged、DELETE 无错误，测试目标路由回 utun8。

这是 socket/进程层面的实际请求、响应与接口证据，不是服务端观测的公网 NAT 出口或物理链路抓包；不泛化到所有应用/VPN/域名规则。目标 HTTPS 若要端到端成功仍需实际服务域名，不能用 IP 名称不匹配错误冒充认证成功。

实际双路径停止后的新 HTTP 连接再次由 nettop 标为 utun8，并恢复 VPN 基线的连接超时；DNS 观察与 App 失联循环前仍逐字一致。本轮没有调用原 VPN 的配置/认证修改。
