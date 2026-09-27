# ADR-EX-INT-01：External 优先与只读识别/预览

日期：2026-09-27。Accepted（开发排队与本批边界）；运行可行性不由本 ADR 宣告通过。

## 调整依据

用户重新强调原始目的为第三方 VPN 分流，已确认 External 为当前主线、OpenVPN 导入/兼容性提前、WireGuard 签名暂缓。替代 ADR-001 D09 及旧路线图的严格开发排队，不替代 D05 的 External 能力限制或 S0–S5 退出条件。保留 WG-INT-10 unsigned USER_REPORTED PASS 与 S0 单目标路径证据，不要求重做已完成实验。

## 本批实现

新增 ExternalCore 本地包、原生只读采集与 SwiftUI 开发入口。独立 ExternalPreview 应用避免为只读诊断要求 WG 系统扩展签名/激活，也不修改 LocalDev 草稿/ACL。仅 ad-hoc、本机开发运行；无 Helper、NE entitlement、开发账号、Go 或第三方协议引擎。不是最终统一产品界面，也不增加正式承诺的平台。

按按钮才执行一次采集：SCDynamicStore 中网络服务 IPv4/DNS 摘要、SCNetworkInterface 类型、getifaddrs IPv4 地址、固定 `/usr/sbin/netstat -rn -f inet` 数字路由表。无 root、无 DNS 查询、无出站探测、无包捕获或用户凭据读取。netstat 子进程输出有大小/时限，错误不回传原始日志；可终止的只有本次只读子进程。

物理候选必须有当前服务 Router、匹配的活动物理接口/地址和连接局域网路由；不把 VPN 当前 default 当物理网关，也不读旧网关重放。多物理服务不自动择一。识别单一 IPv4 隧道候选上的 0/1+128/1 或 default 替换，接口名/点对点标志仅是线索，不验证厂商、认证、加密或端点。scope、clone、blackhole/reject 等标志保留；未知表格整表拒绝，不吞掉错误行。

实际复用 PolicyCore IPv4 类型与 first-match 编译器：默认 VPN，最多 64 条明确 DIRECT 地址/CIDR。输入规范化、重叠合并保留规则遮蔽解释；本机、物理 LAN、已观察的 IPv4 DNS、保留地址重叠整体拒绝。已有同级/更具体、scope 或其他路径路由冲突不得靠先删除来绕过；已有同目标物理直连仅显示“不认领、不删除”。全批无部分计划输出。

## 不是执行权限

`ExternalPreview.canApply` 恒为 false。没有写路由/改 DNS/停止 VPN/安装 Helper 的 API；不输出可以直接执行的 root 命令。未来 EX-INT-02 必须重新观察并加入经认证的有限权限、操作回执、读回、版本、撤销和恢复日志，不能从本快照或相同路由字段推导所有权。

两次路由读取和两次服务/接口比较发现采集期间变化即失败；比较排除使用计数与倒计时，仅保留路由语义。本机制不是系统原子快照，也不是持续网络监测。结果只在内存、最多 30 秒，规则编辑、取消、睡眠/唤醒会清理预览。即使显示期间发生未通知的变化，本结果也绝不可执行；未来执行层必须即时复核。DNS 摘要不覆盖全部 resolver 或加密 DNS，不声称完整 DNS 观测。

没有 VPN 断开前基线时，只用当前服务与链路证据做候选诊断，仍不授权修改，符合 EX-06。任意公网后缀、DOMAIN、External Include、按应用/IPv6 分流、Kill Switch、强制策略绕过均不新增。原客户端继续负责连接；强制流量策略的实际兼容性尚未验证。

## 一手接口依据

- [Apple SCDynamicStoreCopyMultiple](https://developer.apple.com/documentation/systemconfiguration/scdynamicstorecopymultiple(_:_:_:))：只读服务状态。
- [Apple netstat route.c](https://github.com/apple-oss-distributions/network_cmds/blob/main/netstat.tproj/route.c)：flags 与 netname/domask 格式；复核 blob `c3ca50e218d4ed04819debb10985a4f7c51dc5b1`。无 suffix 时是 classful mask，不按省略八位组数猜前缀；非连续 mask/未知格式拒绝。
- [Apple WWDC25 NetworkExtension](https://developer.apple.com/videos/play/wwdc2025/234/)：路由表不代表全部强制流量策略，直接修改与系统策略可能冲突。本批只读不修改；External 后续仍是按样本验证的受限兼容模式。

本批未复制上述第三方源码；依赖仅仓库现有 PolicyCore。执行证据见 [EX-INT-01](../evidence/ex-int-01-discovery-preview.md)。后续顺序为 EX-INT-02 受限执行/撤销，提前 OpenVPN 导入层，WG 暂存；main 非强制提交，回滚用后续 revert，保留用户数据。
