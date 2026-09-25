# LD-02C：顶部遮挡修正、批量规则与搜索

日期：2026-09-25。基线：`669bc52d4c8bdf752be0300619c98c97d7c7e39b`。任务：LD-UI-05、LD-02C、S4-04 前置；规则要求 T-P01–P03、T-U02–U05；本轮测试 T-LD-C01–C04；Refs #1。

## 用户反馈与诊断

用户明确反馈 LD-02B 构建成功且窗口已打开，截图可见 LD-02B 标识、左侧策略与规则列表，顶部策略标题和操作区被模糊区域遮挡。记为 USER_REPORTED 构建/开窗成功，布局存在缺陷；不记录为完整 GUI、Keychain 或 VPN PASS。用户未提供本机精确 Git SHA、macOS/Xcode 构建版本，不补造。原截图不上传仓库。

源码没有刻意隐藏标题或凭据的遮挡层。旧布局为 VStack 状态栏下嵌套 NavigationSplitView，再含固定标题和 TabView。截图结合源码提示可能是导航栏材质覆盖固定内容；未在 Mac 复现，不把这个推测写成已确定的 Apple 框架故障。

## 代码变化

T-LD-C01：用 HSplitView 移除嵌套导航工具栏，保留可拖动分栏；标题与设置按钮参与正常垂直布局并保留自然高度，不使用负偏移、忽略安全区或大段空白垫高。添加可访问性标识。实际遮挡修复仍待 Mac 验证。

T-LD-C02：增加纯 Swift IPv4RuleBatch、单编辑事务 batch 类型和原生多行输入。每行一个 IPv4/IP-CIDR；规范化结果先展示，全部有效后才追加。大小/规则数量受限，顺序和重复保留，错误只有行号及静态说明。默认出口、名称、既有规则与凭据不变。

T-LD-C03：搜索只返回原规则索引，显示全局编号和数量，不重建策略。搜索期间暂停排序避免歧义；检查始终调用原 session.compile()。搜索词不持久化。

T-LD-C04：批量保存复用既有 DraftEditor 的 baseline、选择/身份检查与原子保存；失败保留输入、旧会话和磁盘数据，成功清除旧预览及模拟 token。取消、退出和凭据互斥沿用原保护。

没有新第三方依赖、系统权限、网络 API、工作区版本、Keychain 行为或 PolicyCore 算法变更，不修改正式 App/PacketTunnel。属于 ADR-008 编辑事务的扩展，不调整 S0–S5 或 IPv6/域名/防泄漏保证。

## 本轮执行

环境：x86_64 Linux，Swift 6.2.1；Mac Runner 连接返回离线，不能执行原生 SDK 或 GUI。基线 AppCore/PolicyCore 源码、已有 AppCore 测试、工程和离线脚本已用 Git blob 核对到远端基线；新代码在这些完整业务源码上回归。

| 检查 | 本轮结果 | 限制 |
| --- | --- | --- |
| AppCore Debug，warnings-as-errors | PASS，152 tests | 原 139 项加 13 个测试函数，部分含参数化子用例 |
| AppCore Release，warnings-as-errors | PASS，152 tests | 同一测试集的优化构建 |
| LocalDev Python 合同与编排 | PASS，51 tests | 原 46 项加 5 项布局/批量/搜索接线；不是像素或 UI 行为测试 |
| 统一 tools/localdev/test.sh | PASS | 实际顺序执行以上三组 |
| SwiftUI 源码 parse、工程 plist、Bash 语法 | PASS | 不是 Xcode 类型检查或签名 |

命令：

```sh
/bin/bash tools/localdev/test.sh
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh tools/localdev/test.sh
```

新增测试覆盖：规范化、重复/顺序、CRLF/BOM/行号、空输入、无效地址、资源限制、拒绝动作、默认例外动作、旧副本/对象删除、脏编辑取消、失败保存/重试、整批拒绝、选择隔离、模拟迟到回调，以及搜索不改变 first-match 结果。没有单独重跑 PolicyCore 的 79 项独立测试、S0 或 S1 原测试；不将历史结果冒充本次执行。

## 未执行与下一步

NOT RUN：LD-02C macOS SDK 构建、ad-hoc 产物检查、实际标题遮挡复验、分栏/窗口/长名称/深浅外观、多行输入与原生退出交互。真实 Keychain 合成增删读、授权拒绝和重导入仍需 LD-02B 的独立证据；截图不填补这些缺口。

下一步先完成新版布局与既有合成导入/凭据闭环的 Mac 验证，再继续配置参数编辑及连接生命周期。开发签名仍暂停，首次真实 Managed 隧道联调前恢复。不能把本轮批量规则或解析成功称为实际 VPN。

## 权限与恢复

仅向现有本地草稿文件显式保存规则；不改变路由、DNS、系统扩展或凭据。本轮无工作区格式升级，旧 v1/v2/v3 按原规则读取。源码经正常后继提交撤回，不 force/reset/clean，不删除用户数据、锁文件或原 .conf。规则可能私密，不上传完整工作区。更新入口仍为 main 和原 build.sh，不要求历史更新包。
