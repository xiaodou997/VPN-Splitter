# ADR-WG-INT-08C：正式选择事务与经签名验证的凭据交付

2026-09-26；Accepted（代码方案），原生签名/Keychain/XPC/GUI 验收 NOT RUN。起点 a2f7d30；S1-03 部分，SEC-01、P-05/06、RULE-05、REL-02。继承 08A/08B，不改变 v0.1 范围，也不表示可用 VPN。

## 执行链与信任边界

正式 App 的显式页面 → 当前 NETunnelProviderManager 重载 → App 私有 Keychain 新记录/完整读回 → NE 偏好保存/重载 → 双向签名校验 XPC hello → 当前选择复核和一次性 Keychain 读取 → XPC 暂存 → 再次重载 → NE startTunnel 元数据 → 正式 Provider 消费同一材料。

系统扩展是 root 守护进程，不沿用用户 App 的数据保护 Keychain。凭据仍在 App 登录上下文读取；无 LocalDev ACL 修改、login/System Keychain 回退或扩展 Keychain 读取。Apple 的用户/系统上下文区别见 [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。

08B 的“不给扩展新增共享组”在本批明确细化：新增专用 **Mach 通信 App Group** 与 NEMachServiceName，两个正式 target 均声明；不调用 group container API，不在该组存文件。Keychain 查询显式固定到包含 App 自身签名的 com.apple.application-identifier，而不是通信组，也不新增 keychain-access-groups entitlement。已有权限失败不自动迁移或放宽；LocalDev 完全不变。

App→扩展只有两个 XPC 方法：无秘密 hello 和有界 stage。App 使用 privileged Mach lookup，并在 resume 前设置扩展精确签名要求；listener 在监听前设置 App 精确签名要求，不对同一连接重复设置。要求 Apple anchor、明确加引号的 Team ID、精确角色标识；拒绝 get-task-allow、disable-library-validation、allow-dyld-environment-variables。先用 SecRequirementCreateWithString 检查语法。没有 PID 查进程、路径猜测、IPC 自报 Team/Bundle ID 或失败后替代授权。参考 [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))、[NSXPCListener](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))、[TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)。

通信服务命名使用 $(TeamIdentifierPrefix)$(VPN_APP_BUNDLE_ID).managed.credentials；组为前面的 .managed。证书 Team ID 从 DEVELOPMENT_TEAM 单独取值，不把 App ID prefix 当 Team ID。组须在开发者配置和实际签名中正确授权，参见 [Apple DTS 的 NEMachServiceName 说明](https://developer.apple.com/forums/thread/128550)。运行时检查自身签名和组；ad-hoc/缺组/调试例外不会降级通过。开发签名不等于允许 get-task-allow，联调须使用满足要求的签名配置，不能放松检查换取通过。

## 正式保存事务

本批只发布一个正式选中配置，不改变 LocalDev 多草稿。显式载入建立编辑基线；保存和交付都不先自动刷新来吞掉别人的新版本。Keychain 新记录包含 .conf 字节和规则归档，普通 NE 偏好只含原 08A 描述符、不透明引用、公开 owner UID。UID 不是密码也不是授权证据，扩展须与 XPC 内核提供的有效 UID 对照。

App 持有仅含锁的 0700 目录和 0600 文件的生命周期 flock，拒绝符号链接、其他所有者、宽权限和并发本应用写者。已有目录可重开，永不删除锁来解锁。这是协作写者锁，不是权限证明；系统偏好没有本实现可用的原子 CAS。新记录准备后再次比较选择；保存回调后重新载入相等才提交。保存结果未知/取消发生在提交后时保留候选、禁止交付；原生保存尚未回调时 pendingWrite 保持阻断，超时不等于强制取消系统写入。新旧记录均不广泛扫描或自动清理。

启动后显式重载可恢复当前系统选中的引用，但不承诺阻止非协作程序/旧程序在最后检查后的修改，不承诺崩溃窗口内未完成系统操作已经撤销。旧记录、孤儿记录及失败清理收据的持久化管理仍需后续补齐；当前不做凭据垃圾回收，不伪装已物理擦除。未提交的新记录清理失败显示 cleanupUnconfirmed，不能显示已恢复。

## 一次性材料交付

hello 的随机 nonce/实例 ID 只绑定本条已通过 OS 身份验证的连接；不是独立认证。App 在认证 hello 后才读取 Keychain；读取机会在 await 前占用，不自动重试。读取前后、提交前均与当前选择对照。stage 只保留内存，和 owner UID、完整版本/attempt、引用绑定；正式 Provider 必须全部匹配才能消费，一次消费或错配均删除暂存。连断、取消、停止、过期均丢弃尚未消费的材料。

最多 8 条连接、一个暂存材料、进程生命周期内 256 个已暂存 attempt 墓碑；上限后明确拒绝，不自动重启扩展。连接/挑战约 15 秒，XPC/偏好单次等待 5 秒；回调和消费都检查单调时钟，不依赖定时器准点。已被 Foundation 反序列化的 XPC Data 仍有外层框架分配成本，本层只对进入解析/暂存的材料限额（145000 字节，配置和策略各 64 KiB），不宣称任意恶意消息完全无资源消耗。

08B“序列化仅 Keychain”仅针对持久化：本批增加有界、瞬时、已认证 XPC envelope，禁止写入文件/NE options/providerConfiguration/sendProviderMessage/日志。Swift/Data/系统 IPC 副本不保证全部清零。协议是同机身份受限交付，不宣称额外端到端加密或完整进程防入侵。

## 当前真实边界

正式页面把 CIDR 解析后存为 managed-ipv4-include-draft-v1；.conf 仅检查 UTF-8/文件大小。它不是完整 WireGuard/脚本/Peer/DNS/AllowedIPs 运行校验。正式 Provider 收到材料后暂不执行它，返回 2001；元数据错配 2002；没有匹配的活跃认证交付 2003；原 smoke 保留 1001。没有设置路由或 DNS。

下一步须将已交付材料经过现有完整导入/规则编译转换，再接扩展自有数据通道、WG-INT-07 会话、实际网络 epoch、取消/失效和撤销观察。消费后的长生命周期撤销还未接到引擎，因为引擎尚未安装。不能把本批联调页面叫作真实连接页。

本批证据见 [08C](../evidence/wg-int-08c-authenticated-configuration-delivery.md)。权限变化必须原生验收，源码/替身不能证明 OS 认证通过；失败保持阻断。回滚为后续 revert，不清空用户配置/Keychain/锁/缓存。
