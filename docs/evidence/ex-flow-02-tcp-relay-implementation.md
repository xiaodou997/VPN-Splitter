# EX-FLOW-02：TCP DIRECT relay 数据面实现证据（离线）

日期：2026-10-14。提交范围：FLOW-02 两笔提交（核心+wire 与 provider 集成+构建链）。ADR：docs/adr/ADR-EX-FLOW-02-tcp-direct-relay.md。

## 结论

- FLOW-02 TCP DIRECT relay 数据面已**离线实现并通过全部离线回归**；真机验证 **NOT_RUN**。
- APPLICATION/DOMAIN-* 规则执行路径首次存在，但在真机出口对照、循环检查与共存验证完成前不宣称可用（AGENTS.md 边界不变）。
- 默认行为不变：无规则时 provider 仍是 pass-through 探针，所有 flow 返回 false。

## 已执行（本机，离线）

| 验证 | 结果 |
|---|---|
| `swift test --package-path Packages/ExternalFlow` Debug + warnings-as-errors | PASS（16 测试，含 relay 双向/EOF/写失败/取消/空闲超时/并发上限 + wire 编译/边界/整体拒绝 6 测试） |
| 同上 Release | PASS |
| `swift build --package-path Packages/ExternalFlow` Debug+Release warnings-as-errors（含 ExternalFlowProvider target） | PASS |
| `swift build --package-path Packages/ExternalCore` Debug warnings-as-errors（含主 App 导出桥） | PASS |
| `dev.sh external-flow-test`（含合同测试 11 项） | PASS |
| `dev.sh external-test` | PASS（19 测试） |
| `dev.sh external-execution-test` | PASS |
| `dev.sh external-helper-test` | PASS（15 测试） |

## 实现要点（与 ADR 对应）

- `ExternalFlowRelayCore.swift`：pipe 抽象 + 双向 relay（EOF 半关闭、错误双侧关闭、cancel、watchdog），界限 64 并发 / 64KB / 75s 空闲。
- `ExternalFlowRulesWire` + `ExternalFlowRulesBridgeStore`：结构化规则 wire（schema `external-flow-rules-v1`，≤64 条、target ≤512B）与本机桥文件（0600、O_NOFOLLOW、原子写）。
- `ExternalFlowPolicy(rulesWire:)`：wire → 编译，任何无效/未解析规则整体拒绝。
- Provider：`startProxy` 装载规则（无效则 `rulesRejected` 并回退纯探针）；`NWPathMonitor` 判定唯一物理接口；匹配 DIRECT 的 TCP flow 由 `ExternalFlowRelayEngine` 异步 fail-closed 接管，`NWConnection` 以 `requiredInterface` 绑定物理接口。
- 报告新增纯计数：`rulesLoaded`、`rulesRejected`、`relayStarted/Active/Completed/Failed/Cancelled`、`relayRefusedInterface/Limit`；Codable 向后兼容（新字段 decodeIfPresent ?? 0）。
- 构建摘要升级 `external-flow-build-v4` / `flow_copying=TCP_ONLY_TRIAL`；合同测试移除 NWConnection 禁令，改守无 UDP、无内容记录、界限常量存在。

## 未执行（下一轮，需用户现场配合）

- 签名构建 / /Applications 安装 / 系统激活：NOT_RUN。
- 受控样本出口对照（DOMAIN、APPLICATION 规则 + curl 出口 IP）：NOT_RUN。
- 循环检查（provider 自建连接不被自身透明代理回捕）：NOT_RUN —— 验证失败则本能力整体保持不可用（ADR 决定 5）。
- UDP/QUIC、DNS、睡眠/切网、VPN 重连：未实现/未验证。
