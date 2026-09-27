# 当前能力与需求验收状态

更新：2026-09-27，EX-INT-02 前台执行候选。起点 1776b4c；[需求规范](requirements-v0.1.md)及 S0–S5 退出条件不变。代码、离线回归、原生构建与真实功能分开记录。

**当前主线改为 External，WG 签名暂缓，OpenVPN 导入/兼容性检查提前。** [EX-INT-01](evidence/ex-int-01-discovery-preview.md) 已有独立只读应用、真实系统采集调用、路由模式识别和 DIRECT 预览；29 项核心测试 Debug/Release、6 项 Python 检查通过。Mac 原生 UI/采集仍未验收；02 新增前台受限执行代码，但不是 GUI Helper 或真实分流通过。排队变更见 [ADR](adr/ADR-EX-INT-01-external-first.md)。

**WG-INT-10 的正式运行代码已接线，正式集成原生编译/链接已有 USER_REPORTED PASS；WG/S1 真实验收尚未完成。** 独立 provider-build 将 App → 认证 run 交付 → 正式 Provider → 网络观察/策略设置 → packetFlow/Go 引擎 → stop/clear 编入同一正式工程。用户本次报告 unsigned 构建成功，产物未执行、网络设置未应用、扩展未请求激活；签名、真实握手、双出口和系统恢复仍未验收，不是已可交付的稳定 VPN。

| 需求/范围 | 现有实现 | 待验收或待实现 |
| --- | --- | --- |
| WG-01/02/06、UX-02 | 08D 完整导入/语义检查 + 09 原生对象转换接入运行宿主；单 Peer/IPv4 数字端点/无 DNS 字段 | 真实配置和原生转换验收；多 Peer 后续另验，不静默裁剪 |
| WG-03/04、RULE-02 | 实际 PolicyCore/ManagedSettings 编译，包含主物理 LAN/网关/MTU 观察；设置成功后启动；正式集成原生编译/链接 USER_REPORTED PASS | 实际网络/API 行为与双出口；不是全路由表/过滤器冲突识别器 |
| P-05/06、WG-05 | 独立连接确认发送严格 run-v2；旧 v1 交付检查仍无网络；集成 Provider 调用真实 backend | GUI/权限/真实连接/取消/断开待验；本次 unsigned 只编译 |
| RULE-05、REL-02 | 原控制器 + 单会话持有、观察快照绑定 epoch、变化即撤销、无自动重连 | 非协作系统偏好变更无原子 CAS；更广网络变化、重连质量和持久化恢复仍待完善 |
| SEC-01 | 精确 Team/角色 OS XPC gate；App 私有 Keychain；消费后的连接租约随失效撤销 | 原生签名接受/拒绝、锁屏/用户切换/退出验收；不新增共享 Keychain，不改 LocalDev ACL |
| REL-01、UX-04/05 | 实际 NE 状态显示，设置 ACK/engine ready/握手未验证分开；运行失败静态代码 | 握手/统计采集和真实目标探测未实现；不能由 connected 推出全部规则已验证 |
| FAIL-03、DIAG-02 | 取消/超时等待原 apply，关闭 engine 后 clear；迟到清除不升级成功；不确定资源保留 | 独立路由/DNS 恢复观察仍未实现；崩溃/系统晚回调真实行为未验收，nil ACK 不算系统恢复 |
| WG-05 运行质量 | 切网或睡眠主动停止，授权断开空闲会话也撤销 | 睡醒/切网自动重连、长时稳定性、性能和异常退出恢复后续实现与验收 |
| DNS-01～05、S2 | 保留原 DNS/域名目标；首轮含 DNS 字段明确拒绝 | Split DNS、来源/TTL/更新/共享 IP 冲突等未接通 |
| OV-01～08、S3 | 原范围与选型约束保留；导入/兼容性检查提前排队，本批未实现 | .ovpn 导入/认证/push/运行/分流未接通 |
| EX-01～08、S4 | S0 样本保留；EX-INT-01 当前服务/接口/数字路由只读采集、单一全局隧道形态和规则预览代码；未知/多路径/保护范围/路由冲突拒绝 | 02 新增真实 PF_ROUTE 与有限事务/回滚/root 意图日志；原生构建、路由行为/双路径仍未验，签名认证 Helper 与 GUI 写入仍未实现；预览仍只读，不能声称原子删除权或完整恢复 |
| DIST-01/02、S5 | 正式可重复集成构建入口已有代码；本次 unsigned 集成构建用户报告通过 | Developer ID、公证、DMG、依赖可达漏洞/许可及原业务最终替代未验收 |

## 证据与边界

新增 [用户原生集成构建证据](evidence/wg-int-10-user-native-build.md)：provider_compile_link=PASS；artifact_execution=NOT_RUN、network_settings=NOT_APPLIED、extension_activation=NOT_REQUESTED。记录时 main 为 a4dfc32；摘要未提供本机 commit/工作区/源码指纹，不声称二进制与远端快照逐字核验。没有新的全量离线测试输出，不由此升级 provider-runtime-test 状态。文档同步不要求重跑已经通过的 unsigned 构建。

[WG-INT-10 原始证据](evidence/wg-int-10-provider-runtime.md)：提交时新 18 项门控 XCTest 在 Debug/Release 通过，6 项 Python 包含实际宿主 6 组与交付 10 组场景；明确框架/引擎/数据 DTO 替身，不重复累计。当时原生系统代码只有语法检查，工作区为部分源码，不宣称全仓库回归。其后 [FIX-01](evidence/wg-int-10-fix-01-build-blockers.md) 的构建阻断修复和本次用户原生成功分别留证，不改写历史失败。

历史 [09](evidence/wg-int-09-native-packet-flow.md)、[08D](evidence/wg-int-08d-material-admission.md)、[08C](evidence/wg-int-08c-authenticated-configuration-delivery.md)、[08B](evidence/wg-int-08b-app-credential-vault.md)、[08A](evidence/wg-int-08a-managed-launch-boundary.md) 保留。48eee07 编译/链接/桥接 USER_REPORTED PASS、S1 preflight/unsigned、LocalDev 开窗与遮挡修正均不作废，也不自动覆盖新代码。

## EX-INT-02 当前证据

[02 证据](evidence/ex-int-02-foreground-route-lease.md)：35 项 XCTest Debug/Release 通过（26 项事务、9 项临时文件日志），6 项 Python 通过（内含实际 C 适配器 + 模拟 Darwin 内核的 15 场景），另 4 项旧只读合同回归通过。不是全仓回归或 Apple SDK/真实内核执行。前台候选要求操作员管理员权限和 TTY/APPLY，最多 8 个 /24–/32 结果、60 秒；不自提权、不安装服务，不能替代 SEC-02 的 GUI/Helper 身份验证。记录的 snapshot_comparison 不等于实际流量/DNS 行为或全系统恢复。见 [运行说明](external-execution.md)。

## 当前下一完成标准

对前台执行候选先做 Mac 原生构建，再现场授权受控联调；后续接签名身份验证 Helper 与 GUI。EX-INT-02：明确授权下添加受限 DIRECT 例外，验证原 VPN 保持与目标新连接直连，停止时只撤销自有修改并确认残留。必须补 Helper 身份/权限、准确回执与读回、网络变化/失败恢复；EX-INT-01 快照不是可执行权限。OpenVPN 导入层可提前，不先开三套完整运行后端。不要要求先完成 WG 签名才允许推进本条主线。

## WireGuard 保留的验收标准（暂缓排队）

正式集成 unsigned 构建已取得本次用户成功反馈，不再作为未完成的首要排障。后续恢复 WG 联调时准备并验证本机开发签名、两个 target 的身份/能力/App Group/profile，使用 provider-build --sign；该命令不自动安装/激活，不代表系统签名身份接受。之后验证正确/错误身份、合成配置保存/交付、取消和超时，再现场授权进行握手、指定目标 VPN 与直连双路径测试；实现并验证停止后的独立系统观察。通过这些才能称为首个可用 WireGuard 分流版本。旧凭据/孤儿记录持久化维护仍欠实现，不清空用户数据解决。

完整 IPv6、按 App/进程、Kill Switch、多 VPN 叠加、任意公网后缀自动发现不在 v0.1 欠交清单。无 DNS 字段只是首轮限制，不取消 S2/v0.1 DNS 承诺。LocalDev、原 S1 与原 engine 工作流保留；main 统一更新，不提供历史补丁包。
