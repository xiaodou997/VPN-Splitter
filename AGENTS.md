# VPN-Splitter 开发约定

先读 docs/plan-v0.1.md、docs/roadmap.md、docs/adr/ADR-001-v0.1-baseline.md。文档目标、代码合并、编译成功与真机通过必须分别报告。

## 当前工作流

用户已明确授权直接修改并推送 main，且表示最近 UI、WireGuard、Keychain 三批更新包均未下载。交付统一为 main；不要要求用户下载或依次套历史包，也不要把包已生成当成用户已安装。每次从最新远端起点整合、执行可用回归、核对完整源码后再非强制更新 main；本地只需 git pull --ff-only 和原构建入口。最新证据见 docs/evidence/localdev-main-integration.md。

用户已授权把 S0 与 PolicyCore 合入 main，并以 main 进行本地真机开发。只删除已确认合入且没有新增提交的远端工作分支；不改写历史、不删除用户本地分支、worktree 或 .local 数据。合并不关闭未满足的技术门槛。S0 实测证据见 docs/evidence/s0-single-target-user-result.md；S1 纯逻辑证据见 docs/evidence/s1-tp10-tests.md。

## 当前优先级：正式 WireGuard 执行链（2026-09-26）

用户已要求从 LocalDev 转向首条真实 WireGuard IPv4 Include 路径：单配置、首轮单 Peer、指定网段 VPN、其余直连，并能取消/断开及确认停止后的系统状态。不要用更多 UI 或模拟数量代替这条路径。开发签名仅在首次真实联调前恢复；本条不授权激活扩展、读取真实密钥或修改网络。

先读 docs/acceptance-status.md 与 docs/adr/ADR-WG-INT-08A-managed-launch-contract.md。LocalDev 为 LD-03B，WG-INT-07 为进程内会话接线；WG-INT-08A 新增正式启动元数据边界与 App 提交辅助代码，尚未接真实连接 UI、凭据授权来源、自有隧道资源或正式会话运行。合法 Managed 请求仍返回 2001，错误请求返回 2002；旧 S1 smoke 保留 1001。不能把这些错误门控改成成功来宣布接通。

日常入口为 dev.sh：run / test 保持 LocalDev；engine / engine-test 保持原生候选及其回归；provider-test 测试正式启动边界，包含明确的框架替身，不是真实 NE 验收。48eee07 用户报告的原生构建成功保留且仅覆盖该基线；新增代码的 Apple SDK 编译和真实功能另验。下一优先项是凭据的实际授权交付、自有数据通道、会话/网络/撤销接线；不得放宽 LocalDev ACL 或把 UUID/引用相等当作授权证明。

## LocalDev 历史调序与持续安全边界

以下保留 ADR-007 时期的背景；当前开发优先级以上方执行链为准，已有数据和权限边界不变。

用户已确认暂停开发签名，先做无网络副作用的配置/规则/诊断界面。先读 docs/adr/ADR-007-localdev-before-signing.md 和 docs/localdev.md；它们调整开发调度，不关闭 S0–S5 真实技术门槛。已有 S1 preflight / unsigned 与旧版 LocalDev 开窗为 USER_REPORTED 成功，不要求重做，也不能作为 LD-02B 新版 GUI/Keychain 验收。入口为 /bin/bash tools/localdev/build.sh run；现有 unsigned 产物仍不可安装。

LocalDev 独立工程在 apps/macos/LocalDev/，仅 ad-hoc 签名、无 NE entitlement/扩展；AppCore 复用 PolicyCore。当前 LD-02B 包含单编辑事务、WireGuard 结构导入及配置范围检查、显式本机 Keychain 适配和可重试清理；原生 SDK / Keychain / GUI 验证仍须证据。不把模拟或规划能力预设报告为真实连接/探测，不向普通 JSON、报告或日志添加密钥和原始配置。正式扩展共享和首次真实隧道前签名另验。

统一离线入口 /bin/bash tools/localdev/test.sh：AppCore Debug/Release warnings-as-errors 与 tests/localdev 合同测试；不会打开程序、使用真实 Keychain 或修改网络。故障注入替身不能计作系统 Keychain 通过。先用 tests/fixtures/wireguard 合成夹具做 Mac 验证，再考虑真实配置。凭据准备阶段可能升级 workspace v3；不通过清空 JSON、手改版本、放宽 ACL 或删除锁文件解决失败。详见 ADR-008/009/010 与 docs/localdev-keychain.md。

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
