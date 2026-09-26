# 当前能力与需求验收状态

更新：2026-09-27，WG-INT-10。起点 e79f889；[需求规范](requirements-v0.1.md)及 S0–S5 退出条件不变。代码、离线回归、原生构建与真实功能分开记录。

**WG-INT-10 的正式运行代码已接线，WG/S1 真实验收尚未完成。** 独立 provider-build 将 App → 认证 run 交付 → 正式 Provider → 网络观察/策略设置 → packetFlow/Go 引擎 → stop/clear 编入同一正式工程。没有本批 Mac 编译、真实握手、双出口和系统恢复证据；不是已可交付的稳定 VPN。

| 需求/范围 | 现有实现 | 待验收或待实现 |
| --- | --- | --- |
| WG-01/02/06、UX-02 | 08D 完整导入/语义检查 + 09 原生对象转换接入运行宿主；单 Peer/IPv4 数字端点/无 DNS 字段 | 真实配置和原生转换验收；多 Peer 后续另验，不静默裁剪 |
| WG-03/04、RULE-02 | 实际 PolicyCore/ManagedSettings 编译，包含主物理 LAN/网关/MTU 观察；设置成功后启动 | 原生网络/API 编译与实际双出口；不是全路由表/过滤器冲突识别器 |
| P-05/06、WG-05 | 独立连接确认发送严格 run-v2；旧 v1 交付检查仍无网络；集成 Provider 调用真实 backend | GUI/权限/真实连接/取消/断开待验；默认 unsigned 只编译 |
| RULE-05、REL-02 | 原控制器 + 单会话持有、观察快照绑定 epoch、变化即撤销、无自动重连 | 非协作系统偏好变更无原子 CAS；更广网络变化、重连质量和持久化恢复仍待完善 |
| SEC-01 | 精确 Team/角色 OS XPC gate；App 私有 Keychain；消费后的连接租约随失效撤销 | 原生签名接受/拒绝、锁屏/用户切换/退出验收；不新增共享 Keychain，不改 LocalDev ACL |
| REL-01、UX-04/05 | 实际 NE 状态显示，设置 ACK/engine ready/握手未验证分开；运行失败静态代码 | 握手/统计采集和真实目标探测未实现；不能由 connected 推出全部规则已验证 |
| FAIL-03、DIAG-02 | 取消/超时等待原 apply，关闭 engine 后 clear；迟到清除不升级成功；不确定资源保留 | 独立路由/DNS 恢复观察仍未实现；崩溃/系统晚回调真实行为未验收，nil ACK 不算系统恢复 |
| WG-05 运行质量 | 切网或睡眠主动停止，授权断开空闲会话也撤销 | 睡醒/切网自动重连、长时稳定性、性能和异常退出恢复后续实现与验收 |
| DNS-01～05、S2 | 保留原 DNS/域名目标；首轮含 DNS 字段明确拒绝 | Split DNS、来源/TTL/更新/共享 IP 冲突等未接通 |
| OV-01～08、S3 | 原范围与选型约束保留 | .ovpn 导入/认证/push/运行/分流未接通 |
| EX-01～08、S4 | S0 受控样本及恢复 USER_REPORTED | 应用内 External/Helper/争用/撤销未闭环；S0 收尾独立保留 |
| DIST-01/02、S5 | 正式可重复集成构建入口已有代码 | Developer ID、公证、DMG、依赖可达漏洞/许可及原业务最终替代未验收 |

## 证据与边界

[WG-INT-10 证据](evidence/wg-int-10-provider-runtime.md)：新 18 项门控 XCTest 在 Debug/Release 通过，6 项 Python 包含实际宿主 6 组与交付 10 组场景；明确框架/引擎/数据 DTO 替身，不重复累计。原生系统代码只有语法检查，不是 Apple SDK 类型检查。工作区为部分源码，不宣称全仓库回归。

历史 [09](evidence/wg-int-09-native-packet-flow.md)、[08D](evidence/wg-int-08d-material-admission.md)、[08C](evidence/wg-int-08c-authenticated-configuration-delivery.md)、[08B](evidence/wg-int-08b-app-credential-vault.md)、[08A](evidence/wg-int-08a-managed-launch-boundary.md) 保留。48eee07 编译/链接/桥接 USER_REPORTED PASS、S1 preflight/unsigned、LocalDev 开窗与遮挡修正均不作废，也不自动覆盖新代码。

## 下一完成标准

先执行 provider-build（不是旧 S1 unsigned 或 engine-flow）验证这批正式集成。通过后验证正确/错误身份、取消和超时，再现场授权进行握手、指定目标 VPN 与直连双路径测试；实现并验证停止后的独立系统观察。通过这些才能称为首个可用 WireGuard 分流版本。旧凭据/孤儿记录持久化维护仍欠实现，不清空用户数据解决。

完整 IPv6、按 App/进程、Kill Switch、多 VPN 叠加、任意公网后缀自动发现不在 v0.1 欠交清单。无 DNS 字段只是首轮限制，不取消 S2/v0.1 DNS 承诺。LocalDev、原 S1 与原 engine 工作流保留；main 统一更新，不提供历史补丁包。
