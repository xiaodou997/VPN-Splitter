# ADR-EX-INT-07：第三方 VPN 健康监测（watchdog，只读提示阶段）

日期：2026-10-14。状态：Accepted。关联 ADR-EX-INT-01/02/05、EX-INT-03B/03D、ADR-EX-FLOW-02。

## 背景

External 分流的前提是"第三方全局 VPN 在线且形态可识别"。真机已验证两类故障面：第三方 VPN 自身掉线/重连/kill switch（ex-flow-02 实测 StrongVPN kill switch 阻断物理出口，relay fail-closed），以及我们自身组件故障（Helper 恢复审计、provider fail-closed）。但 App 层此前只有手动单次快照：VPN 掉线、重连换 utun 接口、切换物理网络时，已展示/已应用的分流语义静默失效，用户无从得知。docs/external-development.md 也明确旧快照"不是实时监视器"。

## 决定

1. 新增只读健康监测，分两阶段。本批只做阶段一：用户在概览页显式点击"开始监测"后，预览 App 以固定间隔复用现有 `ExternalSystemSnapshotReader` 只读采集，对每张快照运行现有 `ExternalPlanner.topology` 判定，分类健康状态并记录状态迁移事件，只在界面上提示。**不自动暂停规则、不自动撤销路由、不触碰 Helper/Flow/系统状态。**
2. 判定逻辑是纯逻辑，放在 ExternalCore target 的跨平台文件（`ExternalWatchdog.swift`），输入为 `ExternalObservation` 或采集错误，输出为健康分类与迁移事件；不新增采集通道、不新增 `Process` 调用、不引入 `#if os(macOS)` 依赖。
3. 健康分类只有两档：`online`（唯一物理路径 + 唯一全局隧道路由形态，与预览同一判定）与 `unavailable`（带原因码，复用 `ExternalError`）。迁移事件区分：VPN 断开（隧道形态消失）、物理网络丢失/切换、隧道接口更换（重连）、路由形态变化、观测读取失败。稳态不产生事件；事件日志有界（≤50 条），仅内存保存，不落盘。
4. 监测由按钮显式启动/停止；睡眠/唤醒与取消检测时一并停止，与现有快照生命周期一致。不引入定时器自启、后台常驻或通知中心推送。
5. 提示文案保持保守：`online` 只表示路由形态可识别，不代表厂商、加密、端点或强制策略已验证；`unavailable` 只表示当前形态不再满足判定，不声称 VPN 一定断开。

## 后果

- `docs/external-development.md` 中"不是实时监视器"的表述更新为：监测是可选、手动启动、只读提示，不改变网络。
- 阶段二（检测到 VPN 异常后自动挂起分流/自动撤销已应用路由）不在本批；它需要 route-trial 真机闭环之后另行 ADR，且默认仍须用户确认。
- 监测复用同一采集，每次轮询等价于一次手动"检测网络"的读取成本；不增加权限需求，无需签名/Helper/扩展。
- 合同测试新增：watchdog 源码不得出现写路由、写 DNS、SystemConfiguration 写、Helper 调用或自动启动 token。
