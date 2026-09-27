# EX-INT-02：有限前台执行、读回与撤销候选

日期：2026-09-27。起点 main `1776b4cfaf2f925f31a63a98e304c21190ea1f34`。任务 S4-02/03 部分；EX-03/05/07/08、SEC-02/03、FAIL-03、REL-02。设计见 [ADR](../adr/ADR-EX-INT-02-foreground-route-lease.md)，操作见 [入口](../external-execution.md)。

## 这批实际新增什么

新增独立前台 `VPNExternalLease`，实际调用 shared macOS collector → ExternalPlanner → 事务/日志 → PF_ROUTE GET/ADD/DELETE → 完整路由读回和逆序撤销。不是只输出路由命令或另一份预览。原 GUI 的采集代码移入 ExternalCore 公共只读组件并保留 actor 包装；`canApply` 仍为 false，没有解锁 GUI 按钮。

有限执行需操作员明确的 OS 管理员权限和真实终端 APPLY 确认；程序不自提权，不安装/接入 SMAppService，不接收任意 IPC 计划。最多 8 个 /24–/32 结果、2048 地址、默认 60 秒不续租；原 VPN/默认路由/DNS/凭据不写。root 私有标记先同步再修改路由，未知写入或清理无法确认则阻断下一次新写入。

每项匹配内核 type/pid/seq/键/接口/errno 后才能发回执，再以完整路由表核对。预先存在的条目不认领；相同字段替换事件也撤销回执。部分失败会尝试清理先前可确认项；丢失归属、scoped 冲突、未知响应不猜删。末尾独立快照比较只报告 observed unchanged/changed/notObserved，不宣称实际出口、DNS 行为或全系统已恢复。

**EX-INT-02 尚不是全部完成或可发行 External。** GUI 授权 Helper 仍未实现；本机管理员直接启动的前台工具不等于经过身份验证的 GUI IPC。BSD 无原子 compare-delete，已知竞争/事件缺口拒绝，但不能排除所有特权 ABA/无通知变化；SIGKILL/挂起/崩溃后不能保证撤销。旧标记只 audit，不重建删除权；全 scope 候选及更具体路由缺失后才能清除标记。限无争用、可恢复的受控工程环境。

## 实际执行的验证

Linux x86_64，Swift 6.2.1；Mac Runner 对原项目仍返回 project_path_not_found。工作区从固定 GitHub 基线恢复，为部分源码工作区；ExternalExecution 新包及其文件完整。ExternalCore 使用原样完整 Observation/Preview 和移出的完整 collector；依赖 PolicyCore 原样完整 IPv4/Policy/Compiler/manifest，逐个原始 Git blob 已核对。没有恢复 Constraints.swift、旧 PolicyCore 测试或整个工程，不宣称全仓构建。

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| Swift Debug | 35 项 XCTest 通过，warnings-as-errors | 26 项真实事务/Planner + 合成内核观察；9 项实际临时文件/锁/标记测试 |
| Swift Release | 同一 35 项通过 | 优化重跑，不算另外 35 个独立场景 |
| tests/external_execution | 6 项 Python 完整通过 | manifest/入口/只读分离/build 参数与命令分发/原生 Swift parse + 下列 C harness |
| C 适配器 harness | 内含 15 场景通过 | 实际 Darwin 分支方法体；布局、内核与 syscalls 明确替身；-Wall -Wextra -Werror |
| 旧 EX-01 选定合同 | 4 项通过 | 本地依赖、共享只读源、选定原生源 parse、旧入口分发；未重跑旧 29 项 Swift 或其余 2 项 Python |
| 新实际入口 | dev.sh external-execution-test 退出 0 | 就本部分工作区执行上述新包/6 项 Python；无提权、无真实路由 socket |

事务覆盖同意/过期/取消/倒退时钟/预算、完整基线变化、已存在条目不删除、部分失败逆序回滚、未知 ADD 不按同值认领、读回缺失、DNS 变化、空闲失效、已知事件缺口、同值外来替换、scope 冲突、DELETE 失败/假成功、日志失败与脱敏。临时文件测试覆盖重复写者、损坏/超限日志、符号链接/权限、同名替换、审计时不得替换候选集合。

C harness 在临时测试副本启用真实 Darwin 分支，并将系统头替换为显式 fixture；生产源无测试开关，也不将 fixture 编入产品。测试匹配 ACK/EEXIST、错误 seq/type/index、丢 ACK、不发送重复写、相同键事件撤销、GET 与 DELETE 之间事件阻断、截断/错误版本、/24 与 /32、关闭不隐含撤销。输出 `routing-socket-adapter=PASS scenarios=15 source=ACTUAL darwin_kernel_io=TEST_DOUBLES network=NOT_APPLIED`。这是接口算法测试，不是 Darwin ABI 或实际内核权限测试。

复查修正：测试内不能把无掩码 GET 请求当成完整响应解码；修复的是 fixture，未放宽产品响应校验。删除请求最后一次事件排空后重新核对回执，避免已撤销回执继续 DELETE；审计绑定原候选数组，拒绝调用者换成同数量的其他目标。日志 begin 失败保留不确定状态。所有修改后重跑新完整入口。

## 未执行项目

Apple SDK C/Swift 类型检查/链接、macOS 实际 PF_ROUTE 响应/权限/netstat、GUI、真实管理员确认/信号、内核竞争与真实流量、VPN/直连双路径、睡眠和崩溃恢复均 NOT RUN。Swift 的 arm64 macOS frontend parse 仅语法；测试替身不升级这些状态。新入口本机构建应先运行 external-executor-build；无开发证书/Go/WG 签名要求，构建不执行产物。

当前只读源的 UI actor 接线保留；新 GUI Helper 尚无实现，不应让用户以 root 运行预览 App。OpenVPN 本批未实现。WG 已有用户原生构建和 S0 样本保留，不重跑、不扩展为本批成功。

本轮未读取用户真实网络/配置/密钥，未写用户路由/DNS、未停原 VPN、未安装服务/工具、未改签名/权限。测试只用合成地址和独立临时目录；不清理用户缓存/锁。更新 roadmap 与验收表，main 非强制统一交付，无更新包；回滚后仍须保留任何本机恢复标记，代码 revert 不等于路由已撤销。
