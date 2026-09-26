# v0.1 开发路线图与任务拆分

版本：Design Draft 1.0；阶段目标保留，执行状态更新于 2026-09-27 / WG-INT-10。
**仍处于 S1，未取得可用 VPN 的真实验收证据。** WG-INT-10 已把显式 run 授权、正式 Provider、真实网络观察 API、PolicyCore/ManagedSettings、设置成功门控和 09 packetFlow 后端接成运行代码，并提供独立正式工程构建入口。新增源码没有本轮 Mac 原生编译、握手、双出口或系统恢复证据，不能把代码接线写成 WG 全部完成。OpenVPN 和应用内 External 未接通。

总跟踪：[Issue #1](https://github.com/xiaodou997/VPN-Splitter/issues/1)。当前事实见 [验收状态](acceptance-status.md)、[10 证据](evidence/wg-int-10-provider-runtime.md)与 [10 ADR](adr/ADR-WG-INT-10-provider-runtime.md)。历史 [09](evidence/wg-int-09-native-packet-flow.md)、[08D](evidence/wg-int-08d-material-admission.md)、[08C](evidence/wg-int-08c-authenticated-configuration-delivery.md) 保留。

## 当前执行队列：先验收一条真实连接

| 已有工作 | 当前事实与边界 |
| --- | --- |
| LocalDev LD-01～03B | 配置/规则/导入/参数/模拟已有实现；开窗和遮挡修正 USER_REPORTED；真实 Keychain 完整链仍待验。本批不改其数据和权限 |
| WG-INT-01～07 | 引擎构建、约束、设置、生命周期基础保留；10 复用原 ProviderSessionController，而非另写一套完整状态机 |
| WG-INT-08A～D | 正式选择/保存/App Keychain/认证 XPC/材料完整语义校验已有代码；真实身份和系统偏好行为未验收 |
| WG-INT-09 | 原生对象转换与公共 packetFlow/C/Go 候选；10 将其接入真实 Provider 的独立集成构建 |
| WG-INT-10 | 显式运行授权、主物理网络快照/MTU/epoch、settings→engine→stop→clear 已有实现和有限离线回归；不是原生功能验收 |
| 原生构建 48eee07 | 用户报告编译/链接/桥接符号通过，保留且只覆盖该旧基线 |

**首个可用目标：单份 WireGuard 配置、首轮单 Peer、IPv4 数字端点、Include、无 DNS 字段；指定网段走 VPN，其余直连，可以取消/断开，并有独立系统恢复证据。** 不自动删除 DNS/IPv6/额外 Peer，不扩大 AllowedIPs；首轮限制不取消 S2/v0.1 DNS 目标。

| 当前优先任务 | 必须交付的实际结果 |
| --- | --- |
| 正式集成原生构建 | provider-build 编译真实 App/System Extension 与固定 Go archive；修正 Apple SDK/链接实际错误，不拿旧 unsigned 或探针结果替代 |
| 身份/保存/授权验收 | 正确 App Group/profile，Keychain/偏好读写、错签名/错用户/过期/重放拒绝；旧 check 始终不联网，新 run 经独立确认 |
| 首轮流量验收 | 设置及时成功后引擎运行、真实握手、指定 VPN 与直连双路径；connected 或 engine ready 不等于目标可达 |
| 系统撤销观察 | 实现独立路由/DNS 前后观察并覆盖失败、取消、超时、崩溃。已有 nil-settings ACK 不升级为系统已恢复 |
| 运行质量 | 扩大网络争用与多接口观察；睡醒/切网重连、真实统计、诊断、性能和长期运行。当前切网/睡眠停止，不自动重连 |
| 持久化维护 | 旧凭据/孤儿记录/失败清理持久化恢复；不扫库盲删、不移除锁，不宣称系统偏好原子 CAS |

main 非强制统一交付，无补丁包。`dev.sh provider-runtime-test` 是本批离线入口；`provider-build [--fetch] [--sign]` 生成并编译独立正式工程，默认 unsigned 且不安装/激活。只有显式 --fetch 下载固定公开依赖，--sign 也不授权真实网络测试。`run`/`test` 仍 LocalDev，原 `engine`/`engine-flow`/旧 S1 保留。

通过闭环后补齐 WireGuard 运行质量和 S2 DNS，再进入 OpenVPN/External。S0 未完成收尾独立保留，已完成单目标实验和旧构建不无理由重做。

## 1. 执行规则

顺序为 S0 -> S1 -> S2 -> S3 -> S4 -> S5，不同时开发三个完整后端。可按 ADR-007 并行做不依赖后端的 LocalDev 界面、配置管理、规则编辑、纯逻辑测试、文档和合成配置，不绕过阶段的事实门槛。

每个实现 PR 只覆盖一个可验证问题，引用任务编号、需求编号和测试 ID，说明改变的能力、风险、回滚与未执行测试。提交源码不等于完成任务；阶段关闭需要证据。

阻碍是外部条件时标记 BLOCKED，列明缺少的环境/凭据/能力。不得为了继续画界面而把关键验证标记完成，也不得要求将秘密上传公共仓库。

## 2. S0：真实场景与 External 小验证

目标：先确认项目对原 VM+VPN+gost 工作流有实际价值；不构建完整 External 产品。

| 任务 | 交付 | 依赖/验收 |
| --- | --- | --- |
| S0-01 | 场景基线：原应用、访问目标、期望出口、原组合承担的功能 | 使用 evidence 模板；敏感数据本地保存 |
| S0-02 | VPN 前后接口/路由/DNS 脱敏差异，物理和隧道候选 | T-E01、T-E04；不知道就明确 unknown |
| S0-03 | 经授权对一个受控目标做 DIRECT 例外并撤销 | T-E02、T-E03、T-E11；双出口证据 |
| S0-04 | 记录 Managed 配置能否等价替代原登录/访问、External 价值结论 | T-U08 场景初判；不等同最终替代验收 |

进入条件：有测试 Mac、原客户端和可控测试目标。结构分析可用脱敏配置；连通性必须用本机有效配置。

退出条件：S0 报告给出可复现的兼容结论和安全撤销结果。若没有支持样本或官方客户端不可替代而 External 不可用，暂停完整三模式 v0.1 承诺；可以继续 Managed 原型，但需明确范围并记录 ADR。

## 3. S1：签名最小工程、PolicyCore 与 WireGuard

| 任务 | 交付 | 依赖/验收 |
| --- | --- | --- |
| S1-01 | 最小 App + Packet Tunnel System Extension；固定工具链清单 | S0 场景；T-U01、T-U06 初验 |
| S1-02 | **IN PROGRESS**：已有 IPv4 类型、first-match、CIDR、能力拒绝、基础设施/peer 检查；[T-P10 实测](evidence/s1-tp10-tests.md) | T-P01–P03、P07–P10 纯逻辑覆盖；Mac 原生、P08 运行态与执行适配待验 |
| S1-03 | WireGuard 导入、Keychain 边界、固定依赖 revision 与许可记录 | WG-01/03/06、T-W06、T-U04 |
| S1-04 | WireGuardKit 设置适配点及最小补丁；协议/系统路由分离 | T-W01–W05、W10 |
| S1-05 | Include/Bypass、基础设施例外、enforceRoutes 比较与实际出口证据 | T-W02、W03、W08 |
| S1-06 | ADR-002：target、entitlement、网络设置适配点、可复制构建步骤 | 上述测试；无开发绕过的发行样例 |

退出条件：在正常安全设置的 arm64 Mac 启动扩展并完成受控 WireGuard 双出口测试；协议 AllowedIPs 不被分流规则偷偷改写；失败和停止路径基本可用。无签名编译不能满足 S1。

本阶段不要求完整规则编辑器、自动更新、多 peer 全覆盖或 OpenVPN UI。先做可验证的最小交互。

## 4. S2：DNS 与受限域名

| 任务 | 交付 | 依赖/验收 |
| --- | --- | --- |
| S2-01 | DNSPlan、Include/Bypass resolver 行为记录 | S1；T-D01–D03、D10 |
| S2-02 | 精确 DOMAIN 的可验证名称映射、有效期、来源和资源上限 | T-D04、D05、D11、D12 |
| S2-03 | 共享地址冲突、CIDR 组合后缀、IPv6/加密 DNS/缓存限制 UI | T-P04–P06、P11、T-D06–D09 |
| S2-04 | ADR-003：名称解析接口、TTL 更新办法、能力等级、关闭条件 | T-D01–D12；编译性能基线 |

退出条件：声明范围内的 DNS-derived 行为与失效处理正确；能在 UI 中展示而不是隐藏无法覆盖的情况。任意公网后缀的自动子域发现和严格域名隔离不是本阶段任务。

如果系统解析接口无法支持可靠自动映射，不把手动快照冒充完整 DOMAIN；该目标标 BLOCKED，调整范围须新 ADR，不能仅关掉功能后声称完整 v0.1 已满足。

## 5. S3：OpenVPN Managed

| 任务 | 交付 | 依赖/验收 |
| --- | --- | --- |
| S3-01 | OpenVPN 3 固定 revision、MPL 路径许可审查、C++ 构建清单 | 许可通过后才能作为发行依赖 |
| S3-02 | ObjC++/C 桥与 NE 包通道最小集成 | T-O01、O08；无第二个独立 utun |
| S3-03 | 导入白名单、认证状态、服务器配置提案与本地审核 | T-O02–O07 |
| S3-04 | 同一 PolicyPlan 的 Include/Bypass/DNS 回归和兼容矩阵 | T-O01–O08、复用 T-D 相关测试 |
| S3-05 | ADR-004：核心选择、桥接/线程/包通道、支持选项和依赖补丁 | 真实测试配置与证据，秘密不入库 |

退出条件：常见目标配置真实认证与访问成功；默认路由可受本地策略控制而不破坏必要 DNS/地址；不支持认证/指令给出可操作错误。CLI 能连接不能代替扩展集成测试。

## 6. S4：External 工程化与统一产品

| 任务 | 交付 | 依赖/验收 |
| --- | --- | --- |
| S4-01 | NetworkDiscovery、epoch 和兼容能力状态 | S0 证据；T-E01、E04、E05、E09 |
| S4-02 | SMAppService Helper、身份验证、结构化计划与有限租约 | T-E06、E08、E10、T-U01 |
| S4-03 | 事务日志、崩溃/争用恢复、动态域名例外回归 | T-E02、E03、E06–E12 |
| S4-04 | 三模式共享配置/规则/DNS/诊断界面；更新/退出一致性 | T-U02–U05、U09 |
| S4-05 | ADR-005：可支持 External 样本、系统版本、路由 API、风险和熔断参数 | 全部 T-E 及资源测量 |

退出条件：至少一个真实路由型 VPN 样本完成 Bypass 与稳定性测试；只撤销安全自有修改；没有持续路由争用；默认不改第三方 DNS。仍以受限实验性发布，不将测试结果推广到所有 VPN。

## 7. S5：发行与最终验收

| 任务 | 交付 | 依赖/验收 |
| --- | --- | --- |
| S5-01 | 完整需求/测试追踪报告，未解决问题分级 | 所有强制测试有证据 |
| S5-02 | 连接/重连/睡醒/切网循环和故障测试，性能对照 | 测试计划第 10 节 |
| S5-03 | Developer ID、公证、DMG、许可与版本清单 | T-U06；正常安全设置 |
| S5-04 | 升级/退出/卸载/重新安装流程与说明 | T-U07、T-E11 |
| S5-05 | 使用者原 VM+VPN+gost 场景最终替代验收 | T-U08，所有实际业务目标 |
| S5-06 | v0.1 发布说明：支持环境、能力、IPv6/断线/域名限制 | 所有阻断项清零或经 ADR 调整范围 |

未完成 S5 前可以发布明确标注范围的 preview，不能用预览包宣称三路方案已全部生产可用。

## 8. 开发前外部资源清单

测试 Mac、开发/发行签名账号与相应权限、有效 WireGuard/OpenVPN 配置、原 VPN 客户端、受控访问目标、可控制 DNS 记录的环境、必要时有线网络。它们是执行条件，不是已具备事实。

脱敏材料用于理解结构，不足以握手；有效密钥、证书私钥和密码留在测试机。缺少材料时先做相应纯逻辑/模拟任务，并在阶段报告写 BLOCKED，不在公开 Issue 催交秘密。

## 9. Definition of Done

一个任务完成需代码/文档一致、测试可重复、错误/权限/恢复路径覆盖、无秘密、依赖许可记录齐全、诊断可解释、未测项明确。影响系统网络的变更额外提供前后状态及撤销证据。

新依赖、数据面机制、默认出口、DNS 隐私行为或保证等级变化必须先更新 ADR。当前可执行项：按上方队列进行正式集成原生构建、真实运行验收及独立系统撤销观察；不以 LocalDev 完善或组件数量代替实际双出口。签名在首次真实隧道前恢复，但不是唯一剩余工作。S0 收尾独立保留，不要求重做已完成单目标实验。不 Fork 整个参考应用，不以本批代码集成宣告 S1–S5 通过。

## main 工作流与 S1-01 交付

PR #3 与 #2 已保留历史合并；本地统一使用 main。见 [构建操作](s1-01-build.md)、[ADR-002 草案](adr/ADR-002-signing-spike.md) 与 [本轮证据](evidence/s1-01-scaffold.md)。删除工作分支不删除证据，也不把 NOT RUN 升级为 PASS。不要重跑已完成的 S0 手工实验来替代 S1 构建；需要签名账号的部分在用户本机进行。
