# WG-INT-08C：正式保存 → 经身份验证的交付接线

日期 2026-09-26；起点 main a2f7d30d237ac3cb9cde1803dc8a77d0d1aad51d。任务 S1-03 部分；SEC-01、P-05/06、RULE-05、REL-02。设计/权限/失败语义见 [ADR](../adr/ADR-WG-INT-08C-authenticated-configuration-delivery.md)。

## 已实现的同一条代码路径

正式 App 新增“正式配置 / 交付”页面，显式载入当前选择、选择 .conf、填写 IPv4 CIDR、确认保存。ManagedAppWorkflow 将真实 NETunnelProviderManager 的重载/保存与 08B Keychain 记录事务接起。一个进程生命周期用户文件锁协调本应用写者；系统保存未确认则不删可能已被引用的凭据、不允许交付；当前选择由系统偏好重载，而非落盘 connected 布尔值决定。

单独确认交付检查后，真实 NSXPCConnection/NSXPCListener 使用系统签名要求验证对端角色和 Team；App 先完成无秘密 hello，随后复核选中记录并读取 App Keychain，发送一次性有界材料，收到暂存确认后再次核对系统偏好并调用 NETunnelProviderSession.startTunnel。扩展 main 安装监听端，真正的 PacketTunnelProvider 启动入口消费匹配材料。

这不是只增加协议对象或编译探针；但本批环境尚未运行上述 Apple 原生路径，不能写成“真机跨进程交付验收完成”。收到材料后仍主动返回 Managed 2001（引擎未安装），无交付返回 2003，元数据错误 2002，旧 S1 smoke 1001。无实际 VPN、握手、路由/DNS 设置或恢复证明。

## 权限与数据

两个正式 target 增加专用 Mach 通信 App Group；扩展 Info.plist 增加 NEMachServiceName，身份参数来自签名 bundle。Keychain 显式使用包含 App 自身 application identifier，不使用通信组、不增加共享 Keychain entitlement，也不更改 LocalDev。新签名 profile/组授权和调试权限拒绝均待原生验证。get-task-allow 或注入例外不被放行；不能靠关闭系统保护联调。

普通系统配置只持有标识、版本、公开 UID 和不透明 Keychain 引用。原始配置/规则仅进入 App Keychain 及已认证瞬时 XPC，不进入日志/文件/NE options。新 UI 保存的是交付草稿，不冒充已通过 WireGuard 单 Peer、AllowedIPs、DNS 或脚本安全检查的运行配置。旧凭据版本与崩溃孤儿保留，不宣称垃圾回收或完整持久化清理恢复已完成。

## 已执行

环境：Linux x86_64，Swift 6.2.1，Python 3.13.5。连接的 Mac Runner 返回 project_path_not_found；未借用无关项目绕过访问范围。工作目录按固定 GitHub 基线恢复本批需要的文件，**是部分源码验证目录，不是完整仓库构建**。

| 检查 | 实际结果 | 边界 |
| --- | --- | --- |
| 本批 Swift Debug / Release | 同一 41 项 XCTest，各 0 失败，warnings-as-errors | 35 项选择/交付/错误/版本/取消/重放/时钟/脱敏 + 6 项临时文件系统锁测试；不是重复 82 个独立场景 |
| 凭据源 Python | 4 项通过 | SwiftPM 实际发现、App 专用查询边界、无回退、无真实 Security 测试 |
| 新接线 Python | 8 项通过 | 实际工程引用、正式入口、原生认证调用顺序、专用组、UI 显式基线、资源上限的源码合同；不证明原生 API 行为 |
| 旧 Provider Python 选定回归 | 4 项通过 | 工程一致、正式 target 依赖、旧目标设置和可执行 11 场景 metadata harness；11 组含在此项，不另累计 |
| macOS 条件源 | arm64-apple-macos26.0 frontend parse | 语法检查，不是 Apple SDK 类型检查或链接 |
| 基线与生成核对 | 原启动包/凭据记录、生成器、7 个配置文件、旧 S1/Provider 测试和 5 个旧 helper/fixture 的原始 blob 核对 | 基于原生成器生成新 pbxproj，不手写失配引用 |

41 项仅为本次恢复目录实际执行的测试；08A/08B 原来的 58 项 Swift 测试没有在本批恢复运行，不累加声称全包/全仓通过。Mac 专用 5 项真实 Security 查询构造测试在 Linux 排除，本批 NOT RUN；没有执行其原生 Security IO。旧 dev dispatcher 测试、完整 S1/PolicyCore/AppCore/ManagedSettings/ProviderSession/Go/engine 套件未重跑。

旧 metadata harness 的测试副本明确替换 Bundle ID，并关闭 native 条件分支（断言 5 处）；原正式源码不增加测试开关。这样 Mac 上的旧框架替身测试也不会误入原生 XPC 路径。输出额外写 native_xpc=NOT_TESTED；不把替身、OS 签名或真实 Bundle 混为一谈。

复查修正：不自动刷新覆盖旧编辑基线；listener 要求不重复设置到同一连接；SecCode 显式取得 SecStaticCode 后读取签名信息；已有锁目录重开；文件锁占用/符号链接/宽权限拒绝；旧失败/过期回调不能取消新授权；等待对象存活至自身截止时间。

## 可复现检查

```bash
swift test --package-path Packages/ProviderConfiguration --filter 'ManagedSelectionDeliveryTests|ManagedAppLeaseTests' -Xswiftc -warnings-as-errors
swift test --package-path Packages/ProviderConfiguration --filter 'ManagedSelectionDeliveryTests|ManagedAppLeaseTests' -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/provider -p test_credential_source.py -v
python3 -m unittest discover -s tests/provider -p test_authenticated_delivery.py -v
PYTHONPATH=tests/provider python3 -m unittest test_launch_integration.LaunchIntegrationTests.test_checked_in_project_is_generated test_launch_integration.LaunchIntegrationTests.test_both_formal_targets_link_contract test_launch_integration.LaunchIntegrationTests.test_legacy_target_settings_and_no_remote_dependency test_launch_integration.LaunchIntegrationTests.test_native_source_flow_with_explicit_doubles -v
```

日常完整 provider-test 入口保留，会在完整仓库中运行原有及新增用例；本批没有把它全部通过作为证据。dev.sh run 仍启动无 NE 的 LocalDev，**不是本批新正式页面**。新增正式代码应在 Mac 使用原 S1 unsigned 构建入口检查；unsigned 产物只编译，不得安装或激活。

## 原生验收仍未执行

新的 Apple SDK 类型检查/xcodebuild、双向签名接受与拒绝、Mach 服务发现/组配置、真实 Keychain/锁屏行为、实际系统偏好/取消/保存晚回调、GUI/跨进程交付、Provider 回调、进程终止与重启均 NOT RUN。应先用合成配置在现场授权的测试 Mac 验证；只看 startTunnel 返回值或 UI 暂存消息不算交付成功，须有匹配 attempt 的 MANAGED_CREDENTIAL_DELIVERY_CONSUMED 日志，并验证错签名/错用户/旧版本/过期/断开不消费。

下一步不是只剩签名：仍须实现完整材料语义转换、可信自有数据通道、WireGuard 正式会话和实际网络失效/撤销。真实 VPN 的握手、双出口、停止恢复全部未验收。48eee07 用户报告的原生编译/链接/符号 PASS 保留且只覆盖该版本。

本批未安装工具，未读取用户真实配置或密钥，未保存本机 VPN 偏好、激活扩展或改系统网络。交付 main，不发 ZIP；回滚采用后续 revert，保留数据、锁、缓存和旧构建证据。
