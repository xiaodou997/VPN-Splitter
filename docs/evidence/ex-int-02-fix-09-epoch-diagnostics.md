# EX-INT-02-FIX-09：写入前网络变化的脱敏诊断

日期：2026-09-29。基线 `main` `c0bc002`。关联 EX-INT-02 / FIX-08、EX-03/05/07/08、DIAG-02/03。没有放宽会话对接口、物理路径、DNS 或完整 IPv4 路由集合的保守比较。

## FIX-08 首次复验结果

用户在 Mac 前确认对上次单目标执行一次 60 秒路由实验。新产物此前 `inspect` 为 `wouldAdd`，原生 GET `probe=PASS`。用户在本机终端运行 `apply` 后只提供脱敏末尾诊断：

```text
route_io_schema=external-route-io-v1 stage=none reason=none mutation_attempts=0
state=closed owned_receipts_remaining=0 snapshot_comparison=changed
failure=networkChanged
```

本机同时运行的只读 `route get` 监测在执行器出现和退出时均观察到目标走 `utun8`，没有采样到物理接口阶段。`mutation_attempts=0` 表示该执行器的本次原生上下文没有尝试 ADD/DELETE；不能据此声称 FIX-08 ADD ACK / DELETE ACK 或自动撤销通过。后续 20 次、每秒一次的本机 `ExternalSystemSnapshotReader` 只读采样中，路由、接口、物理路径和 DNS 类别均稳定；这不能追溯定位刚才的瞬时变化。用户完整目标、网关和原始路由表未入库。

## 代码改动

会话仍在任一网络 epoch 差异时原样拒绝写入。新增 `snapshotChangeSummary`，只在快照不一致时给出接口、物理路径、DNS 是否变化及路由增加/减少条数；CLI 对失败会话输出 `snapshot_change=...`。诊断不包含地址、网关、接口名称、DNS 值或原始行，也不改变权限、路由操作、恢复判定、重试或租约。

## 验证与下一步

- `external-execution-test` 初次运行时，原生 CLI 拼接测试的 `ExternalLeaseTransaction` 替身缺少新增属性，导致该测试编译失败；补齐替身后整套重跑通过。增加 DNS 变化与无关路由变化两种 fail-closed 断言，并检查诊断不泄露路由地址。测试替身不能当成真机网络稳定性证据。
- `external-executor-build` 在 Mac 上输出 `compile=PASS`、`execution=NOT_RUN`；新精确产物 `.local/external/executor.7aanoup_/VPNExternalLease`，SHA-256 `ab95f2285b63dc80c189aa53c44bd7f208edcb5f6fccacf7c93acb8f98668244`。构建不运行或写路由。
- 用户随后用该产物做管理员只读 `audit`，得到 `journalFailed`，没有候选计数。回读日志实现发现：`active` marker 不存在时，旧 `auditCandidates()` 也会返回 `journalFailed`。用户在本机只读核查并回报：目录 owner 0 / mode 700、锁 owner 0 / mode 600、`active=absent`；该结果与“无 marker”路径吻合，未读取 marker 内容或删除任何文件。
- 将 `openat(active)` 明确返回 `ENOENT` 的情况处理为 0 个审计候选；其他打开错误、错误权限、符号链接和坏内容继续拒绝。`clear-absent-marker` 对 0 个候选仍不能清除或取得删除权。新增缺失 marker 负向测试后，`external-execution-test` 再次通过；Mac 新构建 `compile=PASS`，精确产物 `.local/external/executor.gz5ie8nz/VPNExternalLease`，SHA-256 `a98b4bee411cdb3988a502d57600c3de8f66ba2a6bc7e3c9b9ce703061a551e3`。新产物的 root 只读审计仍待本机确认。
- 用户用修复版新产物做管理员只读 `audit` 后反馈 `audit_candidates=0 present_or_ambiguous=0 route_writes=NONE`，记为 **USER_REPORTED PASS**；与本机确认的 `active=absent` 一致。新产物对同一私有目标重新运行只读 `inspect` 和原生 GET `probe`，分别为 `wouldAdd` / `network_settings=NOT_APPLIED` 与 `native_route_probe=PASS` / `mutation_attempts=0`；独立查询目标仍走 `utun8`，新产物 SHA-256 复算和 strict codesign 通过。
- 若需要再次做单目标写入，须另行现场授权，并在本机稳定窗口观察新增的 `snapshot_change` 分类；不因一次 20 秒稳定采样就降低 epoch 比较要求。

当前 FIX-08 的真实 ADD ACK、readback、DELETE ACK、自动撤销和真实双出口仍 **NOT RUN**。未修改第三方 VPN、DNS 或默认路由。
