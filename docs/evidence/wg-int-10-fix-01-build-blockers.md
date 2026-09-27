# WG-INT-10-FIX-01：原生构建阻断修复

日期：2026-09-27。基线：`263459edd82d1433ab63987bc7a4c73b284325c5`。任务：WG-INT-10，S1-03/04/05 部分；关联 SEC-01、REL-02。继承 [WG-INT-10 ADR](../adr/ADR-WG-INT-10-provider-runtime.md)，不改变运行、签名或权限边界。

## 用户反馈：原生构建仍为失败

用户报告 provider_runtime 的 6 项 Python 检查中 5 项通过，工程生成测试失败：测试期望 `/var/.../libwg-go.a`，生成器已将目录解析为 `/private/var/.../libwg-go.a`。源码引用的比较也有同样的不一致，不能仅修复第一个断言。

用户提供的原生日志明确在 ManagedAuthenticatedXPC.swift 的延时 Task 中报 `sending 'connection' risks causing data races`。WireGuardAdapter 的 weak capture 是 warning，不是本段日志的致命错误。本轮不把旧失败更新为原生 PASS，也不将已有 5 项用户报告成功作废。原始日志、用户名和完整本机路径不入库。

## 实际修复

延时 Task 不再捕获 NSXPCConnection，而是捕获已有 Sendable 监听器的弱引用、MainActor broker 和连接 ID。过期判断仍在 MainActor，实际关闭复用已有 `end(id)`：加锁从注册表取走精确连接，解锁后调用 invalidate，避免同步关闭回调重入时持锁。活动 run 仍免于暂存超时；显式结束和旧 ID 不会关闭另一条连接。

没有给 NSXPCConnection 添加 unchecked Sendable，没有关闭 Swift 6 严格并发检查，没有降低代码签名要求、更改 Keychain ACL、运行授权寿命、构建参数或依赖锁。旧 interruption/invalidation 回调保持不变。

路径修复只修改测试预期：静态库和源码路径均使用 resolve，与实际生成器一致；不改生成器、不硬编码删除 `/private`，也不放宽源码符号链接检查。增加显式目录别名场景，让 Linux 也能覆盖这一类路径差异。

## 本轮已执行

环境：Linux x86_64，Swift 6.2.1，Python 3.13.5。固定基线部分源码工作区；不是完整仓库、Apple SDK 或原生签名环境。

| 检查 | 结果与边界 |
| --- | --- |
| 原工程生成回归 | PASS：实际原样 S1 generator、runtime overlay 和三个完整 integration 源文件，合成 plist；没有运行 xcodebuild |
| 显式目录别名回归 | PASS：同一测试经真实临时符号链接运行，保留含空格路径和完整链接/源码断言 |
| 旧 XPC 捕获负向编译 | PASS：在测试副本重新引入旧捕获，Swift 6 完整代码生成必须以同类 data-race 诊断失败；不是仅语法检查 |
| 修复后 XPC 编译及执行 | PASS：真实 listener/liveness 方法体通过 strict-concurrency=complete、warnings-as-errors；执行过期关闭、活动 run 保留、精确 ID、重复结束和同步关闭回调重入 |

共 4 项针对性 unittest 通过，不重复累计其中分支数量。额外变异检查分别撤回静态库路径或源码路径修复，目录别名用例均按预期失败。Python 语法和修改文件的 macOS 目标 frontend parse 通过。

XPC 测试中的 Foundation XPC 类型、broker、身份与导出对象是明确替身。连接类型故意不声明 Sendable。仅在测试副本把 15 秒暂存延时缩短为 50 毫秒，并等到活动连接的超时判断确实执行；生产延时不变。测试输出标记 `source=ACTUAL framework_broker=TEST_DOUBLES timer=ACCELERATED native_auth=NOT_TESTED`。负向编译使用 `-c`，因为 parse/typecheck 不能替代本次代码生成阶段的隔离诊断。

旧 6 项中的其他 5 项及 Swift 包全量用例没有在本轮重新执行或累计；用户给出的通过结果保留为 USER_REPORTED。新测试由原 provider-runtime-test 的 discover 自动包含，不新增测试开关或改变日常入口。

## 原生复验与未执行项

```bash
git pull --ff-only
/bin/bash dev.sh provider-runtime-test
/bin/bash dev.sh provider-build
```

不需要删除 .local、DerivedData、凭据、缓存或锁文件，不需要重装工具或重复下载依赖。默认构建仍为 unsigned，不安装、不激活；unsigned 产物不可作为真实 VPN 验收。

本轮没有 Apple SDK 完整编译/链接或真实 XPC 接受/拒绝结果。修复后的 Mac 构建仍待用户复验；日志未覆盖的后续编译步骤也未被视为通过。WireGuard 握手、实际双出口和独立路由/DNS 恢复仍未验收。此次仅关闭两个已定位源码/测试问题，不宣称 WG 或 S1 整体完成。

未读取真实密钥、未操作 Keychain/系统 VPN 偏好、未激活扩展、未修改网络。通过非强制 main 更新交付；回滚使用后续 revert，保留用户数据及旧构建证据。
