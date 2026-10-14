# EX-INT-03B 持续 IP 分流试用版

2026-09-30，按用户优先交付试用而非无限延伸验收的要求实施 ADR-EX-INT-05。主机端显式 sustained 构建取消活动会话绝对 60 秒期限；默认有限执行器/route-trial 不变。保留 10 秒心跳、15 秒 prepare、console 身份、网络 epoch、有限路由预算与保守撤销。新增请求递增序号让状态心跳使用固定内存防重放；变更请求仍受 UUID 集合上限保护。120 秒通道关闭只豁免仍有新鲜心跳的已认证活动所有者。

验证：ExternalControl Debug/Release 各 30 tests / 0 failures，包含 697 次连续状态请求、超过 60/120 秒、重放不续心跳和失联撤销；ExternalExecution Debug/Release 各 43 tests / 0 failures，包含受控生命周期跨一小时模拟时钟后取消撤销，以及默认短期限回归。Helper Python 15、Execution Python 26 tests 通过；构建合同补测持续选项同时传给 App/Helper。真实 signed build control.48xbsv22 通过；公证 c21dd0b2-58f6-426f-aa62-fbf809492aba Accepted，staple、安装后 strict codesign/票据通过，旧服务 GUI quiesce/注销，新服务注册 enabled。

这些模拟时钟测试不等于一小时真机；真实长运行及停止结果后续补记。当前第三方 VPN 健康、完整切网/硬故障/两小时稳定性仍不是已验证保证。试用交付保留已知边界，APP/域名 DIRECT 未实现，WireGuard/OpenVPN 不因本次改动变为已验收。无 Github 同步。

首次真实持续会话：35/70/105/135 秒检查均 active/en0；目标 HTTP 200，VPN 对照 HTTPS 超时（不视为双路径通过）。136 秒后正常 stop 路由回 utun8，但连接超龄清理抢先关闭 XPC，GUI 未收到终态；audit noRecovery。定位为 stop 已结束会话，120 秒老通道扫描立即回收，新增从终态产生起固定 10 秒、不可延长的回复送达窗口。控制层增加对应测试，最终 Debug/Release 各 31 项通过；其余 Helper Python 15 项通过。首次候选不算停止 UI 验收通过，后续修正版另记。

## 最终候选交付证据

修正版 control.xkjlm438，公证 8dd0283c-ab8b-49a2-98df-f2d108f77662 Accepted，staple/validate 和安装后 strict codesign 通过。正式安装路径 /Applications/VPN-Splitter-ExternalControl.app，GUI 注册 enabled。真实复验在 36.3、71.3、106.4、136.4 秒均 active/en0；随后菜单 stop，GUI closed/none/owned0/unchanged，DELETE reason=none / reply_type2 / mutation_attempts2，目标回 utun8。后续 audit noRecovery。原停止回复竞态未在修正版复验出现。

本次交付为持续 IP 分流试用：无 60 秒自动到期，保持 App 运行；用户显式开始/停止。验证结束已停止，不替用户保留活动会话。真实持续验证约 136 秒，不伪称两小时稳定性或全环境支持。后续收集实际使用反馈，切网扩展矩阵不再阻塞本次试用交付。
