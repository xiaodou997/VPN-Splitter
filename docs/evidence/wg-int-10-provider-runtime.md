# WG-INT-10：正式 Provider 运行接线证据

日期：2026-09-27。起点 main e79f889717b97f9b36b555b8a1c8851d2c6bbd9b。任务 S1-03/04/05 部分；设计见 [ADR](../adr/ADR-WG-INT-10-provider-runtime.md)。代码集成不是原生编译或真实 VPN 验收。

## 实际交付

正式 Provider 的显式 run 请求现在调用 ManagedPacketFlowSession，复用原 ProviderSessionController。实际调用路径包含原生网络观测、09 转换、PolicyCore/ManagedSettings 编译、系统设置成功门控、SplitterPacketFlowBackend 启动，以及关闭引擎后 setTunnelNetworkSettings(nil)。不是只在链接探针中新增一个类。

新 provider-build 在独立生成的正式 App/System Extension 工程中链接上述实现和固定 Go archive。默认 unsigned，--sign 使用本机签名；不自动安装/激活。旧 S1 unsigned 不包含运行后端，dev.sh run 仍 LocalDev；原 engine/engine-flow/packet-flow-test 保留。

正式页新增与交付检查分开的连接确认和实际 NE 状态观察。v1 check 请求仍不连接；严格 run-v2 才允许提升已认证连接为运行租约。取消、XPC 断开、App 退出、切网和睡眠进入停止路径，不自动重连。上游签名要求、App Group、Keychain ACL、模块锁不变。

状态边界：check 仍 2001；坏元数据 2002、无交付 2003、材料拒绝 2004、运行重叠/授权不可用 2010、运行失败/清理不确定 2011、睡眠停止 2012。只有设置及时成功且引擎启动完成，运行分支才调用成功 completion；这不表示握手或目标可达。

## 实际执行的测试

Linux x86_64，Swift 6.2.1、Python 3.13.5。连接的 Mac 项目目录仍返回 project_path_not_found；未使用无关项目绕过访问范围。工作区从固定 GitHub 文件恢复，是部分源码工作区，不是全仓库 checkout。

| 检查 | 本轮结果 | 范围 |
| --- | --- | --- |
| PacketFlowSettingsGate XCTest Debug | 18 项通过，warnings-as-errors | 原样完整 ProviderSession.swift 和原 Package.swift + 新 gate/测试；非旧 31 项 controller 全量套件 |
| 同组 Release | 同一 18 项通过 | 优化构建重跑，不算另 18 个独立测试 |
| tests/provider_runtime | 6 Python unittest 全部通过 | 4 个构建/入口/命令/条件源码检查 + 下方 2 个可执行 harness |
| runtime host harness | 内含 6 组通过 | 实际 ManagedPacketFlowSession、完整原控制器、新 gate；系统/网络/配置/后端为明确替身 |
| runtime delivery harness | 内含 10 组通过 | 实际 broker/envelope/运行授权、真实 Foundation 二进制归档；元数据/材料 DTO 是替身，未测试 OS 身份认证 |
| 原生条件源码 | arm64-apple-macos26.0 frontend parse 通过，运行宏启用 | 仅语法；不是 Apple SDK 类型检查、链接或 xcodebuild |

18 项门控覆盖同步/迟到/重复回调、apply/clear 失败与超时、取消期间等待原 apply、一次性使用、调用方重入、真实旧控制器的 settings→engine→stop 顺序。6 组宿主场景覆盖正常顺序、启动取消、空闲授权撤销、网络变化、apply 失败和 MTU 拒绝。10 组交付场景覆盖旧 check 不授权、run lease、连接断开、精确 attempt 结束、并发拒绝、过期和目的篡改。

工程生成测试使用原样完整 S1 generator 和明确合成 Info.plist，检查目标/源码/包/宏/链接/路径空格；没有运行 xcodebuild。命令分发测试使用无副作用替身。只有原样恢复并完整核对的文件才报告基线 blob 一致；不声称验证了缺失文件或全仓库。未重跑原 ProviderConfiguration/AppCore/PolicyCore/ManagedSettings/旧 controller/Go/WG09 套件，不累加历史数量。未使用真实 Security、XPC、NE 或加密引擎执行本轮测试。

## 更新后的原生构建入口

```bash
/bin/bash dev.sh provider-runtime-test
/bin/bash dev.sh provider-build
# 仅当需要允许固定公开依赖下载时：
/bin/bash dev.sh provider-build --fetch
```

provider-runtime-test 在完整 checkout 会运行 ProviderSession 中旧/新用例和本批 Python；上表只记录本轮部分工作区实际执行的新 18 项和 6 项。provider-build 依赖原已支持的 Mac/Xcode/Go，不安装工具。实际先构建固定 packetFlow 引擎，再生成并编译正式 App/扩展；核对原生 arm64、4 个定义的 packetFlow C 符号和源码构建前后一致，结果写本机 .local/wireguard-engine/provider.*。

默认 unsigned 产物不得安装或激活。--sign 只改变构建签名，不授权真实连接、不提交签名文件。先检查集成构建和签名/App Group，再在现场明确授权且有恢复入口的机器使用合成配置验证身份拒绝，之后才用本机有效配置进行受控流量测试。真实密钥不要上传。

## 仍未通过／仍缺的工作

新增 Apple SDK 类型检查、生产 Go 引擎的本批链接、真实签名/XPC/Keychain/偏好/GUI、物理网络观测、实际 packetFlow、握手、VPN/直连双路径和睡眠/断线处理均 NOT RUN。源码里的真正 API 调用不冒充实测。

物理网络适配目前覆盖受控主 Wi-Fi/以太网 IPv4 样本；不是完整路由表/过滤器/企业策略冲突发现器。新 UI 已读 NE 状态，但仍无真实握手/字节统计采集和目标探测。setTunnelNetworkSettings(nil) ACK 只表示该操作回调，独立路由/DNS 恢复观察尚未实现，日志始终 network_restore_NOT_OBSERVED；不调用 observeSystemTeardown 伪造验收。持久化孤儿/旧凭据清理和长期运行质量仍欠实现。故 WG/S1 整体不能标完成。

48eee07 USER_REPORTED 编译/链接成功继续保留，只覆盖原基线。没有访问真实配置、密钥或签名材料，没有安装工具、保存 VPN 偏好、激活扩展或改变系统网络。main 非强制交付，无更新包；回滚用后续 revert，保留数据、锁、缓存及历史证据。
