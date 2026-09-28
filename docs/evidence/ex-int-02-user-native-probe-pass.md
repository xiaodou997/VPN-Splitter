# EX-INT-02：用户报告原生 GET 预检通过

记录日期：2026-09-28。记录前远端 main：`e76876fff154160b6420c4ac42f4ff72cc183db6`。关联 EX-INT-02、FIX-06/07。External 优先；沿用[前台执行边界](../external-execution.md)。

## 本次结果

用户明确使用新产物 `executor.zjw15la8/VPNExternalLease`，对同一个本机单目标运行 probe。该次输出包括物理接口、原 VPN 接口线索、通过当前物理网关的 `/32` wouldAdd 提案，以及：

```text
probe_index=1 route_io_schema=external-route-io-v1 stage=gatewayGET reason=none decode_field=0 system_errno=0 reply_errno=0 reply_type=4 mutation_attempts=0
native_route_probe=PASS; traffic_paths=NOT_VERIFIED; network_settings=NOT_APPLIED
```

证据等级：**USER_REPORTED PASS — 当前现场的目标及物理网关原生 RTM_GET 预检**。回读当前 C preflight 与 CLI 可确认：gatewayGET 只在目标 GET 回包及目标路径约束通过后执行，最终 PASS 要求物理网关查询和路径约束也通过。不是只有第二个查询单独通过。

本次已经越过此前 targetGET/decode_field=7 的拒绝点；FIX-07 的掩码兼容修正在这个样本上取得现场查询成功证据。mutation_attempts=0 表示本次上下文没有尝试 ADD/DELETE syscall，不是整台机器的写入计数，也不反推旧执行器 apply 的全过程。用户的完整路径、目标、网关及接口名称不在本文展开。

本次没有独立提供新产物的源码指纹、SHA-256 或完整构建/测试摘要，不从运行结果推导本地源码逐字等于远端、不增加全量测试通过数量。旧原生构建证据继续保留，未要求为这些缺字段重建。

## 历史失败与恢复状态分别保留

此前真实 apply 返回 recoveryRequired/routeUncertain，不能改记为成功。其后用户独立 route get 显示目标仍走原 VPN，并报告 `audit_candidates=1 present_or_ambiguous=0 route_writes=NONE`：只说明那次审计未观察到候选残留，不说明此前一定从未写入。

本次 probe 不读取或清除旧恢复标记，标记清理仍未执行或验收；也未执行本轮 ADD、DELETE、实际流量访问、DNS 查询或 GUI Helper 验证。查询通过不是写入授权或后续网络状态保证。

## 下一步的操作条件

复用本次明确通过 probe 的产物，不为本证据文档重新构建。只在用户有本机控制、明确允许目标直连、可恢复且无路由争用或企业强制策略的环境中继续；原 VPN 保持连接，不通过依赖它的唯一远程通道测试。

先使用现有 `clear-absent-marker`。该命令会重新取得私有日志锁、读取记录、采集当前网络，并要求记录中全部候选及更具体路由在所有 scope 下均不存在，才删除经 inode 核对的本工具 active 标记；不删除路由、不修改 DNS、不删除锁文件。不是因为 probe PASS 就忽略旧记录，也不是依据过时的 audit 结果直接清除。

仅在输出 `journal_marker=CLEARED_AFTER_ABSENCE; routes_and_dns=NOT_MODIFIED` 且命令成功后，才另行进行经操作员授权的单 `/32`、不续期短时 apply。清理失败、标记缺失/损坏或候选存在时停止，不用 rm/flush 或盲目重试绕过；这不是自动执行指令，本轮助手没有执行这些操作。

应用前以新的目标路由查询记录基线；程序会重新采集并展示提案，操作员核对后输入 APPLY。看到 add ACK/readback PASS 后，在另一终端记录目标路由，随后按回车请求正常停止，再记录停止后的路由及执行器完整诊断。60 秒到期会请求停止，但不是内核自动到期保证；不关闭窗口、强杀或主动切换网络。

即使 state=closed、owned_receipts_remaining=0、snapshot_comparison=unchanged，也只是有限事务及快照证据。实际 DIRECT/VPN 双路径、独立 DNS 行为、异常恢复和授权 Helper/GUI 仍待验收。再次出现不确定状态时保留新标记及日志，停止新增写入。

## 本次仓库操作

只新增此证据文件。回读当前 CLI、C preflight、日志清理代码及运行说明；没有修改产品源码、权限、依赖、构建脚本或测试，没有执行本机构建、测试、网络采集、probe、标记清理、apply 或服务安装。通过 main 正常追加提交；不提供更新包，不清除缓存、锁或历史证据。
