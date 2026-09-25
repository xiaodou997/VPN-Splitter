# VPN-Splitter 开发约定

先读 docs/plan-v0.1.md、docs/roadmap.md、docs/adr/ADR-001-v0.1-baseline.md。文档目标、代码合并、编译成功与真机通过必须分别报告。

## 当前工作流

用户已授权把 S0 与 PolicyCore 合入 main，并以 main 进行本地真机开发。只删除已确认合入且没有新增提交的远端工作分支；不改写历史、不删除用户本地分支、worktree 或 .local 数据。合并不关闭未满足的技术门槛。S0 实测证据见 docs/evidence/s0-single-target-user-result.md；S1 纯逻辑证据见 docs/evidence/s1-tp10-tests.md。

## 已确定边界

macOS 26.0+、arm64、Swift/SwiftUI、纯 Swift PolicyCore、Developer ID/DMG、自有代码 MIT。主场景 Include；External 首发仅经验证的 Bypass。一次一个会话，不自动叠加隧道。

不提供系统级 Kill Switch、完整 IPv6、REJECT 执行、按 App/进程或严格域名隔离。不支持的策略在应用前拒绝，不能静默略过。DNS resolver 选择不等于数据路由。

## 实现与验证

按 S0–S5 门槛推进，允许无网络副作用的纯逻辑并行。每个提交引用任务/需求/测试编号，列出权限影响、失败/恢复路径、已执行与未执行测试。新架构、依赖或保证变更先更新 ADR。

已存在 tools/s0/ 只读工具、tests/s0/ 合成测试与 Packages/PolicyCore/ 纯逻辑库。使用 python3 -m unittest discover -s tests/s0 -v；核心使用 swift test --package-path Packages/PolicyCore -Xswiftc -warnings-as-errors，并以 -c release 重跑。Python 仅用于开发工具/测试，不是产品运行依赖。

S1-01 原生 Xcode 工程在 apps/macos/；操作见 docs/s1-01-build.md。tools/s1/build.sh 只构建，不安装/激活；tests/s1/ 只做离线合同检查。Provider 有意返回1001，须真实日志证明已进入；没有协议后端时禁止配置默认隧道吸收流量。签名账号、profile 与 Signing.local.xcconfig 留在本机。不要把 parse/plist 测试称为 xcodebuild 或真实签名通过。

## 代码与系统边界

PolicyCore 不依赖 UI、NetworkExtension、root 或系统网络 API。用户规则必须保持 first-match 等价；WireGuard 协议 AllowedIPs 与系统路由分离。IPv4ConstrainedPolicyCompiler 仅检查调用方提供的拓扑和 peer 集合，不能把 planning-only 输出直接安装；能力 presets 不是真实探测结果。

Managed 通过 Network Extension，不启动第二个独立隧道。Helper 只接受身份/参数/epoch 验证后的结构化有限操作，不接受通用命令。route 退出码 0 不证明写入成功或归属。只撤销可安全认领的修改，歧义不删，不恢复整个旧路由表。

## 安全与证据

不提交真实配置、密钥、密码、令牌、签名私钥、provisioning profiles 或未脱敏网络资料。使用合成夹具。S0 原始输出只保存在 .local/s0/，并非已脱敏，不能上传整个目录。执行改变路由/DNS/系统扩展的操作前需现场授权、隔离环境和恢复办法；不在共享 CI 盲目运行。不禁用 SIP、Gatekeeper 或企业强制策略来使测试通过。

复制第三方内容前检查许可；根 LICENSE 不重新许可依赖。证据位于 docs/evidence/，缺环境写 BLOCKED/NOT RUN，用户反馈标 USER_REPORTED。不把模拟、源码存在或上游可用当成实际 VPN 已验证。
