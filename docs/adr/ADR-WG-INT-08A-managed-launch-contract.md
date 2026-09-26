# ADR-WG-INT-08A：正式 Managed 启动元数据边界

日期：2026-09-26。状态：Accepted（本批代码边界与调度）；联网功能未验收。  
基线：main `eafac9f`（WG-INT-07）。任务：S1-03/04 部分；需求：P-05/06、WG-05、RULE-05、SEC-01、REL-01/02。本 ADR 不替代 v0.1 范围和 S1 退出条件。

## 决策与范围

按用户要求，下一主目标是单配置、首轮单 Peer、IPv4 Include 的真实连接闭环，不继续优先扩展 LocalDev。保留暂停签名期间的无网络副作用开发；首次真实联调仍需单独签名和现场授权。

本批仅实现 App 与正式 PacketTunnelProvider 共用的启动元数据协议，并将它加入两个实际 Xcode target。`ManagedTunnelLaunchClient` 从调用方已重新载入、明确选定的 NETunnelProviderManager 进行一次提交，拒绝禁用、On Demand、非 disconnected、错误协议/会话、错配版本或引用。返回 attempt ID 只表示调用已提交，既不表示 Provider 收到，也不表示连接成功。它尚未被正式 GUI 调用，不能作为“连接按钮已实现”。

Provider 的真实 startTunnel 先识别 Managed 请求，再做元数据校验。错误请求返回固定错误 2002；合法请求仍返回 2001，说明真实凭据与隧道运行未接通。旧 S1 smoke 返回 1001 的路径保留。不能仅移除错误返回或用替身 loader/数据通道来宣称完成。

## 传输契约

`providerConfiguration` 仅有 `VPNSplitterManagedProfile`；start options 仅有 `VPNSplitterManagedStart`。版本 1 的 profile 包含 scope、profile UUID、credential UUID、policy revision UUID、generation；start 再增加 attempt UUID。generation 使用规范十进制字符串，避免 Foundation 的 Bool/NSNumber/浮点强制转换；UUID 使用本应用生成的规范形式。字段、类型、版本、scope 不支持即拒绝。nil options 不触发自动启动。

`passwordReference` 被当作长度受限的不透明引用；本批不解析、不创建、不读写 Keychain 记录。普通元数据不承载密钥、PSK、原始配置或规则正文。未实现的真实存储事务不能因已有字段结构而被标记完成。

scope 固定为 `wireguard-single-peer-ipv4-include-v1`，只是协议版本的意图标签，不能证明尚未载入的实际配置是 IPv4/单 Peer/Include。实际配置和规则仍须在运行前经既有编译器及权威状态检查。

## 明确不构成的保证

相等的 UUID、generation、引用和 Bundle ID 字符串仅能核对本次传入的元数据。它们不是调用方身份认证、Keychain 记录授权、全局最新版本、防重放令牌或 utun 所有权证明。App 辅助对象的一次性也不是系统范围的多会话锁。

后续必须根据正式 System Extension 的实际运行身份与可用授权机制选择凭据来源，校验真实调用方/记录所有者/完整配置快照。禁止为凑通代码而放宽 LocalDev Keychain ACL，禁止把原始密钥放进 providerConfiguration、options、日志或普通工作区。可信隧道资源、实际网络 epoch、WireGuard 会话及系统撤销观察同样尚未实现。

## 权限、兼容与恢复

不改 entitlement、签名设置、数据 schema、现有 LocalDev 工作区、依赖锁或 WireGuard 原生构建流程。不安装/激活扩展，不保存 VPN 偏好，不迁移真实凭据，不调用系统网络设置。未知情况明确拒绝启动，因本批没有开始任何网络执行，不声称测试了运行失败后的路由/DNS 恢复。

提交失败不自动重试；未来调用方须观察终态、重新载入偏好并重新确认后创建新提交对象。系统恢复须有独立证据，不能用 stop 回调代替。代码回滚采用后续 revert 提交，不 reset/clean/删除用户数据。

## 验证

见 [本批证据](../evidence/wg-int-08a-managed-launch-boundary.md)。纯 Swift 测试、Foundation 序列化和显式框架替身验证不是 Apple SDK 编译或跨进程授权/真实流量证据。未新增第三方依赖；本批测试替身均为项目自有合成代码。
