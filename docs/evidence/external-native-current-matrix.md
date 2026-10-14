# External 本轮原生验证矩阵

日期：2026-09-30。环境：macOS 26A428、arm64，现有 StrongVPN 样本。用户授权 Agent 操作测试应用和本轮受控测试；GitHub 同步暂停。此矩阵区分原生样本、离线回归与未测门槛，不能视为完整 v0.1 发布签署。

| 项目 | 当前证据 |
| --- | --- |
| Developer ID / 公证 / 安装 | 多轮真实构建、Accepted、staple/validate、安装签名核对通过；本机既有 Gatekeeper override 记录保留，非干净安全默认安装验收 |
| Helper 注册/批准/注销 | GUI 与 launchctl/进程独立核对通过；当前修复版已注册 enabled，最近恢复核查 noRecovery |
| 认证、只读核查、重复核查 | 原生 hello/recoveryAudit、跨 30 秒重复核查通过；错误身份 ad-hoc 和同 Team 错 ID 有系统签名拒绝日志及有效新连接对照 |
| 单目标预检/ADD/停止/DELETE | 10 次正常开始/停止循环通过，目标 utun8→en0→utun8、零回执、无 DELETE 错误、语义快照 unchanged |
| 持续 IP 试用 | 新增显式签名 sustained 模式，已公证安装；真实 136 秒保持 active、停止 closed/owned0/unchanged、回 utun8、audit noRecovery。见 ex-int-03b-sustained-preview.md；不是完整长期稳定性验收 |
| 60 秒自然租约 | 修复 IFREF 元数据误报后单样本通过；GUI 首次观察结束约 64.7 秒（含操作/采样/调度），非硬实时期限 |
| 控制 App 失联 | 10 次 SIGTERM 循环通过；恢复路径并重开 noRecovery；前后 DNS 观察一致 |
| 心跳丢失 | 单次 SIGSTOP/SIGCONT 样本约 9.99 秒撤销、零回执、unchanged；不是系统睡眠 |
| 实际双路径访问 | 目标 HTTP 200、nettop/socket=en0；同 lease HTTPS 对照 200、源地址/路由=utun8；停止后的新目标连接又走 utun8；DNS 观察仍一致 |
| 目标 HTTPS | TCP 直连可达，但严格验证正确拒绝 IP 与证书名称不匹配；未跳过 TLS 校验 |
| Rule V2 / App picker GUI | Chrome 与 Safari 真实 Signing ID 保存、无路径；改名清除旧 ID；保存后的 flow-only 方案禁用 Route 预检/开始。临时方案已删除，原方案内容与选中项恢复 |
| Flow Probe | 前轮 TCP pass-through、第三方 VPN 共存、报告桥和安全停止已有证据；本轮未新增真实 DIRECT 数据转发 |
| 原生错误修复 | XPC 错误回调 Sendable、idle UI/过期通道、邻居 IFREF epoch、Safari 系统隐藏 App 链接均有回归与相应原生证据 |
| 实际睡眠样本 | 初次撤销确认不完整，marker 已安全清除；诊断版复验睡前 closed/owned0/cleanup=none、睡后 noRecovery。StrongVPN 旧核心随后断言退出，HTTPS 仍可达；本工具睡眠撤销单样本 PASS，用户确认第三方重连不阻塞本项；首次异常记录保留，非完整稳定性通过。见 external-sleep-network-investigation.md |
| 纯编译性能 | PolicyCore 固定种子 1,000 条规则、预热 10/测量 100，P95 2.392 ms；见 policy-1000-rule-native-benchmark.md。非数据面性能 |
| 尚未完成 | 切换物理网络、主动 VPN 重连的活动路由样本、特权 Helper 硬故障/人工恢复、2 小时/完整发行稳定性矩阵、干净 Mac 默认安全环境、多厂商/双栈环境 |

实际源地址/目标/原始网络记录仅在本机忽略目录，不进入此文。`noRecovery` 仅说明 Helper 无待恢复会话，不能代替全系统路由扫描。Flow App/域名 DIRECT、UDP/QUIC 未实现；WireGuard Basic 按既定优先级后置，OpenVPN Backlog。本轮结果不关闭这些门槛。

详细证据：`ex-int-03b-helper-route-native.md`、`ex-int-03b-negative-identity-preflight.md`、`ex-int-03c-native-rule-picker.md`、`ex-flow-01f-native-activation-attempt.md`。

用户于 2026-09-30 明确收敛验收责任：停止追查 StrongVPN，自有 External 睡眠通知撤销/唤醒后无恢复会话已通过本轮；WireGuard 配置导入和后续 OpenVPN 自有后端的睡眠/重连在对应实现阶段另验。第三方全机断网的调查记录保留，不作为当前开发阻塞，也不新增通用系统网络 reset 功能。
