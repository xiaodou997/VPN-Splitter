# EX-INT-02-FIX-06：原生查询预检与写入不确定性的区分

日期：2026-09-28。基线 `b147a0d36adb5201e596480ff0d302dcdac9c582`。关联 EX-INT-02、EX-03/05/07/08、DIAG-02/03。External 优先和原[执行限制](../external-execution.md)不变。

## 用户结果与当前处置

用户报告：应用前目标查询走原 VPN；明确运行已通过 inspect 的执行器并输入 APPLY 后，输出 `state=recoveryRequired owned_receipts_remaining=0 snapshot_comparison=unchanged`、`failure=routeUncertain`。这是一次真实 apply 失败，不是编译或物理路径识别失败。没有 ADD 成功/读回 PASS，也没有应用后独立 route get/audit 结果。

零回执不证明零写入；unchanged 只表示有限快照对照。当前不能声称已添加、已撤销或完全没有写入。旧恢复标记必须保留，不重复 apply，不 flush、不猜删。先用原确切产物 audit，并独立查询目标路由；audit 只查标记和候选残留，不给删除权。原生响应字节/阶段未提供，不能指定本次的精确内核触发原因。用户网络地址、接口和完整目录不入库。

## 已确认并修正的代码缺陷

旧 `er_add` 在真正 ADD 之前先执行目标和物理网关两次 RTM_GET。任一 GET 超时或响应不匹配，旧代码也返回 uncertain；Swift 事务因此保留未知写入状态及恢复标记。用原样旧 C 源加模拟 GET 超时，复现 `status=2`、`add_calls=0`、路由未增加。**这是确证的错误分类缺陷，不等于已经证实用户现场就发生在 GET。**

新增状态 3，仅表示本次 ADD 调用在发出 ADD syscall 之前已停止。NativeRouteDriver 将其映射到现有 rejected 路径，事务不再凭该次查询失败认定未知 ADD；多条规则中先前已取得的回执仍走原逆序清理。ADD syscall 一旦尝试，负返回、缺失/错误响应仍不能据此当作没有写入；unknown 继续保留。已有标记不自动清除，不从标记重建所有权。没有修改事务、日志、回执匹配、解析和拓扑判断的原有条件。

## 新增 probe：不再通过重复写入定位

`VPNExternalLease probe <IPv4/CIDR> ...` 使用当前真实采集和有限规则检查，然后复用 er_add 的同一个原生 preflight；只发送 RTM_GET，不执行 ADD/DELETE、不创建事务、不读写 root 恢复标记，不主动向目标发送网络探测流量。默认普通用户运行，无自行提权。即使调用者是 root，query-only 上下文在公开 API 和最底层发送点都禁止修改操作；probe 成功没有回执，也不能授权以后写入。

查阅于 2026-09-28 的一手依据：[Apple XNU rtsock.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c)，rts_attach 无条件按普通 route socket 附加；route_output 明确将 RTM_GET 与需要特权的其他消息分开。该源码支持选择公开 GET 路径，不是本机 OS 运行验收。未复制上游实现或增加依赖。

新增 `route_io_schema=external-route-io-v1`：阶段（targetGET/gatewayGET/add/removeGET/delete）、原因、decode_field、syscall errno、reply errno/type 和 mutation_attempts。记录首个失败，后续清理不覆盖；不打印原始消息、IP、接口、PID/seq、token 或其哈希。mutation_attempts 是当前上下文 ADD/DELETE syscall 尝试数，非成功次数，不能解释成整台机器的写入计数。GET 虽使用 write(2) 发送查询消息，但不计为路由修改。

decode_field 是现有拒绝条件的位置编号：1 头长度；2 头格式/版本/地址位图；3 地址起始边界；4 地址长度/对齐边界；5 IPv4 地址结构过大；6 IPv4 地址过短；7 掩码 family；8 目的/网关 family；9 IFP 格式；10 接口索引冲突；11 消息尾部/缺目的地址；12 host 掩码；13 非连续掩码；14 目的地址非规范网段。0 表示没有该层拒绝。本批不放宽这些条件、跳过事件或把未知响应视为成功。

## 实际验证

Linux x86_64 / Swift 6.2.1，固定基线的部分源码验证目录。完整原 C、头文件、NativeRouteDriver、CLI、旧 C harness/fixture/Python 测试均核对原 Git blob；不是完整仓库或 Apple SDK。生产源没有测试开关或测试头引用。

- `python3 -m unittest discover -s tests/external_execution -p 'test_native*.py' -v`：4 项通过。
- 原 C 适配器测试保留原 15 组，增加 16 组，共 31 组（参数循环不另累计）：普通/root 查询上下文、底层禁止写入、目标/网关 GET 的超时/解码/错误 seq/type/截断/errno、选路不符、ADD 发出前事件失败、ADD 未确认、明确 EEXIST、DELETE 未确认、首个失败保留。实际 Darwin C 方法体执行，内核/ABI/系统调用为明确替身。
- 两项 Swift 测试编译执行实际完整 NativeRouteDriver 与实际 CLI run 方法：Debug/优化、Swift 6 strict-concurrency=complete、warnings-as-errors。每种模式运行同一 4 组：probe 成功、失败、无需添加、C 返回值映射。C 接口、拓扑、系统采集和事务/日志为明确替身；probe 若碰事务、日志或写操作则失败。不是端到端内核/Swift 联调。
- 第四项包含修改的 macOS Swift frontend parse 与 Python 3.9 语法检查；parse 不是 Apple SDK 类型检查。
- 实际 C harness 在 AddressSanitizer/UndefinedBehaviorSanitizer 下通过。原样旧代码复现 GET 未发送 ADD 却返回 uncertain；临时撤回分类修正，新测试按预期失败。测试开发期间移除了与系统 fflush 重载冲突的多余测试替身，没有为此改产品逻辑。

未重跑 35 项事务/文件日志 XCTest、41 项核心、旧解析/签名/预览全套；未执行新 Mac 构建、原生 probe、apply、audit、路由修改、权限获取或 Helper 安装。现场原生响应问题仍待定位，不把本批称为实际分流已修复。

## 本机操作

先回传应用后目标 route get 和原产物 audit。暂不 clear-absent-marker 或再次 apply。随后普通用户更新、运行上述 4 项针对性测试，并 `dev.sh external-executor-build`。使用本次输出的新 Executable 精确路径执行 `probe <同一个目标IPv4>`；旧复制产物不会被 git pull 更新。只需回传 probe 的 route_io_schema 行、结果和上述审计摘要，不需要原始网络表或密钥。

probe 即使通过，也不等于 ADD/DELETE 或实际双出口通过。它不会消除旧 recoveryRequired，也不检查旧标记；旧记录仍需独立核查。保留原 GUI 只读、短租约、原 VPN/DNS/默认路由和所有已存证据；不催办 WG 签名。main 非强制追加交付，不发更新包，不清缓存/锁/恢复记录。
