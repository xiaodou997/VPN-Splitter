# LD-02A：WireGuard 结构导入与配置范围检查证据

> 历史批次记录：当时通过本地包交付。现统一从 main 更新，不再应用这些包；本轮重新执行结果见 [main 整合证据](localdev-main-integration.md)。下文测试归属与当时 NOT RUN 保留。

日期：2026-09-25。关联 LD-02A、S1-03 部分、S1-02 接入；WG-01/03/06、T-W06、T-U02–U04、T-P10。

## 交付和基线

本批是 `.conf` 非密钥结构导入与纯逻辑检查，不是完整凭据导入、Keychain、WireGuardKit 集成或可用 VPN。

远端读取基线为 `ba12bbf2ff75249d110532157c7d46e26a33b93b`。上一轮 `localdev-ui-fixes.patch` 仍单独交付，用户是否应用及其 Mac 结果未知。本批同时提供相对上一轮界面补丁的增量更新和相对远端基线的组合更新，不要求猜测本地状态。本次没有远端写入或新远端提交。

Mac Runner 状态查询失败（tunnel client 未连接）。本轮执行环境为 Linux x86_64、Swift 6.2.1；通过连接器读取仓库，验证所需原始源文件按 Git blob 比对。不是完整 Git clone；没有恢复或运行依赖 PolicyCore 的独立测试目录。四个 PolicyCore 产品源文件及 AppCore 原始基线与仓库一致，没有用替代编译器代替真正逻辑。

## 已执行的代码验证

| 项目 | 结果 | 边界 |
| --- | --- | --- |
| AppCore Debug，warnings-as-errors | PASS，94 tests | 原始 28 + 前轮编辑 24 + 新 WireGuard 42；参数化用例按 Swift Testing 的测试计数报告 |
| AppCore Release，warnings-as-errors | PASS，94 tests | 优化构建与同一测试集 |
| LocalDev Python 合同 | PASS，30 tests | 原 12 + 编辑 8 + 本轮 10；不是 GUI 或行为安全证明 |
| SwiftUI 语法解析 | PASS | 不包含 macOS SDK 类型检查 |
| 原 Xcode 工程 plist | PASS | 工程未改；不是 xcodebuild |
| 原构建脚本 Bash 语法 | PASS | 构建入口未改；不是 Mac 构建 |
| Git diff 空白检查 | PASS | 无空白错误 |

Release 首次执行超出工具单次等待窗口；最终重新执行完整命令实际成功后才记录 PASS。未把超时或编译进度当成通过。

命令：

```sh
swift test --package-path Packages/AppCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/AppCore -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/localdev -v
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh
git diff --check
```

新测试覆盖：密钥格式/重复公钥/无密钥序列化，重复/未知/脚本指令拒绝，UTF-8/BOM/CRLF，IPv4/IPv6/Endpoint/数值校验，大小/行数/Peer/前缀限制，主机位及 AllowedIPs 不变性，IPv6/未解析端点阻断，基线冲突和保存失败可重试，v1/v2 和损坏文件保护，真实约束编译器的 Peer 分配/越界/基础设施冲突/first-match，原文件不变及末级符号链接、目录、FIFO、超大文件、NUL 路径拒绝。

原 AppCore 关于“未来版本”的两处输入从 2 改为 3，因为本批已明确支持 v2；对应的拒绝和原文件不变断言仍保留，另外增加 v1 可读、v2 round-trip 和未来 metadata 拒绝测试。不是删除失败用例。

## 更新包验证

PASS：Linux 临时、合成 Git 工作区中完成 20 项交付检查：

- 两个精确起点（ba12bbf 所需源码镜像、上一轮 UI 补丁后镜像）分别检查无写入、自动选择正确补丁、逐文件 SHA-256 验证、Git index 不变、重复应用无操作、反向补丁恢复源码镜像；共 8 项。
- 相关源码被编辑、新增文件碰撞、上一轮 UI 只应用一部分、PolicyCore 依赖改变，均在写入前拒绝并保留文件；4 项。
- 末级与祖先路径符号链接拒绝且不改目标；2 项。
- 不相关的本地笔记及 `.local` 哨兵文件保持不变；1 项。
- 补丁损坏、校验清单截断、源文件清单损坏均在写入前拒绝；3 项。
- 非仓库目录与不支持的参数拒绝；2 项。

包包含增量/组合补丁、前后镜像清单、交付文件校验和与 `apply.sh`。校验和仅验证交付完整性，不是发布者身份认证或 macOS 代码签名。验证只针对本轮精确镜像和合成冲突样本，不保证同一用户进程并发改写时的原子事务；应用时应停止其他源码编辑/更新操作。

最终文档加入证据后重新生成补丁与校验和，并重跑上述交付检查。没有执行 Git 提交、推送、应用安装、用户草稿读取或网络修改。源码可逆不代表用户首次导入后的 v2 工作区可由旧程序读取。

## 未执行与未实现

NOT RUN：本批 macOS SDK 类型检查、Xcode 构建、真实 ad-hoc 检查、文件选择器/导入报告/保存取消/Command-Q/Dock/旧编辑流程 GUI 验收、Mac 文件系统的专项行为、新的 Mac 更新脚本运行。旧版用户报告能打开不能补足本批验收。

NOT RUN：独立 PolicyCore 全部 79 项、原 S0/S1 完整测试；这些历史结果未当作本轮执行。

NOT IMPLEMENTED：Keychain 凭据持久化与跨目标访问、可建立隧道的完整导入、OpenVPN、WireGuardKit、Endpoint DNS 解析、完整 DNSPlan、物理拓扑发现、真实 Network Epoch、真实隧道/路由/DNS/出口验证。

目录/文件权限及原子保存使用原 DraftStore。本批不建立新的凭据存储，不声称可靠内存零化、源 .conf 已加密或网络结构已完整脱敏。导入只保存非密钥结构，原文件保持不变，真实连接需重新导入凭据。

## 权限、恢复与下一步

不添加 entitlement、扩展、root、通用命令执行或网络请求。文件读取由用户选择并确认；取消不写工作区，失败保存保留原文件与输入。导入成功才升级 v2，旧开发版会拒绝，源码回退不能自动回退用户数据。

停止测试直接退出；没有本批需要撤销的网络修改。补丁只改仓库源码，不删除草稿、.local 或原配置。存在后续本地改动时不强制反向应用。后续 LD-02B 单独实现/验证 Keychain、重导入、删除和失败恢复；真实 Managed 联调前恢复开发签名，阶段门槛未关闭。
