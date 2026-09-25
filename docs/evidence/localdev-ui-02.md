# LD-UI-01–04：编辑可靠性与操作简化

> 历史批次记录：当时通过本地包交付。现统一从 main 更新，不再应用这些包；本轮重新执行结果见 [main 整合证据](localdev-main-integration.md)。下文测试归属与当时 NOT RUN 保留。

日期：2026-09-25。基线：`ba12bbf2ff75249d110532157c7d46e26a33b93b`。
关联：S4-04 前置、T-U02–U05；新增回归 T-LD06–T-LD09。前序[源码审查](localdev-01-user-review.md)，决策 [ADR-008](../adr/ADR-008-localdev-edit-transactions.md)。

## 交付状态

GitHub 写入调用被工具拦截；再次读取远端 main 仍为上述基线。**没有推进 main，也没有发布本轮提交。** 本轮通过 `localdev-ui-fixes.patch` 交付；源码、测试和文档都在补丁内。应用补丁不自动提交或推送。

## 已交付范围

LD-UI-01：规则编辑改为单事务；模态窗口打开时背景修改入口被禁止；即使绕过 UI，也通过基线和选中策略检查拒绝旧副本覆盖。两个方向的启用 / 禁用冲突都已通过离线测试。

LD-UI-02：编辑缓冲上移到 App 模型；切换编辑对象不会替换当前事务，旧绑定 ID 无法更新新事务。取消脏缓冲要求明确放弃；失败保存保持输入。退出菜单及系统退出委托共用继续 / 保存 / 放弃决策，原生行为待 Mac 验证。

LD-UI-03：提供中文错误说明、规则编号、列表提示和返回编辑按钮。继续调用原 PolicyCore；错误信息不回显非法目标或任意 Error 内容。

LD-UI-04：主页面缩为规则 / 检查，设置集中在独立窗口，模式改中文；开发工具和技术详情折叠；规则及策略删除都要求确认。没有新增真实连接能力。

## 本轮实际执行

环境：x86_64 Linux、Swift 6.2.1。Mac Runner 查询返回连接不在线，未运行 Mac 命令。需要的基线文件通过 GitHub 内容读取后在隔离容器中还原；原 AppCore 源码 / 测试、四个 PolicyCore 源文件、包清单、工程 / scheme / 原合同测试 / 构建脚本按 Git blob SHA 校验，未用简化 stub 代替。

| 检查 | 结果 | 含义 |
| --- | --- | --- |
| AppCore Debug，warnings-as-errors | PASS，52 tests | 原 28 + 新增 24 个测试声明；参数化用例另覆盖双向状态 |
| AppCore Release，warnings-as-errors | PASS，52 tests | 同一测试集的优化构建 |
| Python LocalDev 合同检查 | PASS，20 tests | 原 12 + 新增 8；只证明源码连接 / 工程合同，不是 GUI 运行 |
| SwiftUI 源码语法解析 | PASS | 不是 macOS SDK 类型检查 |
| 工程 plist、Bash 语法 | PASS | 原文件未修改；不是 xcodebuild |
| 补丁应用与撤回 | PASS | 在临时 Git 工作区检查 / 应用，8 文件逐字节比对；重复应用拒绝、反向应用恢复、已有文件冲突拒绝 |

可重复命令：

```sh
swift test --package-path Packages/AppCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/AppCore -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/localdev -v
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh
```

T-LD06：旧启用状态覆盖拒绝、删除不复活、事务 / 规则 ID 保护、单编辑入口、旧绑定不改新编辑、选中策略改变时拒绝提交。PASS（纯逻辑）。

T-LD07：取消保留 / 显式放弃、恢复原值不脏、成功保存及预览失效、存储失败不丢输入 / 不改磁盘且可重试、格式失败不关闭、JSON 版本和既有规则不变、无改动保存不重写。PASS（纯逻辑）。

T-LD08：多个非法启用 IP 定位、禁用草稿处理、DOMAIN 编译器错误映射、External 模式提示、非法输入和任意错误不回显。PASS（真实核心 + 展示适配）。

T-LD09：模型动作锁、App 级缓冲、modal 取消保护、退出入口共享检查、删除确认、开发控件折叠、规则反馈接线。PASS（静态合同）；Mac 行为 NOT RUN。

## 不计入通过的项目

用户此前报告的 LocalDev 编译 / ad-hoc 检查 / 窗口打开继续为 USER_REPORTED PASS，归属旧版启动记录，**不能覆盖此次改动的 GUI 验收**。

本轮未执行 macOS SDK 编译、Xcode 构建、实际 ad-hoc 检查、屏幕布局、辅助功能、sheet / Command-Q / Dock 退出或重启持久化的真机测试。人工清单见 [操作文档](../localdev.md)。强制退出、崩溃、断电保存未提交输入不在保证范围。

未重跑 PolicyCore 独立 79 项测试及 S0 / S1 测试；其源码未修改，历史结果不记成本轮执行。没有路由 / DNS / 扩展操作、真实认证或 VPN 出口测试。`.conf` / `.ovpn`、Keychain、基础设施 / peer 校验 UI 仍未实现。

## 权限、兼容与撤回

没有新增权限或第三方依赖，构建目标及本地签名不变。写入仍仅限独立用户草稿文件，schemaVersion 1 不变，不迁移 / 清空数据。跨进程写入与文件系统竞争仍不提供保证，不将内存基线比较当作文件锁。

未提交的补丁可先运行 `git apply -R --check`，通过后再反向应用；之后已提交的变更可用正常源码 revert 撤回。不要强制覆盖后续修改；不删除用户数据、不重写历史、不撤销系统网络设置，因为本轮没有申请这些操作。更新前先保存并退出旧 App，在本地 main 工作区检查并应用本轮补丁后再构建。开发签名继续暂停；后续按 LD-02 / S1-03 推进导入和凭据边界。
