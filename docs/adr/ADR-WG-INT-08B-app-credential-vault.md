# ADR-WG-INT-08B：正式 App 私有凭据仓库，不冒充扩展共享

日期：2026-09-26。状态：Accepted（App 侧实现边界）；Apple SDK、真实 Keychain 和跨进程交付未验收。任务：S1-03 部分；需求：SEC-01、P-05、REL-02。继承 [WG-INT-08A](ADR-WG-INT-08A-managed-launch-contract.md)，不改变产品范围或首次真实隧道门槛。

## 为什么不直接让系统扩展读 LocalDev Keychain

Apple 的 [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) 区分数据保护和文件式 Keychain：前者依赖用户登录上下文，系统守护进程不能简单沿用用户 App 的访问方式；两者的权限模型也不同。用户上下文的 App Extension 示例不能直接证明 Packet Tunnel System Extension 的访问可行。

因此本批先实现正式包含 App 的真实 Security API 适配。它是后续交付链的凭据来源，不是已完成的跨进程共享。不给系统扩展新增共享组，不更改 LocalDev ACL，不退回读取 login/System Keychain。跨进程调用方验证、当前配置发布事务和凭据交付协议仍须另行实现和审查。

## 本批决策

- `ManagedCredentialVault` 是非 MainActor 的 actor；生产工厂只接受匹配 Bundle ID 的 `.app` 和非 root、实际/有效 UID 相同的进程。Bundle ID 和 UID 检查是角色与记录绑定，不是签名身份认证；实际访问仍由 Security 的进程权限执行。
- 使用显式数据保护 Keychain、独立 service、不可同步、仅本机且解锁可访问的记录；`LAContext.interactionNotAllowed` 禁止本层隐式弹出授权。没有默认 Keychain 或共享访问组回退。
- 单条记录包含配置字节、规则归档及完整 profile/credential/policy/generation/UID 绑定。只在 Keychain 序列化；普通偏好只可持有不透明引用与元数据。配置和规则各限 64 KiB，整个记录限 140000 字节；它们仍须经已有解析器和 PolicyCore 检查，仓库不宣称完成 WireGuard/规则语义验证。
- `prepare` 新增记录后读回核对全部绑定及内容。重复项不覆盖，不因准备新记录删除旧记录；调用方更新时应使用新的 credential ID。`load(for:selected:)` 将 WG-INT-08A 的元数据检查接到 App 内的真实读取，但不证明该选择是最新已发布版本。
- 撤销先核对记录，删除时限定精确引用与 account/service；之后另查同一引用是否仍可见。删除返回成功不等于确认不存在。取消发生在写入后时走同样的精确清理；无法确认则保留不透明、内存内的清理凭据供显式重试。
- 错误、材料、句柄及清理凭据的描述和反射脱敏。底层任意错误不直接外传；不记录配置、引用、策略或密钥。Swift/Data/Keychain 的副本不承诺全部安全擦除。

## 失败与未实现边界

拒绝访问、缺少签名权限、锁定或未交互授权均报错，不自动换源或放宽保护。原生调用阻塞不能被此 actor 强制终止；取消只在调用前后检查。

若写入成功但缺少可用引用，状态为写入/清理未确认；不扫描仓库猜测应删除的项。清理凭据不是可持久化恢复日志，进程崩溃后的孤儿记录处理仍缺正式事务实现。

“确认不存在”只指当前 App 安全上下文内对精确引用的查询结果，不是物理擦除保证、全局授权证明或路由/DNS 恢复。读取一个有效旧句柄仍可能成功，权威选择、代际发布、防重放与系统偏好重载必须由正式控制层维护。

## 接线状态与后续

两个正式 target 已引用 ProviderConfiguration，本批文件由 SwiftPM 自动发现；没有新增工程、依赖、entitlement 或 LocalDev 数据迁移。正式 GUI 尚未调用新仓库，Provider 仍拒绝真实启动，没有把用户 Keychain 引用交给系统扩展直接读取。

下一交付应接正式配置选择/发布事务，以及经过身份验证的 App→Provider 交付，然后接扩展自有数据通道与 WG-INT-07 运行会话。不能继续用增加仓库字段或测试数量代替这些执行链缺口。Mac 构建与真实授权读取各自留证；首次启动 VPN 仍需现场授权和恢复方案。

本批测试与未执行项见 [证据](../evidence/wg-int-08b-app-credential-vault.md)。回滚使用后续 revert，不删除用户记录、锁文件、缓存或历史证据。
