# EX-INT-03B 睡眠核查后预检仍禁用

2026-09-30。实际诊断版睡前撤销和睡后 noRecovery 已通过，但继续操作发现预检按钮 disabled，规则页确认单目标方案已保存且可 Route 执行。源码确定 GUI cleanupUnconfirmed 在 invalidate 后保留，而 idle/noRecovery 未解除该标志。

修复：仅接受已认证回复 idle/noRecovery 且 owned=0 时解除本地清理未确认标志。Helper 同时拒绝有预约或活动会话期间的 recoveryAudit/recoveryClear（busy），避免它们错误返回 noRecovery。普通 idle、拒绝和错误回复不获得该解除条件；删除权限和 marker 清理规则不变。

验证：实际 UI model/client 配合显式平台替身，在 apply→invalidate→audit noRecovery→prepare 路径恢复可用；服务测试覆盖预约/活动两阶段 audit/clear 拒绝和断开清理后 noRecovery。ExternalControl Debug/Release 各 28 tests / 0 failures，Helper Python 15 tests 通过。真实安装与按钮复验尚待完成；测试替身不是原生身份或路由证据。无新增权限，无网络 reset；GitHub 同步暂停。

## 原生安装与后续提示修正

control.6ogfuuvw 签名编译通过；公证 d77954da-47d3-480d-aabc-42cfa6f3092c Accepted，票据和安装后 strict codesign 通过。旧 UI 因已知锁存问题无法正常退出，已在 Helper noRecovery 后结束该唯一控制 App 进程，重开后通过 GUI quiesce/注销；新版本注册 enabled、audit noRecovery，预检按钮实际 enabled 并可点击。未提交 apply。此结果验证部署和按钮可用，但没有再次真实睡眠复现完整状态迁移。

继续测试发现未成功 prepare 也启动 watch，后续 idle 状态覆盖拒绝原因。修正为只有 prepared 才 watch；其他结果保留提示并关闭该通道。新增实际模型替身测试等待超过一次轮询间隔，确认拒绝提示不消失且未发送额外 status。该后续提示修正尚未部署，已安装版本只包含前面的锁存修复。

## 最终提示修正部署

control.eo6paken Developer ID route-trial 构建、公证 04be9e64-1836-4ba4-8608-a90f5adeb3eb Accepted、staple、安装后 strict codesign/票据验证通过；旧服务 GUI 注销和退出，新服务注册 enabled。只点击 prepare：GUI 返回 refused / observationFailed，开始按钮禁用；第二次独立 UI 读取仍保留相同拒绝原因，没有被 idle 覆盖。该时点第三方隧道未连接，目标查询 en0；未点击 apply。这里只证明拒绝提示和阻断行为，observationFailed 尚不足以精确归类为 noVPN。

## VPN 恢复后的最终候选验证

用户报告 VPN 已连接；只读发现 0/1+128.0/1 经 utun8，授权目标经 utun8，GUI audit noRecovery。control.eo6paken 再次真实 apply/stop：ADD/readback 成功、en0，正常停止 closed/none/owned0/unchanged、DELETE reply_type=2/mutation_attempts=2、目标回 utun8。

额外真实 prepare 票据过期测试：单目标 prepared 后不确认、不 apply，等待 17 秒；GUI closed/notApplied/owned0/notObserved，开始按钮 disabled，目标仍 utun8。此测试覆盖真实 Helper 服务定时器和 GUI 更新，不把 notObserved 当成快照验证；未进行过期票据重放（已有离线覆盖）。测试脚本初次语法错误发生在执行前，修正后运行。
