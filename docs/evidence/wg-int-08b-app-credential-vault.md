# WG-INT-08B：正式 App 凭据仓库证据

日期：2026-09-26。起点：main `9ee36ee0547ac9e02b2fa4d48d4c39430ccdfde1`。任务：S1-03 部分；需求：SEC-01、P-05、REL-02。边界决策见 [ADR](../adr/ADR-WG-INT-08B-app-credential-vault.md)，状态见 [验收表](../acceptance-status.md)。

## 实际新增

新增 `ManagedCredentialVault.swift` 和 macOS 条件编译的 `ManagedAppKeychain.swift`：前者执行不可变记录的准备/读回/读取/精确撤销/清理重试，后者实际调用 SecItemAdd、SecItemCopyMatching、SecItemDelete。它不是只有协议和替身，但原生 Security 分支尚未在本批环境执行。

`load(for:selected:)` 把上一批 CheckedManagedLaunch 与 App 当前提供的记录绑定比较后执行读取。配置和规则归档写入同一 Keychain 记录，普通持久化只可保存引用元数据；没有把密钥或原始配置放入 NE options/providerConfiguration，也没有修改 LocalDev 仓库。材料仅做大小/编码检查，不代替 WireGuard 导入和 PolicyCore 的语义校验。

保存后核对完整记录而非只核对 UUID；准备失败或取消后只清理本次引用。撤销还需独立查不到精确引用才报告确认，错误状态不伪装成成功。重试凭据只存在内存；崩溃恢复和当前选择发布事务尚未实现。

**本批没有新增可供用户连接 VPN 的操作。** 正式 GUI 未调用新仓库；系统扩展授权交付、正式 WireGuard 会话和网络撤销仍未接通。Provider 的合法请求 2001、错误请求 2002、旧 smoke 1001 保持不变。

## 本批实际执行

环境：Linux x86_64，Swift 6.2.1，Python 3.13.5。Mac 项目路径在连接 Runner 上仍不可访问；没有借用其他项目绕过限制。验证目录是从固定 GitHub 基线恢复的部分源码，不是完整仓库构建。

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| ProviderConfiguration Debug | 58 XCTest，0 失败，warnings-as-errors | 新增凭据事务 34 项 + 原启动元数据 24 项 |
| ProviderConfiguration Release | 同一 58 项，0 失败，warnings-as-errors | 优化构建重跑，不另算 58 个新场景 |
| `test_credential_source.py` | 4 Python unittest 通过 | 实际 SwiftPM source discovery、无新依赖、访问边界和无真实 Security 操作的测试约束 |
| macOS 两份条件源码语法 | arm64-apple-macos26.0 frontend parse 通过 | 只有语法解析，不是 Apple SDK 类型检查或链接 |
| 原始包输入 | Package.swift、ManagedLaunch.swift、原 24 项测试与远端 Git blob SHA 相符 | 原始三文件未修改 |

新增测试使用 NSLock 保护的内存 Keychain 替身，覆盖重复记录不覆盖、完整绑定错配、读回内容不符、任意错误脱敏、删除未生效/查询拒绝、写入后取消、精确清理重试、并发重复准备、大小界限及 NSMutableData 快照隔离。34 项中包含参数循环和并发操作，不将内部次数另计。

复查修正了一个清理状态错误：已限定查询报不存在，但精确引用仍存在或查询被拒绝时，原因和附带 cleanup 字段都必须为未确认。此路径不会生成未经记录核对的删除重试权限。

macOS 专用 `ManagedAppKeychainQueryTests` 的 5 项只构造/检查原生查询，不调用 SecItem*，在 Linux 条件编译中排除，**本批 NOT RUN**。它们不是 58 项的一部分，也不计作真实 Keychain 验收。

本批可单独复现的已执行命令：

```bash
swift test --package-path Packages/ProviderConfiguration -Xswiftc -warnings-as-errors
swift test --package-path Packages/ProviderConfiguration -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/provider -p test_credential_source.py -v
```

日常完整入口仍为 `/bin/bash dev.sh provider-test`，无需 Go、不下载、不读写真实 Keychain、不改网络；在 Mac 上还会编译/运行新增原生查询构造测试。本批没有执行完整入口中的旧 Python Provider harness；不能把上述四项写成全部 provider-test 通过。Swift Testing 的尾部“0 tests”是未使用测试框架的输出，实际计数以 XCTest 汇总为准。

## 明确未执行 / 未实现

新增代码的 Apple SDK 类型检查、xcodebuild、真实 Security 读写/权限/锁屏行为、正式 App 交互、VPN 偏好保存/重载、App→系统扩展身份验证和凭据传输、最新选择与防重放、崩溃记录恢复、可信隧道通道、网络变化、真实握手/流量分流/路由与 DNS 恢复均未验收；其中多项仍缺实现，不只是缺测试。

旧 PolicyCore/AppCore/ManagedSettings/ProviderSession/Go/原生引擎/S1 套件未在本批重跑或计数。`48eee07` 用户报告的编译/链接/符号成功继续保留，仅覆盖该基线。未安装工具、未读取真实配置/密钥、未修改签名权限/LocalDev/依赖锁/网络。main 统一交付，无更新 ZIP。

下一优先项是正式选择发布事务与经身份验证的跨进程交付，随后自有数据通道和正式运行会话；不因本仓库实现宣告 SEC-01、S1 或可用 VPN 已完成。回滚为后续 revert 提交，保留用户数据和历史证据。
