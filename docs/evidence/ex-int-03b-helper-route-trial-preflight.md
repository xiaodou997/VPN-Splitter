# EX-INT-03B：App 内受控路由测试版准备

日期：2026-09-30。基线 `e9713e5`，含空闲核查关闭通道修复。前置证据见 Helper 原生诊断与错误身份测试记录：系统注册/批准、正常只读认证往返、注销、ad-hoc/同 Team 错 ID 拒绝以及有效新连接对照已取得样本证据；跨 30 秒重复核查 USER_REPORTED PASS。其他团队证书/用户切换并未验证。

`external-helper-build --identity <本机身份> --team-id <本机团队> --route-trial` 原生编译、签名验证通过，输出 `route_trial=COMPILED_EXPLICIT_OPT_IN`。候选 `.local/external/control.y59aj_d8/VPN-Splitter-ExternalControl.app` 的 App 和 Helper 均来自本次构建；本次没有复用只读 Helper 二进制。构建不注册、不运行、不写路由。

公证提交 `35291437-24bd-40f5-9b23-7a5cfc6d242e` Accepted；staple/validate、strict codesign 通过。仅本机 `cert/external-control-route-trial-notary.zip` SHA-256 为 `12ec7d00c61f202a8e712dacfffdf97bdfa1cbb69319f395e32ff2f9cf215c00`。

当前未安装/注册此候选、未请求 prepare/apply。已请用户通过旧版安全注销并退出，等待反馈。下一步现场操作按序：校验注销状态→用户授权安装/注册有限写入测试版→先只读核查→确认原 VPN 和测试环境→仅含旧授权目标 /32 的已保存方案→Helper 只读预检→核对单条提案→现场单独授权 apply→立即正常停止→核对 DELETE 诊断、零回执及原路径。最长 60 秒；任何不明结果停止重试并只读审计，不强删路由或恢复旧快照。旧目标只保存在本机忽略目录，不写入证据。

这是测试准备，不是 Helper 路由闭环验收；实际双出口流量、租约到期、睡眠/切网/重连仍未通过。按用户要求不进行 GitHub 同步。

## 安装候选

用户报告旧版已注销并退出；独立确认系统服务不存在、旧 Helper 和控制 App 均无进程。保留旧只读安装版到本机忽略目录后，已将 y59aj_d8 候选更新至 /Applications，App/Helper 哈希与候选一致，strict codesign、stapler validate 通过，控制 App 已启动。未注册新 Helper、未预检或应用路由；下一步由用户现场确认注册具有有限写入能力的测试 Helper。
