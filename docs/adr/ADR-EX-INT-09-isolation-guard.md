# ADR-EX-INT-09：VPN 隔离守卫（Isolation Guard）与"假在线"探测

日期：2026-10-15。状态：Accepted。关联 ADR-EX-INT-07/08、ADR-EX-FLOW-02；证据见 docs/evidence/ex-int-09-isolation-guard.md。

## 背景

用户提出两个相连的需求：第三方 VPN 断开/异常时，规则覆盖的连接应不能访问公网（隔离，防止泄漏），但不做系统级拦截；以及 VPN"假在线"（客户端显示已连接、路由形态正常但实际断流）目前不可识别。EX-INT-08 的 relay 暂停已是 fail-closed（暂停后匹配 DIRECT 的 TCP flow 被关闭而非交还系统），隔离的执⾏端已经存在，缺的是检测与自动触发。

## 决定

1. **隔离 = 守卫自动发出 relay 暂停，不做系统拦截。** 守卫（Isolation Guard）放在 Flow Probe 宿主 App：预览 App 不持有 NE 会话无法直达 provider，宿主 App 同时具备只读采集能力与 provider message 通道，检测与执行闭环在同一进程。守卫只在用户显式点击「开启」后运行，关闭 App 或点击「关闭」即停止；状态不持久化。
2. **两级检测**：
   - 路由形态（复用 ExternalCore 只读采集 + `ExternalWatchdogTracker`）：隧道形态丢失/物理路径丢失/拓扑不再支持 → 立即暂停。
   - 假在线探测：路由形态在线时，按固定间隔向可配置目标（默认 `captive.apple.com:80`，裸 TCP 握手、不发送任何数据）做双路对照——默认路径（经 VPN）+ 绑定物理接口。判定只看 VPN 路径：连续 2 次失败（约 8 秒）即暂停；物理路径结果只用于界面区分"VPN 断流"与"本地断网"。探测目标若命中当前 DIRECT 规则，守卫拒绝启动（避免探针被自己的 relay 暂停误伤）。
3. **恢复即解除**：路由形态恢复在线且（探测开启时）VPN 路径探测成功 → 自动发 `relay-resume-v1`。只允许守卫自己发起的暂停被自动解除；用户手动暂停不受守卫接管。
4. **fail-closed 语义不变**：暂停期间匹配 DIRECT 的 flow 被关闭；未匹配 flow 始终不受影响。Route 线不做对应隔离（黑洞/REJECT 属边界外）。
5. **防抖动**：假在线需连续 2 次失败才暂停，路由形态事件直接触发；恢复无阈值（首次成功即解除）。守卫运行期间禁用 App Nap（`beginActivity(.userInitiated)`），但不阻止系统睡眠；睡眠/唤醒后下一轮采集自然反映新状态。

## 后果

- 探测向第三方端点（默认 Apple 连通性端点）发起裸 TCP 连接，流量外观与普通 HTTPS 握手一致；目标可由用户更改，不写日志、不发送数据。
- 守卫需要 Flow Probe App 保持运行；App 退出后 provider 维持最后一次状态（若停在暂停，重启探针即恢复，偏安全方向）。
- Flow Probe 宿主 App 新增 ExternalCore 包依赖（复用只读采集与 watchdog 状态机），provider 二进制不变。
- 合同测试新增：守卫显式启动、无持久化、不阻止系统睡眠、探测有超时/阈值界限、只使用既有两个 provider message 动词。
