# ADR-EX-RULE-02：GEOIP 归属地规则（一键归属分流）

日期：2026-10-18。状态：Proposed（用户已确认全量范围；实现、编译与真机验收均未执行，本文件不宣称任何可用能力）。关联：[ADR-EX-RULE-01](ADR-EX-RULE-01-user-friendly-rules.md)（规则类型与双执行层）、[ADR-EX-INT-10](ADR-EX-INT-10-route-domain-resolution.md)（预检展开与 sustained diff 先例）、ADR-EX-FLOW-02/03（Flow relay 数据面）、[security-distribution](../security-distribution.md) §9（第三方数据登记）。

## 背景

用户要求类似 mihomo `GEOIP,CN,DIRECT` 的一键归属分流：一行规则让某归属地的 IPv4 目标走 DIRECT（或 VPN），无需手工维护 CIDR 列表。

mihomo 的实现本质是**用户态数据面逐连接查内嵌归属库**：每个连接的目的 IP 在运行时查一次"CIDR → 国家码"表，命中即采用该规则动作。它能这样做的先决条件是 TUN 用户态接管全部流量，操作系统路由表永远不需要装下那几千条 CIDR。

本项目的执行层与 mihomo 不同构，必须先分层再决定 GEOIP 落在哪：

| 执行层 | 结构 | GEOIP 结论 |
| --- | --- | --- |
| Route Bypass（第三方 VPN 活跃时的 PF_ROUTE 例外） | 路由表例外，会话预算 8 条、/24–/32、地址总数 ≤2048（ExternalLease.swift:46-49；C 驱动 ER_LIMIT 8、journal 与 wire 协议同按 8 条设计） | **明确不做**。8 条是有意的产品会话预算，非内核限制；PF_ROUTE 串行写入随条数线性增长；ownership/journal 全链路按 8 条带测试硬校验。扩容是协议级重做，不属于本 ADR |
| 自有 WireGuard Include 路径 | 内核 cryptokey 路由按 AllowedIPs 前缀分流，无用户态逐流点 | **编译期展开**：GEOIP 在策略编译时展开为归属 CIDR 集合，走既有区间算法进 AllowedIPs/peer 选择。这是"一键输入、展开在应用时"而非 mihomo 的运行时查表 |
| Flow Bypass（ExternalFlow relay） | 用户态逐流 TCP/UDP 中继，看得见每条流的目的 IP | **运行时查表**，架构里唯一与 mihomo 同构的位置；门控于 Flow 真机 MVP |

现状合同约束：`CompilationLimits` 1000 规则 / 2048 路由（Policy.swift:95-105，注释明示提升须连同合同测试一起修改）；`ConstraintLimits.prefixCeiling` 2048（Constraints.swift:50-67）；External 批量导入 64 行/16 KiB（ExternalProfiles.swift）。GEOIP 展开（中国段约万级前缀）超出当前天花板约一个数量级，必须改合同而不是塞 IP-CIDR。

## 决策

### 1. 规则语法与数据模型

- 用户文本：`GEOIP,<ISO 3166-1 alpha-2 大写>,<ACTION>`，动作限 DIRECT / VPN。延续 ADR-EX-RULE-01 精神：文本接近 mihomo 逐行形式，内部保存类型化结构，不承诺 mihomo 配置/订阅兼容。
- `RuleMatch` 增加 `.geoip(GeoIPCountryCode)`。GEOIP 规则在存储、批量编辑和工作区中始终是**一行**，展开结果绝不物化为成千条 IP-CIDR 规则。
- 国家码非法、动作非法：输入期拒绝。表内不存在该国家：规则可保存，覆盖为空集，预览明确显示"0 条前缀"，不误报为可执行。

### 2. 执行面 A：编译期展开（主线）

- PolicyCore 保持纯逻辑无 I/O：归属表作为**调用方注入输入**（`GeoIPTable`，按国家码索引的排序归并 CIDR 集合），编译器不自己读文件。
- GEOIP 规则是有序规则表中的一条，严格 first-match：其覆盖 = 归属集合 ∩ 前序规则未遮蔽空间；遮蔽/有效诊断保留规则级归因（命中报告"GEOIP CN（表 vX.Y.Z）"，而非展开后的匿名前缀）。
- 展开走既有区间合并算法，产物参与 Include/Bypass 编译与 WG peer assignment；不引入新的执行机制。
- 仅 IPv4。不做 IPv6、不做 GEOSITE（域名集合是另一条数据线与语义）、REJECT 动作仍整体拒绝。

### 3. 执行面 B：Flow 运行时查表（随 Flow 线，门控）

- Flow provider 加载同一序列化格式的内存归属表，对每条流的目的 IP 查表；分类语义与执行面 A 同版本表完全一致。
- 查表不得阻塞 relay 数据面（预取/异步，失败按"不命中"fail-closed）；上报延续 Flow 线纯计数边界。
- **门控**：Flow Bypass 真机 MVP（含互联网 DIRECT 前提，当前受第三方 VPN kill switch 限制）通过前，任何仅能走 Flow 执行的方案含 GEOIP 即整体拒绝，与 DOMAIN-KEYWORD/APPLICATION 同规。禁止部分执行。

### 4. Route Bypass 明确拒绝

Route Helper 遇到 GEOIP 规则必须**整体拒绝**并给出诊断，禁止静默跳过或只执行其余规则。理由：8 条会话预算是有意设计；PF_ROUTE 串行安装千级前缀不可行；本层保持小例外定位不变。

### 5. 匹配语义

- 目的 IP ∈ 归属集合即命中；未命中 fall through 到下一条规则，最终由默认动作决定。
- 私有/保留/未映射地址不命中（表构建期排除或查表期过滤，实现时定并测试）。
- 任何超限、表缺失、版本不匹配：明确拒绝，不静默截断。

### 6. 数据更新

- 归属表随 App 版本发布固化，经签名/公证链分发；**不做运行时自动拉取**（供应链边界，见安全边界）。
- UI 显示表版本与数据日期；不宣称实时归属准确性，数据陈旧以界面标注声明。

## 数据源与许可（流程义务）

进生产构建前必须完成 security-distribution §9 登记：上游、commit/tag、许可证、复制方式、补丁、校验、传递依赖、维护与安全更新办法、签名影响、审核结论。**登记完成前数据文件不得进入生产构建。**

候选与已知许可事实（最终以登记流程结论为准）：

1. MaxMind GeoLite2：CC BY-SA 4.0（署名 + 相同方式共享），对随闭源 Developer ID 包再分发不友好，默认不选。
2. Loyalsoldier/v2ray-rules-dat 的 geoip.dat：仓库代码 MIT；数据为 MaxMind + ipip.net + 社区修正混合来源，须逐项核查数据文件本身的再许可。
3. APNIC/BGP 派生聚合表：归属准确性较低，但来源许可简单，可作fallback。

转换管线：构建期由开发工具（Python 仅作开发工具，非产品运行依赖）把数据转为确定性排序的 CIDR 表，固定 revision + SHA-256 + reference.json，照 third-party/wireguard-* 先例登记。同一 revision 输入必须产出字节级相同的表，保证编译可复现。

## PolicyCore 合同变更

- 新增 `GeoIPCountryCode` 与注入式 `GeoIPTable`；`RuleMatch.geoip` 参与编译与诊断。
- `CompilationLimits.ruleCeiling` 不变（GEOIP 仍是一条规则）；**`routeCeiling` 由 2048 提升**（目标量级 65 536，覆盖 CN 展开加聚合碎片），`ConstraintLimits.prefixCeiling` / `explanationCeiling` 同步提升。提升必须连同该合同既有测试一起修改（Constraints.swift:48-49 明示义务），并新增：万级表 × 规则组合的属性测试、first-match 等价测试、确定性（同表同策略同产物）测试、遮蔽诊断归因测试。
- 规模验证义务：实现时实测典型表（CN 约万级前缀）的编译产物规模与耗时；若聚合后 AllowedIPs 超出 WG 真机可下发规模，回修本 ADR，不得静默截断。

## 应用层与 UI

- 单条与批量输入接受 GEOIP 行；预览显示"展开 N 条前缀（表 vX.Y.Z / 数据日期）"。
- 存储格式：external-profiles 扩展（v2 内新增 kind 或升 v3）在 EX-RULE-02C 实现时定，硬性要求：旧版本 App 对未知 kind 保持拒绝，不降级解码，不静默丢弃。
- LocalDev 草稿与批量编辑同步支持；一行存储不触碰 2 MiB 工作区与 1000 条规则上限。

## 验收

### 执行面 A（自有 WG 路径，EX-RULE-02D）

- 默认 VPN + `GEOIP,CN,DIRECT`：国内目标直连、境外目标进隧道，真机双出口证据（docs/evidence/ 新档）。
- 万级 AllowedIPs 下发、回读、断线重连后的归属语义保持，真机实测。
- 表缺失/版本不匹配/国家码未知：整体拒绝并给诊断，离线测试覆盖。

### 执行面 B（EX-RULE-02E，门控）

- 前置：Flow Bypass 真机 MVP 通过；否则本条保持未执行，不计入任何完成度。
- 通过后：逐流查表分类与执行面 A 同版本表语义一致的真机样本；relay 吞吐/时延开销实测并记录。

## 安全边界

- 归属判定全部在本机完成，无 per-IP、per-国家命中数据上报。
- 数据文件哈希构建期校验，随签名链分发；不运行时远程更新。
- 未知/保留地址不命中，不默认放行也不默认进隧道，交给 first-match 后续规则。
- 未通过真机前，GEOIP 在 Flow 面与 Route 面均不可执行；执行面 A 未真机验收前，不宣称"中国 IP 直连"可用。

## 任务拆分

| 编号 | 内容 | 性质 |
| --- | --- | --- |
| EX-RULE-02A | PolicyCore 类型、编译器展开、合同提升、离线测试 | 纯逻辑，可与 External 主线并行 |
| EX-RULE-02B | 数据源选定、§9 登记、转换工具、随包表 | 离线；登记完成前不进生产构建 |
| EX-RULE-02C | 输入解析、预览、存储扩展、LocalDev/External UI | 离线 GUI |
| EX-RULE-02D | 执行面 A 真机验收 | 排期在 External MVP 之后或并行窗口 |
| EX-RULE-02E | 执行面 B Flow 运行时查表 | 门控：Flow MVP 真机通过 |

每个提交引用任务编号与测试，列出权限影响、失败/恢复路径、已执行与未执行测试。

## 未决项

- 数据源最终选定（EX-RULE-02B 完成 §9 登记后确定）。
- 存储格式 v2 扩展 vs v3 的迁移细节（EX-RULE-02C 定，须旧版本拒绝解码）。
- routeCeiling 提升后 WG 真机下发规模上限（EX-RULE-02D 实测；不达标回修本 ADR）。
