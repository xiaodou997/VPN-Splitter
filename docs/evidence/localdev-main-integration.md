# LocalDev 三批整合到 main 与统一回归

日期：2026-09-25。任务 LD-UI-01–04、LD-02A、LD-02B、S1-03 部分、S4-04 前置；Refs #1。

## 用户状态与交付

用户明确要求直接修改并推送 main，并说明之前 UI、WireGuard 与 Keychain 更新包均未下载。不能把这些版本写成用户已安装或实测。本次从远端 ba12bbf2ff75249d110532157c7d46e26a33b93b（tree 18556316c9444de73fe9c3ae2f9d500cacc238b0）整合完整代码、测试、合成夹具和文档；不要求用户按顺序应用历史包。

代码包含：独立编辑事务、旧副本覆盖保护、保存失败保留输入、取消/退出保护、主界面简化；WireGuard .conf 结构解析与配置提供的端点/DNS/接口/Peer 范围检查；显式 Keychain 保存/读回、同策略重新导入、解除引用与精确清理、可重试记录和本版实例间锁。主界面标识 LD-02B，始终显示“本地开发模式：不接管网络”。

本次新增 tools/localdev/test.sh，顺序执行 AppCore Debug、Release 和 Python 合同测试；任一失败即停止，不输出 PASS。新增 4 个编排测试，覆盖带空格路径、执行顺序和失败停止。没有自动运行真实 Keychain、GUI、S0 路由实验或正式扩展。

源码整合前，累计包 39 个文件的 SHA-256 全部与包内 after.tsv 一致，反向恢复也与 before-main.tsv 一致。累计包 SHA-256 为 8c33d69c039a7fe709bc908f59345316d3d2bec949ff0ff3fd6e544ead65e062。它用于核对前几批代码没有遗漏，不是用户更新入口，也不等于发布签名。

## 本轮实际执行

环境：x86_64 Linux、Swift 6.2.1。Mac Runner 不在线。本轮 PASS 都是本次实际执行，不借用旧版用户开窗结果。

| 检查 | 本轮结果 | 边界 |
| --- | --- | --- |
| AppCore Debug，warnings-as-errors | PASS，139 tests | 含真实 PolicyCore、编辑/导入/凭据事务逻辑；凭据后端为故障注入替身 |
| AppCore Release，warnings-as-errors | PASS，139 tests | 同一测试集的优化构建 |
| LocalDev Python 检查 | PASS，46 tests | 原 42 项源码/工程合同 + 新增 4 项统一入口编排；不是 GUI 测试 |
| 统一 test.sh | PASS | 实际顺序重跑上述三组；非仅模拟命令 |
| SwiftUI / Keychain Swift 源码 parse | PASS | 仅语法，不是 macOS SDK 类型检查 |
| Xcode project plist、Bash 语法 | PASS | 不等于 Xcode 构建或真实签名 |

复现：

```sh
/bin/bash tools/localdev/test.sh
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift Packages/AppCore/Sources/AppCore/KeychainCredentialVault.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh tools/localdev/test.sh
```

统一入口成功结尾：

```text
schema=localdev-tests-v1
core=PASS
contracts=PASS
mac_gui=NOT_RUN
live_keychain=NOT_RUN
network_settings=NOT_APPLIED
```

本轮未单独重跑 PolicyCore 全部 79 项、S0 和 S1 原测试套件；不能把其历史 PASS 记作本次执行。没有更新第三方依赖、PolicyCore 算法、正式 App / Packet Tunnel 工程或签名 entitlement。

## 未执行与门槛

NOT RUN：新版 macOS 26+ arm64 Xcode 构建、ad-hoc 产物检查、窗口/文件选择器/退出交互、真实 Keychain 增删读、授权拒绝、重新编译后的访问与服务中断恢复。正常模拟或故障注入不能证明系统 API 的真实行为。先用合成夹具验收，再考虑真实配置；不要求上传任何真实配置。

NOT IMPLEMENTED：真实 WireGuard / OpenVPN / External 执行、完整 DNS-derived 域名能力、Endpoint 名称解析、物理网络探测和完整配置参数编辑。首次真实 Managed 联调前恢复开发签名；现在继续暂停，S0–S5 门槛不关闭。

## 更新、权限与数据

先保存并完整退出旧 App，在仓库根目录执行 git switch main、git pull --ff-only、/bin/bash tools/localdev/build.sh run。之前三批包不需要下载。遇到本地修改冲突停止，不 force/reset/clean；不删除用户 worktree、分支或 .local。

Git 拉取与构建不迁移工作区，也不触发凭据保存。旧 v1/v2 可直接读取；应用内确认结构导入至少使用 v2，凭据事务准备阶段升级 v3，即使随后授权失败。普通 JSON 仅含结构/规则/引用/待清理引用，不含密钥。不要手改版本、清空工作区或恢复旧 JSON 来回退；原 .conf 始终保留。

新增系统权限影响限于用户主动确认的本机 Keychain 操作，无 root、Network Extension 加载、路由或 DNS 改写。读取失败不盲删，不放宽系统访问控制，不提供明文回退。结构仍可能私密；不上传 workspace、原始日志或授权材料。

源码撤回使用普通后继提交，不改写 main 历史；数据 v3 不自动降级，活动/待清理凭据需通过当前可读版本安全处理。操作与合成清单见 [LocalDev](../localdev.md)、[WireGuard](../localdev-wireguard.md)、[Keychain](../localdev-keychain.md)。
