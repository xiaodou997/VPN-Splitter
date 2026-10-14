# ADR-EX-INT-04：邻居引用标志与网络 epoch

日期：2026-09-30。状态：Accepted for implementation；原生复验待完成。关联 EX-INT-03B、T-E08、T-E09。补充 EX-INT-02 的快照语义，不改变写入/撤销所有权要求。

## 证据

Helper 多次将正常租约提前结束为 networkChanged。原生脱敏诊断最终证明：完整路由集合仅小写 i 不同，目的、网关、接口、其余标志及 Expire 状态相同；形态为 /32 UHLWI↔UHLWIi，涉及物理及其他接口。独立路径查询确认清理已执行，但该行为阻碍稳定租约。

本机 SDK 与 [Apple XNU route.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/route.h) 将 RTF_IFREF 定义为路由持有接口引用；[netstat 映射](https://github.com/apple-oss-distributions/network_cmds/blob/main/netstat.tproj/route.c) 输出小写 i。大写 I 是 RTF_IFSCOPE，二者不可混同。这里没有复制上游代码。

## 决策与边界

只为网络 epoch 比较提供一个独立规范化视图：当且仅当前缀为 /32、原始 flags 精确为 UHLWI 或 UHLWIi（UP/HOST/LLINFO/WASCLONED/IFSCOPE），将小写 i 从比较键移除。保留所有行及目的、网关（包括 MAC/未完成状态）、接口、其余标志和 isExpired。规范化导致重复键折叠时退回原始集合，不忽略歧义。

原始 ExternalRoute 和 parser 输出不变，规划器、冲突检查、原生 ACK/事件/receipt 所有权及 DELETE 前逐项原始读回不使用这个视图。G/S/PROTO2 的自有路由不符合例外，不能凭 i 容忍获得删除权。不忽略大写 I、网关/MAC、接口、前缀、路由增删、unknown flags、Expire、DNS 或物理路径变化，也不增加重试。

同一比较视图用于采集器两次路由读数的一致性、事务 baseline 比较和停止后快照比较；接口与系统配置仍按原要求相等。该变化是区分引用元数据与网络变化，不构成任意后台路由变化容忍。其他动态邻居变化仍可使会话拒绝或停止。

## 验证

须覆盖双向 i 切换、非 /32、非 LLINFO、缺失 scope、owned/G/S 路由、MAC/网关、接口、Expire、增删与重复键。原生 ACK/DELETE 及完整到期测试仍需重跑。未通过真机之前不宣布修复稳定性门槛，不扩大到完整 External MVP。
