# EX-INT-03B 协议 v2 整合：真机 XPC 往返与受控 route-trial 闭环

日期：2026-10-14。基线为整合分支 `integration/ex-int-03b-protocol-v2` 顶端 `074d528`（第一批 `4277ae2` 协议 v2 + sustained 生命周期 + 面板修复，第二批 `a285ad9` 目录符号链接/PERF-01，第三批 `074d528` route 证据与 ADR-EX-INT-04），来源为 main `36559bb` 与 backup 线 31 个提交的 range-diff 逐项核对整合。本记录覆盖该基线的真机结果；文档目标、代码合并、编译成功与真机通过分别报告。

## 离线回归（整合分支，真机当日执行）

- `external-helper-test`：Swift 32/32（Debug + Release warnings-as-errors）+ Python 15/15 通过。
- `external-test` 19/19、`external-execution-test` 26/26、`external-flow-test` 9/9 通过。
- 整合过程中修复两处问题：`World.allow()` 测试替身漏解锁（测试基础设施死锁）；`ExternalHelperClient.send()` 的 proxy 错误处理器闭包缺 `@Sendable`，Swift 6（SE-0420）下继承 MainActor 隔离导致 XPC 队列回调断言崩溃（替身测不到，由 `tests/external_helper/test_native_xpc.py` interrupted 场景抓出，属真实缺陷）。

## 服务代际切换

- 旧 v1 服务已由一次性签名小工具经 SMAppService 注销，launchd 查无 v1、无残留 Helper 进程。
- 协议 v2 使用新服务名 `io.github.xiaodou997.VPNSplitter.ExternalHelper.v2`（plist 同步），跨代请求应答 `refused/protocolMismatch`，不再误报 `authentication`。

## 只读构建真机验证（`control.0p_7dzc2`，route_trial=DISABLED）

- Developer ID（V6M88BQG7C）签名、strict codesign 通过；未公证（本机开发验证）。装入 /Applications，旧版备份在本机忽略目录。
- GUI 注册 v2：申请授权 → 用户在系统设置批准（USER_REPORTED，触控ID）→ 注册状态 enabled。
- 「测试 Helper 通信（只读）」通过：签名校验、root 对端检查、hello 与 status 往返成功，服务状态 idle/none。这是 main 线此前 `unavailable` 阻塞点（协议代际不匹配）的正式闭环。
- 「核查恢复状态（只读）」：noRecovery。
- 未注册状态下探针精确报 `serviceNotEnabled`（错误分类生效）。

## route-trial 构建真机验证（`control.ih56f6nz`，route_trial=COMPILED_EXPLICIT_OPT_IN，FINITE_TRIAL 60 秒上限）

- 与只读构建同一 commit（`074d528`）重建，未复用旧 Helper 二进制；strict codesign 通过、未公证。换入 /Applications 后重新注册，系统未要求重新批准（沿用既有授权）。
- 防御行为实测：第三方 VPN 未连接时，GUI 只读检测报 `tunnelUnknown`，Helper 预检拒绝 `observationFailed`，无任何路由残留。
- 受控闭环（StrongVPN 已连接，utun4 持 0/1 + 128.0/1，目标基线经 VPN；apply 由用户本人现场点击，USER_REPORTED）：
  - 预检提案：`81.69.116.102/32 → 192.168.2.1 / en0 · wouldAdd`，15 秒确认窗口内勾选并应用。
  - 16:20:09 `route -n get 81.69.116.102` 显示经 en0 / 192.168.2.1 直连（ADD 生效，绕过 utun4）。
  - 16:20:31 Helper 日志 `lease_terminal state=closed code=none owned=0 comparison=unchanged cleanup=none`。
  - 16:20:38 起路由表无该主机路由，目标恢复经 utun4 / 100.64.8.1。
  - 事后 GUI「核查恢复状态（只读）」：noRecovery。
  - 撤销路径与 60 秒自动到期时间线吻合；日志未区分手动停止与到期，按未区分记录。

## 结论与边界

GUI → 认证 Helper → prepare/apply → ADD → 内核读回 → 自动撤销 → 零残留审计的完整链路首次在真机通过。这不是可用 VPN 分流验收：目标实际流量（双出口对照）未测，sustained 模式未上真机，route_trial 仍为显式编译开关、默认构建禁用写入。已知 UX 限制：15 秒确认窗口叠加每秒状态轮询使 AX 自动化操作不可靠（SwiftUI Toggle 不响应合成鼠标事件，AXPress 有效）；主窗口关闭后点 Dock 不重开（Cmd+N 可开），待后续修复。
