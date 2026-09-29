# EX-INT-02-FIX-08：单目标正常停止真机闭环

日期：2026-09-29。关联 EX-INT-02 / FIX-08、EX-03/05/07/08。执行环境为用户在本机操作的 macOS 26 arm64，StrongVPN 保持连接，另有独立控制通道。沿用此前已人工恢复、仅存于 `.local/` 的真实单目标 IPv4；地址、网关及原始路由表不入库。

## 前置与结果

本次为第三次受控尝试。第一轮在写入前 `networkChanged`、`mutation_attempts=0`；第二轮取得 ADD ACK/readback 后因 `observationFailed` 保守停止，清理成功但不是正常停止。两轮结果与诊断分别见 [FIX-09](ex-int-02-fix-09-epoch-diagnostics.md)、[FIX-10](ex-int-02-fix-10-observation-diagnostic.md)，不能改写为成功。

第三次用户再次现场授权，使用精确产物 `.local/external/executor.ibba2c99/VPNExternalLease`；管理员只读 `audit` 为零候选/零残留（**USER_REPORTED**），目标 `inspect` 为单条 `/32` `wouldAdd`、原生 GET `probe=PASS`、应用前独立查询走 `utun8`。用户在本机终端核对提案、输入 `APPLY`，看到 ADD ACK/readback 后按回车请求正常停止，回传脱敏结果：

```text
route_add_ack_and_readback=PASS; traffic_paths=NOT_VERIFIED; dns_writes=NONE
route_io_schema=external-route-io-v1 stage=delete reason=none reply_errno=0 reply_type=2 mutation_attempts=2
state=closed owned_receipts_remaining=0 snapshot_comparison=unchanged
traffic_paths=NOT_VERIFIED; no_system_restore_guarantee=true
```

没有 `failure`、`snapshot_change` 或 `observation_error` 行。当前事务代码只有在 ADD 精确回执和添加后全表读回通过、进入 active 时才打印首行；停止时只对本次回执执行 DELETE，需删除响应确认及其后全表缺席，才能清空所有权并得到 `state=closed`。因此结合末尾 `stage=delete reason=none reply_type=2 mutation_attempts=2`，本机这一次短时正常停止的 ADD/DELETE 回执及撤销读回可记为 **USER_REPORTED + 代码路径支持的 PASS**。

助手随后独立 `route get` 确认目标重新走 `utun8`；用户再以同一产物做管理员只读 `audit`，报告 `audit_candidates=0 present_or_ambiguous=0`（**USER_REPORTED**）。没有手工 delete、flush、清锁、改 DNS、停用或重配 StrongVPN。

## 验收边界

FIX-08 后的单目标正常停止自动撤销门槛，在本机这次样本上关闭。它不证明其它目标、不同 VPN/网络形态、60 秒自然到期、睡眠/切网/重连、崩溃恢复或 BSD 竞争下都能安全撤销。active 阶段没有独立采集真实物理出口流量；原 VPN 其它目标与 DIRECT 目标的 TCP 双路径仍 **NOT VERIFIED**。认证 Helper/GUI 尚未使用本次写路由能力。
