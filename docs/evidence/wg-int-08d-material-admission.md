# WG-INT-08D：正式材料语义校验与入口接线证据

日期：2026-09-26。起点 main `27dde34d7a67b68e75ac881651964a11dd34f85e`。任务 S1-03/04 部分；需求 WG-01/02/03/04/06、P-06、RULE-02、SEC-01。决策见 [ADR](../adr/ADR-WG-INT-08D-material-admission.md)。

## 本批实际新增

正式 App 保存事务前、认证 hello/Keychain 读取后且 XPC stage 前、正式 Provider 消费后均接入相同材料检查。实际调用既有完整导入器和 PolicyCore，输出保留原始字节的类型化快照。非法脚本/字段/密钥、非首轮 Peer/地址/端点范围、DNS 无方案、坏规则归档、VPN 超 AllowedIPs 及基础设施冲突均拒绝；不扩大协议权限或部分应用。

UI 改用同一规则编码器、安全的单 fd 文件读取，并修复新文件读取失败后仍保留上次待保存配置的问题；保留已有系统选择，不删除用户凭据。Provider 增加 2004 材料语义拒绝；校验合格仍 2001 引擎未安装，2002/2003/1001 原边界保留。没有任何新增的可用 VPN 连接。

本批**未实现原生 WireGuardKit 配置转换、自有数据通道或正式引擎运行**；类型化快照不冒充上述实现。DNS 字段被明确阻断是首条受控路径范围，不取消完整 v0.1/S2 DNS 要求。

## 实际执行环境与范围

Linux x86_64，Swift 6.2.1。Mac Runner 对原项目返回 project_path_not_found；没有借用无关项目。工作目录由固定 GitHub 基线恢复，是**部分源码验证目录，不是完整仓库或完整产品包构建**。

31 项 XCTest 使用隔离 SwiftPM harness：完整、原样的四个 PolicyCore 文件与 WireGuardImport.swift；Credentials.swift 截至完整 WGCredentialMaterial 定义、WireGuardPlanning.swift 截至完整 WireGuardPlanning 定义；新增材料实现与测试。后两者仅排除无关工作区/持久化事务定义，不替换导入、密钥验证或编译器。没有原生 Security/NE 调用。上述完整旧文件及 ManagedLaunch、三个改动调用文件、旧合同测试和改动文档的原始 Git blob 已与远端基线核对；部分源码摘录不声称整文件哈希。

| 检查 | 本批结果 | 证据边界 |
| --- | --- | --- |
| 新增材料 XCTest Debug | 31 项通过，warnings-as-errors | 真解析器/PolicyCore、规则范围和语义、二进制归档、字节保持/快照/脱敏及临时文件拒绝场景 |
| 同组 Release | 31 项通过，warnings-as-errors | 同一场景优化构建重跑，不算额外 31 项独立场景 |
| test_material_admission.py | 6 项 Python 测试通过 | 实际 SwiftPM manifest、三个接线位置/调用顺序、安全文件 UI 和可执行 Provider 分支测试 |
| T-MAI01～10 | 包含在上述 6 项中的一个测试内，10 组通过 | 真正 Provider 的 macOS admission/stop 方法体 + 实际解析/编译；NE/os/认证交付来源为明确替身 |
| Native 条件源码 | arm64-apple-macos26.0 frontend parse 通过 | 仅语法，不是 Apple SDK 类型检查/链接 |
| SwiftPM、Python | 两个真实 manifest 求值及依赖解析检查、Python 语法通过 | 显式本地 AppCore/PolicyCore，无新远程依赖；原旧包全量测试未运行 |

31 项覆盖脚本/未知字段、三种密钥字段、缺失/重复、单/多 Peer、所有配置位置的 IPv6、DNS/搜索域、数字/主机名端点、保留/重复接口、AllowedIPs 联合覆盖与越界、规则顺序、类型/字段/版本/格式、大小上限、BOM/CRLF/控制字符、可变输入隔离。临时文件测试只在独立测试目录创建合成配置、符号链接和 FIFO，并清理本测试目录；未读取用户文件。

T-MAI harness 在测试副本中将恰好 5 处 macOS 条件替换为显式测试条件、恰好 1 处 Bundle ID 注入；生产代码没有测试开关。实际执行 2001/2002/2003/2004、旧 smoke、收到后重新校验、坏字段/密钥/脚本/规则/DNS、停止丢弃。输出明确 `parser_policy=ACTUAL framework_delivery=TEST_DOUBLES bundle=INJECTED native_auth=NOT_TESTED network=NOT_APPLIED`。它不测试真实身份接受/拒绝、XPC 内核用户身份、Keychain 或路由恢复。

旧 credential source 合同中的“无依赖”断言改为必须恰好两个本地依赖，并检查新源码被发现；原四项合同测试未在不完整目录整体重跑。依赖部分另经实际 describe/dump-package 求值核对。其余旧 Provider/AppCore/PolicyCore/ManagedSettings/ProviderSession/Go/engine 套件未在本批累加计数。

## 在完整 checkout 复现

```bash
swift test --package-path Packages/ProviderConfiguration --filter ManagedWireGuardInputTests -Xswiftc -warnings-as-errors
swift test --package-path Packages/ProviderConfiguration --filter ManagedWireGuardInputTests -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/provider -p test_material_admission.py -v
```

上方完整 package 命令是后续完整 checkout 的复现入口，不声称本批在完整产品包执行；本批 XCTest 使用上文所述隔离源码 harness。日常全量入口仍 `/bin/bash dev.sh provider-test`。本批未运行它全部用例。Swift Testing 的尾部“0 tests”不覆盖实际 XCTest 汇总。

正式新代码的 Mac 编译入口为 `/bin/bash tools/s1/build.sh unsigned`，只编译，不得安装/激活 unsigned 产物。`dev.sh run` 仍是独立 LocalDev，不是正式页面。本批未安装工具、修改签名/entitlement/组/ACL/依赖锁，未读写真实 Keychain/偏好、未请求扩展或改网络。

## 未完成与下一步

Apple SDK 完整构建、GUI/保存/认证交付的真实接受与拒绝、原生 WireGuardKit 转换、可信数据通道、实际 underlay/epoch、正式会话和运行授权失效、握手/双出口/取消断开与系统恢复均未验收，其中后半部分仍缺实现。`48eee07` 用户报告成功只覆盖该旧基线，不否定也不扩大。

下一交付应把已校验快照真正转换并接到原生引擎/自有通道，不能再把材料校验当完整运行路径。main 非强制统一交付；回滚使用后续 revert，保留原配置、凭据记录、锁、缓存和历史证据，不发更新包。
