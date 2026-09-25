# LD-03B：统一模拟生命周期与定时回调隔离

日期：2026-09-25。基线 `70a7440e680de41c7adb343d147dfcf352aee9fb`，tree `a78932ae0ab456fccc890178dc1d53558a0a27c2`。任务 LD-03B、S4-04 前置；T-LD-B01–B05、T-U02–U05；Refs #1。[ADR-012](../adr/ADR-012-localdev-simulation-lifecycle.md)、[操作清单](../localdev-simulation.md)。

## 交付

LocalSession 统一状态和错误原因，SimulationDriver 独立管理模拟工作与截止时间；UI 使用命令/事件而不是自行睡眠后写成功。增加正常、认证失败、无响应超时、成功后中断四种场景；独立取消/停止 token；3 秒模拟截止与显式手动重试。配置/选择/编辑/凭据操作/批准退出使旧回调失效，手动网络变化同时清除预览。

回调绑定尝试、策略及完整计划上下文。重复开始不破坏当前会话，迟到/重复/越序回调被拒绝；驱动自己的 operation ID 与 attempt ID 独立。成功回调还检查绝对单调时钟期限，防止忙碌执行器先处理过期成功。

过程记录为最近 32 个静态事件，仅内存保存，清空不取消模拟；无名称、目标或密钥回显。主规则/检查页面和已修复的 HSplitView 不变，开发控件保持折叠。模拟不使用真实凭据，也不调用 Keychain。

## 本轮执行

环境为 x86_64 Linux、Swift 6.2.1。Mac Runner 请求返回 404 / tunnel_client_not_seen，未执行 Mac SDK 或 GUI。按 Git blob 核对重建了基线完整 AppCore/PolicyCore 生产源码、175 项 AppCore 测试、59 项离线合同、工程与脚本；没有用替代算法或删减原套件补足结果。

| 检查 | 实际结果 | 限制 |
| --- | --- | --- |
| AppCore Debug，warnings-as-errors | PASS，202 tests | 原 175 + 27 个测试函数，部分参数化；使用真实 PolicyCore |
| AppCore Release，warnings-as-errors | PASS，202 tests | 相同测试集的优化构建 |
| Python LocalDev 合同/编排 | PASS，66 tests | 原 59 + 7 项；原有两处版本标识跟随 LD-03B，不移除旧保护断言 |
| 统一 tools/localdev/test.sh | PASS，exit 0 | 本轮完整顺序执行以上三组 |
| SwiftUI parse、工程 plist、Bash 语法 | PASS | 仅语法/结构检查，不是 macOS SDK 类型检查或 GUI |

前两次前台统一执行被工具时限中断，不计完整 PASS；随后通过持久运行进程完整重跑，取得 exit 0。初期部分源码回归只作开发检查，不将其数量算作完整基线；最终以 202/202/66 为准。没有单独重跑 PolicyCore 79 项独立套件或 S0/S1 实验，不借用历史结果。

命令：

```sh
/bin/bash tools/localdev/test.sh
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh tools/localdev/test.sh
```

## 测试追踪

T-LD-B01：真实规则编译、缺失配置、未支持类型、Peer 范围及 Endpoint 冲突阻止模拟；重复开始保留旧预览/尝试；每个上下文字段和策略/尝试身份独立不匹配均拒绝。

T-LD-B02：成功单次消费、认证/超时/中断区分、连接中取消与成功后停止、重复停止、迟到停止、旧回调、手动重试、配置保存/选择/删除/重新检查及其他失效原因；失败保存保留已接受状态。

T-LD-B03：虚拟调度下独立截止、工作完成与超时竞态、强制交付已取消回调、重用 attempt 的驱动代次隔离、重入取消、释放驱动；忙碌执行器的过期成功不能击败截止时间。另用真实 Linux Task.sleep 验证定时器触发与立即取消，不等同 Mac 调度时序验收。

T-LD-B04：结构参数保存保留规则并使尝试失效；重启不恢复模拟或历史；32 项记录有界、无用户文本/凭据字段，清空不改变活跃尝试。原凭据事务与编辑回归一起执行，均使用替身而非系统 Keychain。

T-LD-B05：模型命令和 UI 按钮接线、单驱动、批准退出才停止、编辑/凭据互斥、版本/模拟提示、无新网络/密钥接口等离线检查；不是像素或原生交互证明。

## 未执行、权限与恢复

NOT RUN：LD-03B macOS SDK 构建、ad-hoc 产物检查、场景选择/按钮状态/取消/退出/布局的实际窗口验证。LD-03A 参数及更早 Keychain 合成授权、读回、重编译访问和清理恢复仍未获得用户逐项结果。本轮用户只要求继续推进，没有新增真机通过证据。

NOT IMPLEMENTED：真实 WireGuard/OpenVPN/External、真实断线重连、系统网络/睡醒观察、DNS/实际出口探测、真实隧道取消/撤销确认和停机超时。本地 3 秒/250 毫秒定时器不是系统或协议完成证据，同步规则检查不可抢占。

没有新权限、依赖、工作区/凭据记录版本、PolicyCore 算法、Keychain 行为、正式 App/PacketTunnel 工程或签名变化。不自动重试，不修改已有配置、AllowedIPs、原 .conf、系统路由或 DNS；事件只有显式模拟与本地失效。

停止模拟/退出无需网络回滚；旧凭据恢复规程保持原样。源码通过后继提交撤回，不 force/reset/clean，不删除工作区、锁文件、Keychain 或 .local。main 仍是唯一日常入口；先退出旧 App 再拉取构建。开发签名继续暂停，真实 Managed 联调前恢复。
