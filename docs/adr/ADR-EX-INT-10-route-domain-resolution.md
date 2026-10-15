# ADR-EX-INT-10：Route Helper 域名规则的解析式支持

日期：2026-10-15。状态：Accepted（实现离线完成，真机未验证）。关联 ADR-EX-INT-03B（认证 Helper）、ADR-EX-INT-05（sustained）、ADR-EX-FLOW-02/03（Flow 层与能力分工）。

## 背景

Flow 层（按 App/域名）的互联网 DIRECT 在 StrongVPN kill switch 下被"接口绑定无路由"拦截（ex-flow-03 证据），而内核路由层（route-trial）已真机证明可出公网。用户的核心需求"指定域名绕过 VPN 直连"因此只能落在路由层。但路由只按 IP 工作，EX-INT-03C 现状是 Route Helper 遇 flow-only 规则（DOMAIN/APPLICATION）整体阻断。

## 决定

1. **DOMAIN/DOMAIN-SUFFIX 规则在路由层经解析支持。** Helper（root）在 prepare 时把域名经**系统 resolver**（即当前 VPN 的 DNS——VPN 内解析符合隐私期望）解析为 IPv4 集合，展开为 /32 直连提案。每域名最多 8 个 A 记录、单次 prepare 总上限 32 条 /32；超上限截断并在提案中如实标注，不静默。
2. **解析失败拒绝该规则。** 零 A 记录、解析出错、或结果落在 198.18.0.0/15 等已知 fake-ip/保留段（VPN fake-ip 模式下解析结果不可路由）→ prepare 拒绝并指明规则，不部分应用。
3. **DOMAIN-KEYWORD 与 APPLICATION 仍不支持路由层**，遇之整体拒绝（语义同现状）。这两类无法映射为确定 IP 集合；APPLICATION 的按进程分流只有 Flow 层可做。
4. **sustained 会话定期重解析。** 活动会话每 60 秒对域名规则重解析，对路由集合做 diff：新增 /32 逐个 ADD、消失的逐个 DELETE（仍只动自己拥有的回执）。有限试用（60 秒）不刷新。重解析失败保持现有集合，不撤销。
5. **尽力语义，非 fail-closed。** 域名 IP 漂移期间，未入集合的新 IP 连接仍走 VPN——这是安全的回落（规则意图是直连，回落 VPN 不泄漏）。与 Flow 层 fail-closed 不同：路由层从未接管流量，只是加宽直连集合。
6. **GUI 提案如实展示来源。** 域名展开的 /32 提案标注来源域名，用户确认窗口看到的就是将被直连的 IP 集合。

## 后果

- "指定域名绕过第三方 VPN"在保持 VPN kill switch 开启的前提下首次可用（prepare 解析 → /32 路由 → sustained 刷新）。
- 域名分流质量受 DNS 轮换影响：CDN 大池域名可能只分流部分连接；这是尽力语义的一部分，写入文档。
- ExternalLeasePlan 保持纯逻辑：域名解析在 Helper 进程内完成，解析结果作为输入传入；不引入第三方 DNS 依赖。
- 真机验证（域名规则 → 出口对照 → 撤销零残留）通过前，不宣称域名路由分流可用。

## 实现补充说明（2026-10-15，离线实现/真机未验证）

- **DOMAIN-SUFFIX 按 apex-only 解析**：路由层无法枚举子域名，suffix 规则只解析其 apex 域名本身，提案来源标注为"example.com 后缀 apex"。子域名漂移不枚举、不猜测。
- **规则线格式**：GUI `routeExecutionRulesText()` 发出 `DOMAIN,<name>` / `DOMAIN-SUFFIX,<name>` 行；wire（schema=2 不变）严格字符集放行这两类行，DOMAIN-KEYWORD/APPLICATION/未知前缀在 wire 与 Helper 解析两处都整体拒绝（invalidRules）。
- **上限叠加**：解析预算每域名 8 条、单次 32 条，再受既有执行预算（每次会话 proposals ≤ 8、前缀 /24–/32）约束；展开预算 = 8 − 静态行数，预算为 0 且存在域名规则时拒绝（limitExceeded），预算不足时确定性截断并在 prepare 诊断中以计数标注 `truncated=yes`，不静默。
- **失败语义**：解析出错、过滤后零可用 A 记录 → `domainResolutionFailed` 整体拒绝（GUI 预检拒绝文案可见该 code）；保留段口径复用 ExternalPlanner 的 reserved（0/8、127/8、169.254/16、224/3）并加 fake-ip 198.18.0.0/15（ExternalPlanner.isUnroutableForDirect）。
- **编译器归并**：PolicyCore 编译器会把相邻 /32 归并为 /31 等更宽 CIDR（路由语义等价）。来源标注按包含关系归因（一个归并提案覆盖多个域名时显示"首个域名 等 N 个域名"）；**混合归并路由**（同一条归并 CIDR 同时覆盖静态规则与域名展开的地址）按静态处理——刷新永不删除/重建它，避免误伤静态规则。
- **sustained 刷新**：lease 的 poll()（actor 同步、500ms tick 驱动）只做"到期判定 + 应用已完成结果"；getaddrinfo 在 `Task.detached` 后台执行，结果经锁保护的一次性盒子交还，tick/poll 不被 DNS 阻塞。每 60 秒一次（注入时钟语义，纯逻辑 `ExternalDomainRefresh` 单测覆盖计时/diff/失败保持）；重解析失败保留现有集合，下个周期重试；有限试用（controlledLifetime=false）不刷新。
- **刷新写路径**：diff 在解析 /32 空间计算；删除映射到实际拥有的（可能归并过的）destination——仅当其全部地址都不再解析时删除。新增/删除走与 start/stop 相同的 drainEvents、快照比对、ACK/readback、回执校验；任何失败按 networkChanged 同等语义终止会话（fail-closed）。路由集合变化前以 journal `amend`（临时文件 + fsync + renameat + 目录 fsync）写前更新恢复 marker，marker 始终等于当前持有集合；崩溃恢复审计语义不变。
- **wire 兼容**：`ExternalControlProposal` 新增可选 `sourceDomain`（合成 Codable 的 decodeIfPresent 语义，旧对端缺省为 nil），reply 校验上限 280 字节；schema 保持 2，GUI/Helper 同版本交付。解析出的域名不进入日志/诊断，只在确认窗口的提案行内向用户展示。
