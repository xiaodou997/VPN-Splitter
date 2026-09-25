# ADR-007：LocalDev 并行开发，真实隧道联调前恢复开发签名

日期：2026-09-25。状态：Accepted（用户确认开发顺序调整；不代表 Mac 构建或 VPN 验收通过）。
任务：LD-01、S1-03 的后续准备、S4-04 的界面前置。关联：T-U02–U05、T-P01–P03；本轮独立测试 T-LD01–T-LD05。

## 决策

签名暂停期间，不阻塞配置草稿、规则、纯逻辑诊断和模拟交互。新增独立工程 `apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj`，唯一应用目标为 `VPN-Splitter-LocalDev`。它不依赖或嵌入现有 App / Packet Tunnel target，不激活扩展，不写路由或 DNS。现有 S1-01 工程、entitlement 与构建入口不变。

LocalDev 采用 ad-hoc 本地签名设置，不填开发团队，不使用 provisioning profile。它不是开发证书签名后的 Managed VPN，也不是经过公证的发行包；不能借此绕过真实 Network Extension 的授权。Apple 机制参考：[构建设置](https://developer.apple.com/documentation/xcode/build-settings-reference)、[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。实际本机构建、签名检查和窗口运行仍需验证。

提取 `Packages/AppCore` 作为与 UI 无关的业务层，依赖已有 `PolicyCore`。LD-01 共享模型、存储、规则编译适配和模拟状态机；SwiftUI 只负责交互和模拟延迟。没有引入第三方依赖。未来正式 UI 可复用 AppCore；本轮没有把正式 S1 加载验证界面替换成 LocalDev，也没有完成真实后端的统一注入。

## 本轮范围

LD-01 实现可保存的策略草稿，不声称已经导入 VPN 配置。草稿只有名称、能力预设、默认动作和有序规则。`.conf` / `.ovpn` 导入及凭据保存尚未开放；不为赶进度把私钥、密码或原始配置写入 JSON。用户不要在普通文本字段粘贴秘密。

规则预览调用现有 `IPv4PolicyCompiler`，保持 first-match；启用的 DOMAIN、DOMAIN-SUFFIX、IPv6 或 REJECT 阻止预览，禁用草稿可保留编辑。能力预设不是运行时探测。当前是规则意图预览，不调用 `IPv4ConstrainedPolicyCompiler`，不做基础设施、peer、DNS 或出口验证。这些缺口必须显示，不能用一个空拓扑或虚构 peer 来制造“已通过”。

连接成功、认证失败、取消和重试仅为模拟，状态始终带“模拟”及网络未接管说明。编辑、切换、删除或重新编译会使旧预览失效；迟到回调由每次尝试的 token 拒绝。只持久化草稿，不持久化活动连接或预览。

## 存储与恢复

使用 LocalDev 独立用户数据目录，目录权限 0700、文件 0600。序列化前校验版本、容量、标识和单行字段；先准备临时文件，再原子重命名发布。加载损坏、版本不支持或符号链接目标时报告错误并禁止写入，不自动覆盖成空配置。保存失败时不接受新的内存工作区。

这不是凭据保险箱，也不承诺对抗同一用户进程的路径竞态、多进程并发写入或所有掉电场景。暂不支持多实例并发编辑，不提供自动删除恢复。具体手工保护和恢复步骤见 [LocalDev 操作](../localdev.md)。

## 顺序与不变门槛

LD-01 后推进 LD-02 / S1-03：WireGuard 结构解析、兼容报告、安全凭据边界，以及基础设施 / peer 检查的输入和展示。OpenVPN 导入评估随后进行，不同时实现三个真实后端。

首次证明请求经过本应用的真实 Managed 隧道之前，恢复开发签名、描述文件和扩展授权验证。Developer ID 发行签名、公证、DMG 仍在发行阶段。已通过的 S1 preflight / unsigned 作为 USER_REPORTED 保存，不要求重做；原 unsigned 产物仍只用于编译检查，不安装或激活。

本 ADR 调整 ADR-001 D09 和路线图中的开发调度，不改变 S0–S5 的真实验收门槛，不减少最终产品范围或提升防泄漏、IPv6、域名、External 的保证。测试边界和本轮结果见 [LD-01 证据](../evidence/localdev-01.md)。
