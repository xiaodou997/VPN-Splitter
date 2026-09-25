# ADR-010：LocalDev 凭据与可重试清理

日期：2026-09-25；状态：实现决策，macOS Keychain 行为待真机验证。任务 LD-02B / S1-03 部分；不关闭真实隧道门槛。

## 范围

新增经用户确认的 Keychain 凭据导入、同策略重新导入、读取校验、移除与失败恢复。原结构导入仍可选，不写原 .conf，不扩展 AllowedIPs，不修改网络。旧 v1/v2 数据继续可读；首次凭据事务才升级 v3。v3 普通 JSON 只有非密钥元数据、随机引用与待清理引用，不包含任何密钥值或原始配置。旧程序拒绝 v3，不能靠手改版本回退。

## 存储选择

LocalDev 使用 Security 的 SecItem 泛型密码 API，明确选择 macOS 文件型 Keychain，独立 service `com.vpnsplitter.localdev.wireguard.v1`，随机 UUID account。没有 access group / NE entitlement、iCloud 同步或扩展共享。使用默认 Keychain 的系统访问控制，不设置允许任意程序读取的 ACL，不调用 security CLI。正式签名版本应另行决定 data-protection Keychain 和跨目标权限，不声称这里的记录能被扩展直接使用。

Apple 一手资料：
- [TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)：两种实现与 SecItem 选择。
- [SecItem pitfalls](https://developer.apple.com/forums/thread/724013)：唯一性、精确查询、避免读取失败后删除。
- [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)：代码身份与要求。

ad-hoc 构建身份变化后的访问 / 系统提示必须实测；拒绝或不可访问时报告失败，不放宽 ACL，不回退明文。不保证内存零化、不称作 Secure Enclave 存储、也不提供锁屏即不可读或无备份保证。

## 事务与恢复

凭据不可原地覆盖。每次凭据保存使用新随机引用，先在工作区持久化待清理引用，再写 Keychain 并读回验证（完整结构、密钥、引用归属），最后原子提交新结构 / 引用，把旧引用转为待清理。任何最终提交前失败，旧配置与旧凭据引用保留；可能留下的新项可根据日志重试清理。结构模式重导入有旧凭据时明确移除其关联，进入待清理。

删除先提交元数据中的解除引用 / 删除，再清理明确记录的条目。清理前读取并检查记录的 profile / UUID / ownership nonce，再使用该条目的 persistent reference 加精确 service/account 删除。不批量枚举或按 service 清空。条目不存在可幂等确认；锁定、取消、格式损坏或归属不符保留待处理记录，不宣称已清理。删除后日志保存失败可安全重试。

启动不自动访问或删除 Keychain。用户显式保存 / 检查 / 清理才触发；后台工作期间禁止并行编辑、重复操作或普通退出。待清理项在全局和导入报告内可见，失败后可先清理再重试保存。跨进程 lease 拒绝同时运行本版多个写入者；旧版不遵守 lease，因此不支持新旧版同时运行。日志丢失 / 人工回退备份可能留下孤立项，不自动扫描删除。

只用合成配置执行测试。Linux 的故障注入仅验证协调器，不是系统 Keychain 测试。首次真实配置使用前先通过本机合成导入、拒绝授权、重新导入和删除清理的清单。

## 恢复保证的限制

本轮协调器验证正常进程中断后已提交工作区记录的恢复次序，不声称跨 Keychain 与文件系统的原子事务。DraftStore 同步临时文件并 rename，但没有目录 fsync / 全盘掉电保证；断电、文件系统损坏、Keychain 服务自身的极端中断，以及恢复旧备份后的孤立条目，未获保证或实测。保留原 .conf，不把单元测试的故障注入当成 macOS 全场景崩溃测试。

租约是本版实例间的 advisory flock，不防止旧版、手工改 JSON 或同用户进程的竞态。每次凭据事务写入前另检查磁盘工作区是否与内存一致；不提供自动并发合并。遇到归属冲突 / 损坏记录时没有强制清空入口，保留诊断与数据；不要随意删除锁文件、工作区或其他 Keychain 内容来通过测试。
