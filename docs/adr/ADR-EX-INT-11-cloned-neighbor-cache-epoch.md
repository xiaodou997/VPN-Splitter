# ADR-EX-INT-11：克隆邻居缓存行与网络 epoch

日期：2026-10-17。状态：Accepted for implementation；真机复验待完成。关联 EX-INT-05（sustained）、EX-INT-10（域名 sustained 重解析）。取代 ADR-EX-INT-04 在 epoch 比较视图内对同一精确模式的 i 归一化，不改变写入/撤销所有权要求。

## 证据

2026-10-17 真机：EX-INT-10 域名路由 sustained 会话运行约 4.5 分钟后被 Helper 以 networkChanged 保守终止。终止日志：

```
2026-10-17 16:47:43 lease_terminal state=closed code=networkChanged owned=0 comparison=changed cleanup=none
```

终止时快照诊断：`interfaces_changed=false physical_paths_changed=false dns_changed=false`、`routes_added=3 routes_removed=2`，增删行形态仅为 `p32/f=UHLWI/if=en/gw=other` 与 `p32/f=UHLWIi/if=en/gw=other`。即物理接口上的临时克隆邻居行（/32、flags 精确为 UHLWI 或 UHLWIi，即 UP/HOST/LLINFO/WASCLONED ±IFREF 的内核链路层缓存行）整条出现/消失导致 epoch 不等。这类行是内核从 RTF_CLONING 父路由克隆出的邻居解析缓存，正常流量（curl/ARP）就会制造；出口接口与下一跳决策不因其增减而改变。终止本身 fail-closed、零残留（owned=0、cleanup=none），行为安全但过于脆弱，阻碍稳定 sustained 租约。

## 决策与边界

只为网络 epoch 比较视图（ExternalRouteEpoch.rows）增加一条排除规则：当且仅当前缀为 /32 且 flags 精确等于 UHLWI 或 UHLWIi 时，整行从比较键中丢弃；两个方向的出现/消失以及这些行自身的字段变化（网关/MAC、接口、Expire）都不再计入 epoch。ADR-EX-INT-04 对该精确模式的 UHLWIi→UHLWI 归一化随之被覆盖——匹配行不再参与比较，归一化没有作用对象。

保留并扩展"歧义退回原始集合"的防歧义逻辑：丢弃后视图变空而原始集合非空时，退回原始集合（非空路由表不得映射为空 epoch 视图；该退化形态在真实 sustained 会话中不存在，默认/局域网/隧道行从不匹配丢弃模式）。保留行不被修改，丢弃不产生键折叠；ADR-EX-INT-04 的重复键场景（同一邻居 UHLWI 与 UHLWIi 并存）由"两行同时丢弃，若因此变空则整体退回原始集合"覆盖，不以丢弃换取键合并。

严格边界：仅限上述精确 flags 组合。其他任何 flags（UHLW、UHLWi、UHLWIr/S/3/Z、UHLSI、大小写或字母顺序变体等）、非 /32 前缀一律不豁免；静态路由增删、G/S/PROTO2 自有路由、接口集合、DNS、物理路径变化仍使会话拒绝或终止。原始 ExternalRoute 与 parser 输出不变；规划器、冲突检查、原生 ACK/事件/receipt 所有权及 DELETE 前逐项原始读回不经过此视图。不放宽 15 秒确认窗口、快照新鲜度或其他任何既有边界，不增加重试。

这不削弱安全性：克隆行是内核链路层解析缓存，WASCLONED 由内核在克隆时设置，route(8) 没有设置该标志的入口；且安全性不依赖伪造不可能——此视图只回答"网络是否变化"，从不授予写/删权限，所有权检查在 epoch 比较之前基于原始行独立执行，自有路由（UGHS2/UGS2，不匹配丢弃模式）消失仍 readbackFailed/recoveryRequired，伪造的同形行不会因此获得任何权限。同一比较视图仍用于采集器双读一致性、事务 baseline 比较与停止后快照比较；接口与系统配置仍按原要求精确相等。该变化是区分内核缓存扰动与网络变化，不构成任意后台路由变化容忍。

## 验证

须覆盖：克隆行增删双向不改变 epoch、仅限缓存行的字段变化不改变 epoch、静态/owned G/S 行增删仍改变 epoch、非 /32 或非精确 flags 行不豁免、保留行全字段敏感（含非豁免行的 i 差异）、空集与全丢弃退回原始集合边界。ExternalLease 层同步覆盖：缓存行扰动下租约保持 active、非豁免行字段变化仍 networkChanged。Core/Execution/Control 完整离线回归（Debug/Release，warnings-as-errors）须通过。未通过真机 sustained 复验之前不宣称稳定性门槛达成，不扩大到完整 External MVP。
