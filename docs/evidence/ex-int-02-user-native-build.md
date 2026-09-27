# EX-INT-02：用户报告执行器原生构建通过

记录日期：2026-09-27。关联 EX-INT-02 / FIX-01；属于构建证据，不关闭 S4 或 External 真实功能验收。此前重复签名失败保留在 [FIX-01 证据](ex-int-02-fix-01-executor-signing.md)，执行限制见 [操作说明](../external-execution.md)。

## 本次用户反馈

用户提供 `test_executor_signing.py` 六项测试均为 ok、`Ran 6 tests`、`OK`。这些是构建脚本的签名流程回归；不能将其中模拟 codesign 的检查算成六项真实系统签名验收，也不推导旧的 35 项 XCTest 或全部回归在本次重新执行。

随后用户提供实际 Mac 构建摘要：

```text
schema=external-executor-build-v1
compile=PASS
execution=NOT_RUN
network_settings=NOT_APPLIED
helper_installation=NOT_REQUESTED
sha256=31bbff68d1ac46c0070614359309654e138714ad5035657e9fa40fb834fca02c
```

本机产物为本次 `executor.y8ru6ydc/VPNExternalLease`，不是此前失败目录中的副本。完整用户目录不入库。上述哈希是用户报告的最终产物 SHA-256，未由助手读取该二进制独立复算。

证据等级：**USER_REPORTED PASS — 前台执行器原生构建与本机 ad-hoc 签名/严格验证流程**。依据本次回读的 `tools/external/executor-build.py`，该脚本在输出 PASS 前完成 Swift/C 编译链接、复制产物、arm64 检查、对本次副本重签名、严格签名验证和最终哈希计算。不是助手在 Mac 上自行执行，也不是将 Linux 替身测试升级为原生通过。

记录时远端 main 为 `c01213f9fb5eb9868be204fccc327dbace9f9ccc`。用户摘要未包含本地 commit、工作区差异、工具链版本或完整日志；不声称本机源码与远端逐字一致，不自动覆盖后续代码。无需为补这些字段重跑已经通过的构建，保留本机日志和产物即可。

## 通过范围与未通过项

| 项目 | 本次状态 |
| --- | --- |
| FIX-01 六项签名流程回归 | USER_REPORTED PASS；系统工具为测试替身 |
| 前台执行器 Mac 原生构建、arm64 和本机签名校验流程 | USER_REPORTED PASS；依据用户摘要及脚本前置检查 |
| 产物执行、真实系统采集及 inspect | NOT_RUN；本次没有运行结果 |
| 路由添加/删除、实际 DIRECT/VPN 双路径、撤销与残留 | NOT_RUN；构建不修改网络 |
| GUI 授权 Helper、界面应用/停止接入 | 仍未实现；前台工具不等于完成产品 |
| 睡眠/崩溃/竞争时的恢复 | 未验收；原有边界不变 |

## 下一步：复用已有产物做只读 inspect

保持原第三方 VPN 由原客户端连接，在普通用户终端使用本次精确产物执行 `VPNExternalLease inspect <本机选择的目标IPv4>`。先选此前需要直连的一个业务目标，不使用 VPN 服务器、DNS、本机地址或大网段作为首次目标。目标只作为参数供规则检查，不自动发起访问探测。

已回读 `ExternalLeaseMain.swift`：inspect 调用共享采集和有限计划检查，在创建 root 日志、原生写入驱动和启动事务之前返回，输出 `network_settings=NOT_APPLIED`。它不申请管理员权限、不写路由/DNS、不停止原 VPN；出现诊断错误也不代表路由已经被修改。输出中会包含本机地址和接口信息，反馈前按需脱敏。

通过只读检查也不自动授权 apply。真实写入仍须明确现场授权、可恢复的本机环境及既定短时限制；不在企业强制策略、路由争用或远程唯一控制通道上执行。后续继续 External 执行诊断、失败/撤销联调与认证 Helper/GUI 接入，OpenVPN 导入保持提前；不恢复 WG 签名催办，不要求重做旧 S0 样本来证明同一机制。

## 本次仓库操作

本次只新增这份用户证据记录，未修改产品源码、构建脚本、权限、依赖或既有历史报告；没有执行新的测试、Mac 构建、网络采集、路由写入、Helper 安装或凭据读取。文档提交不改变刚通过的产物，不需要因此重建或清空缓存、锁及恢复标记。通过 main 的正常追加提交交付，不提供补丁包。
