# 当前能力与需求验收状态

更新：2026-09-26，WG-INT-08C。起点 a2f7d30；不改变[需求规范](requirements-v0.1.md)或[路线图](roadmap.md)的承诺。代码、离线测试、原生编译、真实功能分别记录。

**完整 S1 未通过，尚无可用 VPN，不是只剩签名。** 本批将正式保存/选择、App Keychain、经系统签名要求验证的 XPC 和真实 Provider 消费入口串为代码路径；Apple SDK、真实签名/权限/XPC/GUI 尚未验收。引擎与自有数据通道、实际网络状态和系统撤销仍缺接线。

| 需求/范围 | 已有能力或证据 | 未完成验收/实现 |
| --- | --- | --- |
| WG-01/06、UX-02 | LocalDev 完整结构导入保留；正式页显式选择有界 .conf 和 CIDR 保存交付草稿 | 正式材料仍须完整协议/脚本/Peer/DNS 语义解析，不能凭 UTF-8/传输成功执行 |
| WG-03/04、RULE-02 | PolicyCore/ManagedSettings 可计算约束内路由与设置 | 正式 Provider 应用设置、协议 AllowedIPs 不变和真实双出口 |
| P-05/06、WG-05 | 正式页显式载入/保存/选择/交付检查/取消；真实 NE API 调用已接入 | 原生 GUI 和偏好行为待验；不是可用 VPN 连接页，不自动激活扩展 |
| RULE-05、REL-02 | 选择基线对照、不可变记录、保存/重载提交；未知保存保留候选；一次性版本/引用/UID/连接绑定和过期回归 | 非协作写者/最后检查后的 OS 修改没有原子 CAS；持久化孤儿/旧记录清理、真实 epoch 和运行态全局单会话未完成 |
| SEC-01 | App 私有 Keychain → 认证 XPC → 正式 Provider 消费已有代码；精确 Team/角色的系统 peer requirement；无扩展 Keychain 读取 | 原生接受/拒绝、实际签名/组/profile/锁屏/用户切换/进程退出必须验收。新增组仅 Mach 通信；Keychain 固定 App 自身 application identifier，LocalDev 权限不变 |
| REL-01、UX-04/05 | 元数据错 2002、无活跃交付 2003、收到但无引擎 2001；旧 smoke 1001 | UI 真实 NE/后端状态观察、握手/可达性尚未完成；XPC ACK 和 startTunnel 返回不是连接成功 |
| FAIL-03、DIAG-02 | 未消费材料在取消/失效/过期/停止时丢弃；保存未知不误删凭据 | 消费后的引擎撤销、启动/断开/崩溃的路由和 DNS 恢复均未实现闭环，停止请求不证明恢复 |
| WG-02、WG-05 | 首轮单 Peer 目标保留；本批不静默丢弃 Peer | 单 Peer 实际运行先验；多 Peer、重连、睡眠、切网和统计另验 |
| DNS-01～05、S2 | 规划与限制已定义 | Split DNS、域名来源/有效期/更新和共享 IP 冲突实际执行未完成 |
| OV-01～08、S3 | 后端目标与选型约束已定义 | .ovpn 完整导入、认证、push 审核、运行和分流未接通 |
| EX-01～08、S4 | S0 受控 IPv4 直连例外与恢复有用户报告 | 应用内 External/Helper/识别/争用/撤销未闭环，S0 收尾独立保留 |
| DIST-01/02、S5 | 发行规范已定义 | Developer ID、公证、DMG、安全/稳定性和原业务最终替代未验收 |

## 已有证据不重复作废

48eee07 的编译/链接/桥接符号 USER_REPORTED PASS 仅覆盖该基线；S1 preflight/unsigned、LocalDev 开窗/顶部遮挡修正的成功反馈保留，不能扩大为本批原生构建或真实 VPN 验收。

本批执行子集及 NOT RUN 见[08C 证据](evidence/wg-int-08c-authenticated-configuration-delivery.md)；保留[08B](evidence/wg-int-08b-app-credential-vault.md)与[08A](evidence/wg-int-08a-managed-launch-boundary.md)历史。本批只执行新增 41 项 Swift 两种构建及 16 项 Python 选定检查，不累计未重跑的旧 58 项 Swift/全仓套件。

## 下一完成标准

先在新增正式工程验证选择/保存和正确身份的实际交付（含拒绝场景），同时实现交付材料完整语义转换、自有数据通道、WireGuard 正式会话、网络失效和撤销。最终必须由本应用建立的隧道承载指定目标新连接，其他目标保持直连，且取消/断开与系统状态有实际证据。

完整 IPv6、按 App/进程、系统级 Kill Switch、多 VPN 叠加、任意公网后缀自动发现不在 v0.1 欠交清单；不以“收到凭据”取消现有任何阶段门槛。
