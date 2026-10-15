# ADR-EX-INT-08：watchdog 阶段二——VPN 异常响应（relay 热暂停 + 路由例外一键撤销）

日期：2026-10-15。状态：Accepted。关联 ADR-EX-INT-07、ADR-EX-FLOW-02、EX-INT-03B/03D；修订 ADR-EX-FLOW-02 的 provider message 只读声明。

## 背景

EX-INT-07 已能在真机识别第三方 VPN 断开/重连/形态变化并提示。用户提出两个后续问题：VPN 异常时能否中断被分流软件的联网，以及分流例外能否自动收起。阶段一 ADR 约定阶段二默认仍须用户确认，不做静默自动。

## 决定

1. **Flow 线：relay 热暂停，fail-closed。** provider message 通道新增两个无参数动词 `relay-pause-v1` / `relay-resume-v1`（修订 ADR-EX-FLOW-02 的只读声明；写面仅限这两个动词，不带参数、不改规则、不持久化）。暂停语义：匹配 DIRECT 的 TCP flow 被接管并**立即关闭**（计入 `relayRefusedPaused`），不 return false 交还系统——否则 VPN 断开时这些流量会落到系统默认直连，等于没有中断；未匹配 flow 不受影响。报告新增 `relayPaused` / `relayRefusedPaused` 字段（向后兼容解码）。暂停是 provider 运行时状态，重启探针后失效（规则仍在，relay 恢复），偏安全方向。
2. **暂停动作只能在 Flow Probe App 内显式点击。** 预览 App 不持有 NE 会话，无法直达 provider；预览 App 的职责是检测、横幅提示并引导。Flow Probe App 新增「暂停 DIRECT relay」「恢复 DIRECT relay」按钮，仍无自动触发。
3. **Route 线：响应 = 撤销例外，不做断网。** watchdog 异常时预览 App 显示醒目横幅，一键「停止分流会话」调用现有 `helper.stop()`（走 recovery 语义，只删除可认领路由）。明确不做黑洞/REJECT 路由（AGENTS.md 边界）：VPN 断开后被撤销例外的目标回到系统默认路径，不声称切断其联网。
4. **watchdog 保持纯净。** `ExternalWatchdogModel` 不引用 Helper/Flow；联动编排在视图层横幅。`activeAlert` 只是呈现状态：异常/形态变化事件置位，重连或用户「知道了」清除。
5. 全部动作默认须用户点击确认；自动响应开关留待后续 ADR 与真机证据。

## 后果

- 合同测试更新：`tests/external_flow/test_contracts.py` 断言 provider 写面仅限两个动词、报告新增字段、Flow Probe App 按钮显式无自动；`tests/external/test_watchdog_contract.py` 增加横幅接线断言，watchdog model 禁耦合断言不变。
- provider 二进制变更需重新签名、公证并替换系统扩展（CFBundleVersion 递增机制已在 FLOW-02 修复）。
- "VPN 假在线"（路由形态正常但实际断流）仍不可识别，属后续主动探测 ADR 范围。
