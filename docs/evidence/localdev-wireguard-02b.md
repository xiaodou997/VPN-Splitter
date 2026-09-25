# LD-02B：凭据事务、重新导入与清理恢复

> 历史批次记录：当时通过本地包交付。现统一从 main 更新，不再应用这些包；本轮重新执行结果见 [main 整合证据](localdev-main-integration.md)。下文测试归属与当时 NOT RUN 保留。

日期：2026-09-25。任务 LD-02B / S1-03 部分；关联 LD-UI-01/02、T-U02–U05、T-W06，新增 T-KC01–T-KC08。代码通过本地更新包交付，未提交远端，不关闭 S0–S5 的真实技术门槛。

## 来源和证据级别

远端 main 读取为 ba12bbf2ff75249d110532157c7d46e26a33b93b。上一批 `vpn-splitter-wg-localdev.zip` 已在当前环境展开，源文件按其 after.tsv 的 30 项 SHA-256 逐一校验；PolicyCore 源码未修改。它是用于离线验证的受影响源文件快照，不是完整仓库 clone。

执行环境：Linux x86_64、Swift 6.2.1。Mac Runner 调用返回 tunnel-client 未在线。没有在用户机器安装/更新、运行 Xcode、触碰 Keychain 或建立隧道。用户也尚未提供上一批补丁的逐项验收，因此不假定其本机已经应用。

## 实际执行

| 检查 | 结果 | 限制 |
| --- | --- | --- |
| 原 LD-02A 快照 AppCore Debug | PASS，94 tests | 本轮先实跑的回归基线 |
| 当前 AppCore Debug，warnings-as-errors | PASS，139 tests | 94 原有 + 45 新增测试声明；参数化用例包含多种错误 |
| 当前 AppCore Release，warnings-as-errors | PASS，139 tests | 优化构建；不是 macOS 构建 |
| Python LocalDev 合同 | PASS，42 tests | 12 新增接线合同，非 Security.framework 行为测试 |
| SwiftUI / 原生适配器语法解析 | PASS | parse-only，不是 macOS SDK 类型检查 |
| Xcode plist / Bash 语法 / Git diff 空白检查 | PASS | 不替代 Xcode 或运行测试 |
| 更新包三种起点、一致性与冲突测试 | PASS，22 tests | Linux 临时 Git 树；不等于用户 Mac 更新 |

Release 初次编译两次遇到工具调用超时；使用同一源码完成后实际运行 139 项成功，以完整通过日志为准，不把超时记成通过。测试过程中发现并修正一条合成测试把接口本机地址包含在显式 VPN 规则中的冲突，保留 PolicyCore 的基础设施拒绝行为，没有放宽规则来让测试通过。

命令：

```sh
swift test --package-path Packages/AppCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/AppCore -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/localdev -v
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift Packages/AppCore/Sources/AppCore/KeychainCredentialVault.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh
git diff --check
```

## 新增覆盖

T-KC01：v1/v2 往返兼容、v3 元数据和引用、未来版本拒绝；私钥/公钥/PSK/源路径不进入 workspace；调试描述和 Mirror 脱敏。PASS。没有内存零化保证。

T-KC02：准备日志写入失败时不访问 vault；模拟拒绝/取消/不可用/碰撞/写入后报错、读回不匹配、最终文件保存失败；旧策略/旧凭据保留，新引用可清理后重试。PASS（注入替身）。

T-KC03：重导入保留策略与规则身份、名称、默认动作、规则顺序；仅结构替换显式解除旧凭据；过期/重复确认、错误后端、超限在副作用前拒绝。PASS。

T-KC04：先解除引用，再删已验证项；解除写入失败不删 Keychain，清理确认写入失败可在重新加载后幂等重试。缺失条目视为已清理，不可读取或不匹配不能删除。PASS（注入替身）。

T-KC05：另一策略的凭据不受影响、定向清理不处理其他排队项、UUID 相撞的异属记录不覆盖/删除、损坏记录保留、磁盘变更停止。PASS。

T-KC06：真实临时目录 DraftStore 准备记录往返和 0600 文件；lease 非阻塞互斥/释放、符号链接锁拒绝。Linux PASS。Mac APFS/系统临时目录/多进程 GUI 仍 NOT RUN；不声明锁可阻止旧版本。

T-KC07：原生适配只使用独立 file-based generic-password service/account，读回比对完整记录，删除先核验归属并使用 persistent reference 与精确属性。只有源码合同/语法 PASS，真实 SecItem 返回值和授权行为 NOT RUN。Linux 原生入口抛 unavailable，无明文或内存运行后备。

T-KC08：UI 用户确认才保存、无启动 vault 调用、后台工作避免阻塞主线程、忙碌时禁止编辑/普通退出、失败保留报告与准备记录、全局/报告内重试入口。源码合同 PASS，实际 SwiftUI/macOS 生命周期 NOT RUN。

## 未执行 / 未承诺

NOT RUN：macOS 26+ / arm64 SDK 类型检查、实际 ad-hoc 构建/读取权限、系统 Keychain 增删读、拒绝/取消授权、跨重编译访问、窗口/Sheet/Dock/Command-Q 行为、原生进程崩溃和 Keychain 服务中断。

未重跑独立 PolicyCore 79 项、S0、S1 套件；未复制其历史 PASS 为本轮结果。本轮 AppCore 仍调用相同 PolicyCore 实现。未实现正式扩展凭据共享、WireGuardKit 数据面、OpenVPN、DNS 解析或任何网络设置操作。

恢复针对已经成功保存的操作记录，不是跨 Keychain/JSON 原子事务；没有目录 fsync / 全盘掉电、数据库损坏、备份回滚后孤立项找回保证，不自动扫描 Keychain。不保证内存零化、Secure Enclave 或锁屏访问特性。

## 权限与撤回

仅用户确认后写自己的 LocalDev Keychain 项、用户工作区及锁文件；不新增 root / Network Extension 权限或网络 API，不放宽系统 ACL，不写原 .conf。系统 Keychain UI 可能需授权，但本机表现尚未验证。测试全部使用固定字节模式合成密钥，没有真实秘密。

源码包只改本地源文件，无自动 Git 提交/推送、安装或数据迁移。首次凭据准备记录即使用 v3；旧程序拒绝它，不能手改版本回退。已有凭据或待清理记录时不要为回退源码而清空/覆盖 workspace；先在当前可读版本中处理，保留原 .conf。只撤回源码用审核过的逆向补丁或普通提交，不 reset/clean 用户工作区，不删除 .local。

真机人工清单见 [Keychain 指南](../localdev-keychain.md)，决策见 [ADR-010](../adr/ADR-010-localdev-keychain-transactions.md)。先验合成样例，不要求用户上传真实配置或签名资料。

## 交付检查详情

以 ba12bbf、UI 修复版、LD-02A 三种起点分别执行只读检查、应用、39 项最终文件校验、重复应用和逆向源码校验。22 项检查同时覆盖本地源码/文档修改、新文件碰撞、缺失文件、部分旧更新、PolicyCore 变化、源文件/目录链接、包损坏/缺失/重复 checksum、链接包文件、错误参数、非仓库和错误仓库。检查索引与 HEAD 没有变化，未关联文件和 .local 哨兵数据保留。

包内代码/说明更新后重新生成清单并重跑；交付为本地补丁包，不是远端提交。SHA-256 是一致性检查，不是发布签名。本版更新脚本不提供磁盘故障下多文件原子替换或自动回滚。
