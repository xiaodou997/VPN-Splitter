# S0-03：单目标分流、恢复与 route 返回值异常

记录日期：2026-09-25。证据来源：用户在本机执行后提供的终端摘录、限定接口的 TCP 建连包摘要和六次 curl 输出；不是开发环境自行运行的真机测试。关联任务 S0-03；需求 EX-03/05/07；测试 T-E02、T-E03、T-E11。

仅保留目标代号 D/V、接口代号 P/T 和数值测量。D 是准备直连的公网 HTTPS IPv4 目标，V 是继续走 VPN 的不同 HTTPS IPv4 目标；P 为物理接口，T 为原 VPN 接口。原始地址、域名、机器名、账号、目录、端口和完整抓包不入公开仓库。

## 1. 本次可接受的功能结论

**用户提供的记录支持：D 的新连接从 T 切换到 P，V 继续在 T；随后 D/V 的新连接均回到或保持 T，六次 HTTPS 请求均返回 200、curl 退出码均为 0。** 这是一个现场 IPv4/TCP/443 样本的路径验证，不是只有路由表或网页可达性证据。

| 阶段 | D 的正向路径证据 | V 的正向路径证据 | HTTP / curl |
| --- | --- | --- | --- |
| before | T 上存在 D 的 SYN 及对应 SYN-ACK | T 上存在 V 的 SYN 及对应 SYN-ACK | 均 200 / 0 |
| after | P 上存在 D 的 SYN 及对应 SYN-ACK | T 上存在 V 的 SYN 及对应 SYN-ACK | 均 200 / 0 |
| restored | T 上重新出现 D 的 SYN 及对应 SYN-ACK | T 上再次出现 V 的 SYN 及对应 SYN-ACK | 均 200 / 0 |

此判断依据每条连接的正向观测、用户标注阶段及互相吻合的时间，不以另一接口没有输出为充分证据。跨终端粘贴不是全局有序事务日志；不能从段落排列推断所有命令的完整先后关系。

这里的 DIRECT 指被测连接在该 Mac 的物理接口上向目标发出并收到响应，而不是测得服务端看到的公网 NAT 地址，也不是证明上游网络绝无其他代理。VPN 指被测连接在原 VPN 的 T 接口可见，不识别或保证供应商出口地理位置。

## 2. 耗时观察：每阶段仅一次，不是性能基准

单位：秒；数值按用户 curl 输出原样记录。

| 目标/阶段 | time_connect | time_starttransfer | time_total |
| --- | ---: | ---: | ---: |
| D-before | 0.486596 | 2.016561 | 2.016932 |
| D-after | 0.045602 | 0.208379 | 0.208810 |
| D-restored | 0.834920 | 2.838173 | 2.838732 |
| V-before | 0.294614 | 1.092186 | 1.787657 |
| V-after | 0.502651 | 1.835022 | 3.026502 |
| V-restored | 0.267133 | 1.126427 | 1.789276 |

据此计算，D-after 的总耗时约为 D-before 的 10.35%，降低约 89.65%；TCP 建连耗时降低约 90.63%。只能描述本次请求，不能承诺长期提速、带宽增加或因果分解。V-after 耗时增加的原因未知，不能凭单次样本认定分流损害了 VPN 性能。curl 字段定义参考 [curl 官方手册](https://curl.se/docs/manpage.html)：这些是从开始到相应事件的累计时间，不是可相加的独立阶段。

## 3. 操作异常：不能用退出码代替网络操作结果

第一条 add 的路由事件为 RTM_ADD、errno 0。第二次重复 add 则出现 File exists，事件中 errno 为 17，但终端打印的 route_add_exit 仍为 0。第二次操作必须记为失败/已存在冲突，不能再计作成功，也不能取得新的条目归属。

外部源码复核与本机观察分开：[Apple 发布的 route.c](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.c) 的 newroute() 错误分支打印错误后返回；main() 在 K_ADD/K_DELETE 调用 newroute() 后 exit(0)。复核时该文件 Git blob 为 `bcd320adbcfbc8fd9b155193a5d6120ee9c6c091`。这说明公开实现存在这种控制流；没有确认用户安装的二进制与该源码完全对应。

因此后续实现必须分别记录进程/授权结果、路由操作结果、操作前后状态、请求身份及归属。直接使用 routing socket 时须匹配请求与响应的 type/pid/seq/地址族和对象，检查 rtm_errno，并重新观察目标状态；具体 API 仍由 ADR-005 冻结。不能因为当前对象字段相同就认领；不能用永久重试掩盖 EEXIST。原始输出出现错误即使 rc=0 也不能判成功；没有错误文本同样不是充分条件。

新增回归场景要求（待实现，不计为已运行测试）：rc=0 + File exists；响应错误与进程成功冲突；响应不匹配或超时；预先存在的同目标路由；仅剩 scoped/cloned 条目；授权未通过但另一终端已删除；事件观察中途停止。

## 4. 撤销：恢复已观察，归属与残留审计仍有缺口

一个终端给出 delete 成功文本及 route_remove_exit=0；另一个终端给出 sudo: a password is required、route_remove_exit=1。后者不能记为成功删除，也不等于当前一定仍有残留。用户随后的 D route get 重新选择 VPN 的 /1，D-restored 的新连接也出现在 T，这独立支持实际路径已恢复。

最合理的解释是成功删除发生在另一个终端，但无统一时间记录，不能把这一解释当作精确事件重建。路由监视在删除前已停止，摘录没有覆盖完整撤销区间。不要补造 RTM_DELETE 事件，也不要为了重现错误再次 add/delete。

已提供一次 D 目标行为空的 netstat 输出，但跨终端粘贴中其相对撤销时刻不明确。因此 `owned_route_residue` 仍为待最后一次只读核查，而非宣称全部 scope 无残留。仅需在本机确认 D 的目标 host route 是否还存在；没有则不再删除，有则分类审查而不是自动处理。新的核查只能证明新的观察时刻，不能补齐过去缺失的事件。

V 的 route get 含 WASCLONED/IFSCOPE，且仍指向 T。它与本次针对 D 添加的物理 host route 是不同对象，不应当作本次残留删除。相关标志定义见 [Apple XNU route.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/route.h)，复核文件 Git blob `f0c2c72ba0379906d36714a064b8e9eb6c547acb`。

IPv6 RTM_MISS 是另一些 IPv6 目的的查询未命中记录；这些片段不能归因到本次 D/V 的 IPv4 例外，也不能证明 IPv6/DNS 健康或故障。没有关闭 IPv6、清空路由或删除 VPN 路由的依据。

## 5. 证据分级与开发进度

| 项目 | 本轮状态 |
| --- | --- |
| 现场准备工具 smoke | USER_REPORTED_PASS；精确 build/工具 revision 未独立验证 |
| T-E02 单目标 DIRECT，V 保持 VPN | USER_REPORTED_PASS_SINGLE_IPV4_SAMPLE |
| 撤销后的实际连接路径 | USER_REPORTED_RESTORATION_OBSERVED |
| T-E11 完整安全撤销/不影响原 VPN/DNS | PARTIAL；待最终目标残留确认、版本元数据和恢复证据补齐 |
| T-E03 DNS 保持 | 规程没有 DNS 写命令；没有完整前后 DNS 状态复核，不能标 PASS |
| 完整 S0-03 规程验收 | 不填无保留 PASS_SINGLE_SAMPLE；有重复 add、授权失败和事件覆盖缺口 |
| 完整 S0 / v0.1 | IN PROGRESS / NOT PASSED |

此表是证据注释，不改变 s0-single-target-manual-v1 的字段或验收定义。实际效果与操作完整性分开记录，不能把规程偏差消除或把已观察路径效果降格成未测试。

无需为证明同一个路径机制重跑整套 before/after、重复添加或重新上传原始网络信息。完成一次最终只读目标残留检查即可结束当前手工写入实验；缺少的版本元数据可从现有本地记录补齐。

按既定路线图，可开展 S1-02 的纯 Swift PolicyCore 模型、first-match 参考解释器、CIDR 编译与能力拒绝测试，这是不依赖联网的工作，不意味着跳过 S0 场景/认证等价性或 S1 签名真机门槛。WireGuard 签名最小工程仍按 S1 的条件验证，External Helper 留在 S4，不趁此扩展成多个并行后端。

## 6. 本次仓库操作的边界

本轮仅分析用户反馈、核对公开源码并修改证据与规程；没有执行用户 Mac 的路由/抓包/curl，没有运行新的工具测试、CI、Xcode、Network Extension 或签名构建。此前 27/30/33 项离线测试不是本轮新增或重跑结果。没有上传用户原始文件或改变既有快照。
