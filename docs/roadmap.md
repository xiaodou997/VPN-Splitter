# v0.1 开发路线图与任务拆分

更新：2026-09-29 / EX-FLOW-01F Developer ID 公证、systemextension 激活、第三方 VPN 共存和 provider round-trip 真机验证。按用户重新确认的业务优先级，**External 第三方 VPN 分流成为当前主线，OpenVPN 降为后续 Backlog，WireGuard 保留已有基本链路成果、暂不抢 External 主线**。排队调整见 [ADR-EX-INT-01](adr/ADR-EX-INT-01-external-first.md)，不修改 S0–S5 验收标准或 v0.1 能力范围。

## 当前交付与下一步

| 项目 | 当前能力与边界 |
| --- | --- |
| EX-INT-01 / 02 只读路径 | 已有用户报告的执行器原生构建、inspect 和原生 GET probe 通过；界面中的检测仍只读，不等于真实双出口验收 |
| EX-INT-02 前台候选 | 旧 ADD 回包超时及残留已由用户人工恢复。FIX-08 首次复验在写入前因 `networkChanged` 拒绝；第二次单目标实验得到 ADD ACK/readback，随后 `observationFailed` 触发保守停止，DELETE 阶段无内核错误、零剩余回执、快照不变，独立查询目标回 `utun8`、audit 用户报告零残留。正常停止/到期和真实双出口仍未验收；FIX-09/10 增加脱敏诊断，不放宽拒绝条件 |
| EX-INT-03A/03B | 规则方案管理与认证 Helper/应用内有限会话已接线；03A 用户反馈通过，03B 仍待 Mac 原生身份、系统批准和自动撤销验收 |
| EX-INT-03C | Rule V2：方案可保存 IP-CIDR、DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、APPLICATION；旧 v1 迁移为 IP-CIDR。当前 Route Helper 遇到 flow-only 规则整体阻断，不静默跳过 |
| EX-INT-03D | Helper 协议新增恢复审计/清除动作；GUI 可只读核查候选数，仅在一次零残留审计后开放二次新鲜核查并清除本工具 marker。永不从 marker 重建删除权，也无 GUI 强删路由 |
| EX-FLOW-01A–01F | first-match 核心 + TCP pass-through provider + App/.systemextension + 显式控制器 + 脱敏报告桥。01F 已在本机完成 Developer ID 签名/公证、扩展激活、与 StrongVPN 共存、Provider message=pass 和安全停止/移除。累计 467 条 TCP flow 的 App ID 467、hostname 177；主程序 Flow 页读取为 USER_REPORTED PASS。仍未实现 DIRECT 数据转发，hostname 缺失场景待受控分析 |
| External UI | 主窗口为概览/规则/分流会话/恢复/Flow 实验侧边栏；Helper 注册放到 Settings；APPLICATION 规则新增本机 App 模糊搜索/选择，保存显示名 + Signing ID，不保存路径 |
| External 下一主线 | 继续 Mac 集中验收新导航/APP 选择器、03D Helper 与 Route Bypass FIX-08 自动撤销；Flow 侧先用受控 App/域名样本分析 hostname 缺失和降级规则，再设计 FLOW-02 TCP DIRECT。FLOW-01F 的 pass-through 结果不等于真实直连 |
| OpenVPN Backlog | 暂停实现；不占当前 External 主线资源。保留原 S3 需求和后续兼容路线 |
| WireGuard 暂存 | WG-INT-10 + FIX-01 已有正式集成 unsigned USER_REPORTED PASS；运行/签名/双出口/独立恢复仍未验收，暂不催办签名或重建 |
| LocalDev | LD-03B 及用户原操作/数据保留；本批不修改其 UI、凭据权限或草稿格式 |
| S0 | 原 D 直连、V 保持 VPN 和路径恢复样本保留；不要求为 EX-INT-01 重做手工写路由实验 |

EX-INT-01 使用 `/bin/bash dev.sh external-run` 打开独立、仅本机 ad-hoc 的只读应用；不是原 `run` 的 LocalDev，也不包含 Network Extension/Helper。`external-build` 只编译，`external-test` 运行离线回归；不需要 Go、开发证书、VPN 配置密钥或管理员权限。不自动采集，用户按检测按钮后才读系统状态。

本批的实际实现和测试边界见 [External 开发入口](external-development.md)与 [EX-INT-01 证据](evidence/ex-int-01-discovery-preview.md)。**显示“拟增加”仍为 NOT_APPLIED，尚未形成应用内可用的第三方 VPN 分流。** 不把路由模式、接口名或 PolicyCore 计算通过当作实际出口、加密或厂商兼容证明。

**02 新增的是前台工程执行器，不是预览按钮解锁。** `external-executor-build` 只编译，`external-execution-test` 只做离线测试。真正 apply 需要另行现场授权、管理员前台及 APPLY 确认；最多 8 个 /24–/32 结果、60 秒不续租。异常/不确定时保留恢复标记，不从旧标记重建删除权；BSD compare/delete 竞争与崩溃恢复仍有边界。见 [运行说明](external-execution.md)、[02 ADR](adr/ADR-EX-INT-02-foreground-route-lease.md)及 [02 证据](evidence/ex-int-02-foreground-route-lease.md)。

External 首轮保持原规范：兼容的路由型全局 VPN + 指定 IPv4 DIRECT 例外；不是默认直连 Include，不是按应用/进程，不改原客户端认证/配置/进程/默认路由/DNS。当前预览拒绝多物理路径、多隧道、格式未知、同级或更具体路由冲突及保护范围重叠；已有直连条目也不认领、不删除。后续必须验证原 VPN 保持、指定目标直连及停止后无无法解释的残留。

已有 [WG 原生构建证据](evidence/wg-int-10-user-native-build.md)、[FIX-01](evidence/wg-int-10-fix-01-build-blockers.md)、[WG-INT-10](evidence/wg-int-10-provider-runtime.md)、[S0 样本](evidence/s0-single-target-user-result.md)与 [需求规范](requirements-v0.1.md)保留。下面的阶段退出条件是验收约束，不再作为禁止提前开展 External 开发的排队锁。main 统一非强制交付，不发更新 ZIP，不删除本机缓存、锁或历史证据。

EX-INT-03A 继续使用 `external-run`，不增加另一套运行命令。启动只自动载入本机规则文件；网络检测仍需按钮触发。规则文件只含名称、UUID、版本、类型化 IP/域名/应用选择器及停用状态，不含网关/接口快照、密钥、回执或权限。详见 [03A 存储决策](adr/ADR-EX-INT-03A-profile-workspace.md)与[代码/验证证据](evidence/ex-int-03a-profile-workspace.md)。原 LocalDev、前台执行器与恢复标记保持不变。

EX-INT-03B 为既有页面增加 Helper 操作面板，普通 `external-run` 仍是不能授权的 ad-hoc 预览。`external-helper-test` 仅离线验证，`external-helper-build` 构建独立控制 App 和内嵌 Helper，默认不授权、不安装、不运行。只有显式本机身份签名并经系统批准后才能连接；真实写入另需编译时 route-trial 选择和每次提案确认。见 [Helper 操作](external-helper.md)、[03B 决策](adr/ADR-EX-INT-03B-authenticated-helper.md)和[本轮证据](evidence/ex-int-03b-authenticated-helper.md)。旧恢复标记不会被注册、连接或构建清除。

## 1. 执行规则

原 S0 -> S1 -> S2 -> S3 -> S4 -> S5 的开发排队由 ADR-EX-INT-01 及后续用户优先级调整：先把 External 做到基本可用；WireGuard 保留现有成果、在 External MVP 后补最小真机闭环；OpenVPN 暂列 Backlog。S0–S5 任务编号与退出条件保留，不同时开发三个完整运行后端。可按 ADR-007 并行做不依赖后端的 LocalDev 界面、配置管理、规则编辑、纯逻辑测试、文档和合成配置，不绕过阶段的事实门槛。

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

新依赖、数据面机制、默认出口、DNS 隐私行为或保证等级变化必须先更新 ADR。当前可执行项：先把 External Route/Flow Bypass、恢复和实际场景做到基本可用；WG 原生构建成功证据保留，External MVP 后补最小真机闭环；OpenVPN 暂列 Backlog。不以 LocalDev 完善或组件数量代替实际双出口。签名在首次真实隧道前恢复，但不是唯一剩余工作。S0 收尾独立保留，不要求重做已完成单目标实验。不 Fork 整个参考应用，不以本批构建通过宣告 S1–S5 通过。

## main 工作流与 S1-01 交付

PR #3 与 #2 已保留历史合并；本地统一使用 main。见 [构建操作](s1-01-build.md)、[ADR-002 草案](adr/ADR-002-signing-spike.md) 与 [本轮证据](evidence/s1-01-scaffold.md)。删除工作分支不删除证据，也不把 NOT RUN 升级为 PASS。不要重跑已完成的 S0 手工实验来替代 S1 构建；需要签名账号的部分在用户本机进行。
