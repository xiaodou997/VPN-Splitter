# WG-INT-08A：正式启动元数据边界证据

日期：2026-09-26。起点：main `eafac9f49461cca0976b16eae21c9831b14fc102`。任务：S1-03/04 部分；需求映射见 [验收状态](../acceptance-status.md)。这是源码/离线验证记录，不是 VPN 可用性证明。

## 实际新增与未新增

新增 ProviderConfiguration 纯 Swift 包；正式 App 与 PacketTunnel 两个 Xcode target 均引用。App 的 ManagedTunnelLaunchClient 校验已载入 profile/引用后一次性调用 NETunnelProviderSession.startTunnel；正式 GUI 尚未使用它。Provider 的真实入口解析同一请求、核对配置版本/引用格式/Provider ID，并区分无效请求 2002 与合法但未接通 2001。原 S1 smoke 1001 保留。

没有实现真实凭据的跨进程交付、记录授权、扩展自有 packet/descriptor 来源、实际网络发现、正式 ManagedWireGuardSession 安装或系统撤销观察。不能把引用检查写成 Keychain 授权已完成；也不能把 request scope 标签写成真实单 Peer/IPv4/Include 已检查。合法 Managed 请求仍明确失败，没有用户新增的可用连接能力。

## 执行环境与结果

执行环境：Linux x86_64，Swift 6.2.1，Python 3.13.5。已连接 Runner 无法访问原 Mac 项目目录，未借用无关项目绕过访问限制。验证工作区按 GitHub 固定基线取回本批所需文件，是部分源码工作区，不是完整仓库的全量构建。

| 检查 | 本批结果 | 证据范围 |
| --- | --- | --- |
| ProviderConfiguration Debug | 24 XCTest，0 失败，warnings-as-errors | 类型、严格字段/版本、UUID/generation、引用范围、错配、真实 Foundation property-list 往返、快照隔离与脱敏 |
| ProviderConfiguration Release | 同一 24 XCTest，0 失败，warnings-as-errors | 优化构建的相同逻辑，不算新增 24 个独立场景 |
| tests/provider | 5 个 Python unittest 通过 | 正式双 target 引用、生成文件一致、旧边界、dev.sh 路由保留、可执行入口替身测试 |
| T-MLH01～11 | 包含在上述入口替身测试内的 11 组场景通过 | 实际 App 辅助代码和 Provider 分支；不是 11 个额外独立测试 |
| Xcode 工程原始基线重建 | 原 generator 和其原 pbxproj 的 Git blob SHA 与远端相符 | 再基于该输入生成本批 pbxproj，未手填不一致的 target 引用 |
| Bash/Python、改动审查 | 语法与生成一致性检查通过 | 不启动应用、不安装软件、不访问真实网络/Keychain |

入口替身测试用项目自有 NetworkExtension / os / PolicyCore doubles；Provider 的 `Bundle.main.bundleIdentifier` 在测试副本中仅一处替换为合成 ID。实际 Provider 源码保持系统 Bundle 读取。此替换被断言计数并在 harness 输出标成 `bundle=INJECTED`，不能据此声称真实 Bundle、签名身份、Apple logging 或跨进程消息已验证。测试实际编译 ProviderConfiguration 和 App 辅助代码，执行提交一次、错误状态/On Demand 拒绝、旧版本/引用拒绝、框架错误脱敏、smoke 保留、合法请求仍阻断、混用与错误容器拒绝。

可重跑入口：

```bash
/bin/bash dev.sh provider-test
```

它不需要 Go、不会拉取依赖、保存 VPN 偏好、读取真实密钥或修改网络。测试输出中的 Swift Testing “0 tests”是另一个未使用测试框架的尾注；本包的实际 24 项执行数来自 XCTest 汇总。

## NOT RUN / 未实现

本批未执行 Mac Apple SDK / xcodebuild、真实 NETunnelProviderManager 提交、系统偏好重载、签名/扩展激活、共享 Keychain、实际 Bundle/调用方授权、可信 descriptor、真实会话、握手、分流出口、DNS 与断开恢复。较早的全量 PolicyCore/AppCore/ManagedSettings/ProviderSession/Go/原生 engine/S1 套件未在本批重跑或计数；原生运行路径仍缺实现，不只是缺测试。

用户对 `48eee07` 的编译/链接/符号成功反馈保留为该版本的 USER_REPORTED 证据，本批不否定或扩大其覆盖范围。LocalDev UI、数据 schema、entitlement、签名、依赖锁和 WG-INT-06/07 引擎实现不变。日常仍通过 main 更新，不发更新包。

## 下一交付与回滚

下一交付必须继续关闭执行链缺口：正式凭据授权与真实规则快照、扩展自有数据通道、正式运行会话/网络失效/撤销，再做 Mac 构建和经现场授权的首轮实际双路径验证。不得用继续增加请求字段/模拟数量代替它们。

本批没有创建/修改系统设置或凭据；代码回滚使用后续 revert 提交，保留用户数据、配置、缓存、锁文件和全部历史构建证据。单独停止回调仍不算操作系统恢复证明。
