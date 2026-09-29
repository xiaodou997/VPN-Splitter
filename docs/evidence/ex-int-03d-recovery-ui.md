# EX-INT-03D：恢复核查与 GUI 安全清除

日期：2026-09-29。基线 `5fa4738`。目标：把既有 root 私有 recovery marker 的 audit/安全清除从工程 CLI 搬进认证 Helper 和页面，同时保持“歧义不删”的所有权边界。

## 实现

ExternalControl 新增 `recoveryAudit` 与 `recoveryClear` 两个有界动作，以及仅包含候选数量/当前存在数量的响应字段。请求仍需要已认证 XPC 连接、Helper instance 和当前 console user；不接受地址、网关、接口或文件路径参数。

Helper 的恢复 facade 复用 `ExternalLeaseFileJournal.auditCandidates()`、当前 `ExternalSystemSnapshotReader` 和 `clearAuditedAbsence`。审计只读；清除动作会重新采集一次当前网络，只有全部候选及更具体路由仍不存在时才 unlink 本工具 active marker。没有调用 NativeExternalRouteDriver.remove/RTM_DELETE，不重建旧 receipt，也不删除 lease.lock。

GUI 新增“核查恢复状态（只读）”和条件式“重新核查并清除恢复标记”。第一次审计必须明确得到零候选残留后第二个按钮才开放；第二次仍由 Helper 独立复核。若发现任何候选/歧义，marker 保留且状态继续 recoveryRequired。

## 验证边界

ExternalControl XCTest 增加两组状态机回归：零残留审计不会自动解锁，显式 clear 后才解除 blocked；第二次核查出现候选时保持 blocked。响应边界也增加 recovery candidate 数量约束。

本轮隔离容器无法解析 github.com，且用户 Mac project bootstrap 在此前仍不可用，因此没有执行整个仓库的 SwiftPM/Mac SDK 测试；这些新增测试已提交但需后续本机或可联网构建环境运行。没有安装 Helper、读取用户 marker、修改网络或清理实际恢复记录。
