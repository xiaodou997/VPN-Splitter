# EX-INT-02-FIX-10：ADD/DELETE 真机回执与周期观察失败

日期：2026-09-29。基线 `main` `ad616af`。关联 EX-INT-02 / FIX-08、EX-03/05/07/08、DIAG-02/03。本次仍是单目标、60 秒、用户在本机终端明确确认的前台工程实验；没有 Helper/GUI 授权或 Flow DIRECT 数据面。

## 第二次真机实验

实验前修复版管理员只读 `audit` 为 0 候选、0 残留（**USER_REPORTED PASS**）；目标只读 `inspect` 为 `wouldAdd`、原生 GET `probe=PASS`、独立选路为 `utun8`。用户现场再次授权、核对单条 `/32` 提案并输入 `APPLY`，回传脱敏结果：

```text
route_add_ack_and_readback=PASS; traffic_paths=NOT_VERIFIED; dns_writes=NONE
route_io_schema=external-route-io-v1 stage=delete reason=none reply_errno=0 reply_type=2 mutation_attempts=2
state=closed owned_receipts_remaining=0 snapshot_comparison=unchanged
failure=observationFailed
```

`route_add_ack_and_readback=PASS` 仅在事务进入 active 后打印，证明本次 ADD 精确回执与添加后全表读回已经越过 FIX-08 的原失败点。末尾 DELETE 阶段 `reason=none`、两次修改尝试、`state=closed`、零剩余回执与快照不变，支持异常停止后的 DELETE 回执和撤销读回已完成。助手随后独立只读查询目标回到 `utun8`；用户再做管理员只读 `audit`，报告 0 候选、0 残留（**USER_REPORTED**）。未记录用户完整地址、网关或原始网络表。

这不是正常 60 秒结束的完整通过：active 后一次周期观察失败，程序保守停止，`failure=observationFailed`。本次没有独立采到 active 阶段的实际物理出口，也没有目标 TCP 流量的双路径证据。`snapshot_comparison=unchanged` 是有限状态对照，不等于全系统恢复保证。

## 只读诊断与代码改动

回读事务可知 active 阶段 `driver.observe()` 或 `checkFresh` 的外部错误会转为 `observationFailed`，旧摘要没有具体错误类别。新增 `observation_error=`，只给出 `ExternalError` 的枚举名或 `routeParse`，不泄露地址、DNS 值、接口、路由行或日志；保留遇到观察失败就停止、只凭本次回执删除的既有安全行为。

使用仓库现有 `ExternalSystemSnapshotReader` 的本机临时只读 harness，以约 200 毫秒间隔连续采样 300 次：稳定 300、类别变化 0、采集错误 0。它证明此时普通无写入条件下不能复现，不证明 active 路由期间必然稳定。

`external-execution-test` 整套通过，新增一次性 `changedDuringRead` 故障注入断言：会话报告安全类别、触发停止、只撤销自己持有的回执，最终 closed/零回执/快照不变。Mac `external-executor-build` 输出 `compile=PASS`、`execution=NOT_RUN`；新精确产物 `.local/external/executor.ibba2c99/VPNExternalLease`，SHA-256 `ff108b1e48b033a58d2e29f6c6a2ba660096cace52e723ccc7d199ab06d013ac`。该诊断版还未在真实 active 会话运行。

## 仍需关闭的门槛

FIX-08 的 ADD ACK/readback 与一次异常清理路径有真机证据；正常停止/租约到期、active 时独立出口、长时间稳定性和 Helper 接管仍未通过。下一次写入若需要，先用新产物做只读审计/预检并取得新现场授权；优先读取 `observation_error`，不得因本次清理成功而静默忽略后续观察失败或循环重试。
