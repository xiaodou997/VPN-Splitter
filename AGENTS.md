# VPN-Splitter 开发约定

本仓库当前是设计/技术验证阶段。先读 docs/plan-v0.1.md、docs/roadmap.md 和 docs/adr/ADR-001-v0.1-baseline.md；不要把文档目标当已实现事实。

## 已确定边界

macOS 26.0+、arm64、Swift/SwiftUI、纯 Swift PolicyCore、Developer ID/DMG、自有代码 MIT。主场景 Include；External 首发仅经验证的 Bypass。一次一个会话，不自动叠加隧道。

不提供系统级 Kill Switch、完整 IPv6、REJECT 执行、按 App/进程或严格域名隔离。不支持的策略在应用前拒绝，不能静默略过。DNS resolver 选择不等于数据路由。

## 实现顺序与检查

按 S0–S5 的门槛推进。每个 PR 引用任务 ID、需求 ID、测试 ID，列明实际执行和未执行测试、权限影响、失败/恢复路径。纯逻辑测试不能替代签名/真机联网测试。

目前不存在构建脚本或 Xcode 工程；不得声称执行了不存在的命令。创建后固定工具链与依赖 revision，并更新实际构建说明。新架构、依赖、默认行为或保证等级变化先更新 ADR。

## 代码与系统边界

PolicyCore 不依赖 UI、Network Extension 或 root API。规则用类型化模型和确定性编译，必须保持 first-match 等价。WireGuard 协议 AllowedIPs 与系统路由分离。

Managed 通过 Network Extension，不用 shell 启动第二个独立隧道。Helper 仅接受经过身份/参数/epoch 验证的结构化路由操作，不接受通用命令。只撤销可安全认领的修改，歧义不删，不恢复整个旧路由表。

## 安全与证据

不得提交真实 .conf/.ovpn、私钥、密码、令牌、签名私钥或未脱敏网络信息。使用合成夹具；诊断在所有出口脱敏。执行会改变宿主机路由/DNS/系统扩展的测试前必须确认授权、隔离环境和恢复办法，不在普通共享 CI/办公网络盲目运行。

第三方代码、测试和资源复制前检查精确许可；根 LICENSE 不重新许可依赖。不要 Fork 整个参考 App 代替按问题验证。

技术证据存 docs/evidence/，只记录实际观察。默认 NOT RUN；缺资源写 BLOCKED；不得把计划、模拟结果、编译成功或某上游项目存在写成真实 VPN 已验证。
