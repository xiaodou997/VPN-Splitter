# EX-UI-NAV-01：External 主窗口导航与菜单重构

日期：2026-09-29。用户反馈现有 External 开发窗口把网络观察、规则、Helper、恢复与诊断堆在一个长页面，不利于日常使用；要求该增加菜单的地方使用菜单，不要把所有内容放在一个界面。

## 实现

主窗口从单一 ScrollView 改为 NavigationSplitView：

- 概览：只显示当前方案、网络快照状态、Helper/恢复摘要和常用入口。
- 规则：独立承载方案选择、规则编辑、批量输入、保存/删除。
- 分流会话：网络检测、路由预览、Helper prepare/apply/stop。
- 恢复：仅显示 recoveryRequired 核查与安全 marker 清除。
- Flow 实验：仅显示 APPLICATION/DOMAIN Flow Bypass 的开发/能力状态。

Helper 注册、系统授权、打开系统设置和注销移动到 macOS 原生 Settings scene，不再占据日常主页面。

菜单栏新增“导航”“规则”“分流”：Cmd+1…5 切换页面，Cmd-S 保存方案，Cmd-R 检测网络，Cmd-Shift-P 预览，Cmd-. 请求停止。菜单动作调用原有模型方法，不新增绕过 Helper 预检、用户确认或 recovery 安全门的执行路径。

睡眠/唤醒仍取消陈旧网络观察并撤销 Helper 连接；方案编辑仍使旧预览失效。退出仍复用未保存规则和未确认清理保护。

## 验证边界

更新源码合同测试，使其检查 App + NavigationView 联合行为，而不把按钮强行绑定在 ExternalPreviewApp.swift；Helper 模型测试也与拆分后的 Session/Recovery/Settings views 解耦。

本轮环境没有用户 Mac GUI 自动化能力，因此未声称真实 SwiftUI 渲染、窗口尺寸、菜单可用性或 VoiceOver 已通过。需用 `git pull --ff-only && /bin/bash dev.sh external-run` 做一次集中原生开窗验收；该入口仍是 ad-hoc 预览，不会获得 Helper 特权。
