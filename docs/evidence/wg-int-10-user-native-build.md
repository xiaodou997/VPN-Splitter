# WG-INT-10：用户报告正式集成原生构建通过

记录日期：2026-09-27。任务：WG-INT-10，S1-03/04/05 的原生构建证据；不关闭 WG/S1 功能验收。

## 用户提供的本次结果

用户在此前 FIX-01 排障后执行 `/bin/bash dev.sh provider-build`，提供以下终端结果（省略完整本机路径）：

```text
schema=provider-runtime-build-v1
provider_compile_link=PASS
artifact_execution=NOT_RUN
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
Unsigned compile only. Do not install or activate this artifact.
```

本次结果对应的本机运行目录为 `provider.xrgxd5w3`，不是先前失败的 `provider.5r37fzqy`。产物为该次目录下的 `Products/Release/VPN-Splitter.app`；原始完整路径不提交。

证据等级：**USER_REPORTED PASS — 正式 App/System Extension 集成原生编译与链接**。不是助手在 Mac 上重新执行，也不是 Linux 替身测试的升级。

记录时远端 main 为 `a4dfc320fe3339d352635fbf5d1be1ea917df698`，即 [FIX-01](wg-int-10-fix-01-build-blockers.md) 修复线。终端摘要未包含本地 commit、工作区状态、工具链版本、result.json 源码指纹或二进制哈希；因此不声称本机快照与远端逐字一致，也不把本次成功自动推广到后续代码。不要求为了补版本字段重跑已通过的 unsigned 构建；本机原始 result.json/build.log 应保留。

## 本次成功覆盖与不覆盖

依据已回读的该修复线 `tools/provider/build-runtime.py`，正常输出此 PASS 前，流程会完成固定 packetFlow 引擎候选构建、正式 App/扩展 xcodebuild、检查唯一嵌入扩展、arm64 架构、定义的 packetFlow C 符号，以及所记录 Swift 源码构建前后一致性。因此本次是正式集成构建通过，不是只运行链接探针、旧 S1 unsigned 或 LocalDev。

这仍是脚本检查范围的说明，摘要本身不是独立的二进制审计。没有收到新的 provider-runtime-test 完整通过输出，不能由 provider-build PASS 推导全部离线测试通过；此前测试结果与失败记录分别保留。

| 项目 | 本次状态 |
| --- | --- |
| 正式集成原生编译/链接 | USER_REPORTED PASS |
| 构建产物执行 | NOT_RUN（用户摘要明确列出） |
| 网络设置应用 | NOT_APPLIED（用户摘要明确列出） |
| 扩展激活请求 | NOT_REQUESTED（用户摘要明确列出） |
| 开发签名及签名身份/权限接受 | 未通过验收；本次为 unsigned |
| 真实 Keychain/XPC/偏好保存及拒绝场景 | 未通过验收 |
| WireGuard 握手、VPN/直连双路径 | 未通过验收 |
| 独立路由/DNS 恢复观察 | 仍待实现与验证；nil-settings ACK 不等于恢复 |

## 接下来的入口

下一步是本机开发签名、两个 target 的身份/能力/App Group/profile 核对，而不是继续重跑旧编译排障。已有本机签名配置时使用：

```bash
/bin/bash dev.sh provider-build --sign
```

该命令采用集成工程的 Release 构建和本机签名配置，并执行 codesign 结构校验；不自动安装/激活、不授权修改网络，脚本仍保留 signature_acceptance=NOT_RUN。签名未准备好时先完成本机准备，不使用 ad-hoc 或降低 XPC 身份要求替代它。普通 unsigned 产物不可安装或激活。

签名和权限检查通过后，按明确授权的本机受控流程先验证合成配置的保存与不联网交付检查及拒绝路径，再使用留在本机的有效配置完成首轮运行/取消/双出口/恢复验证。首轮仍为单 Peer、IPv4 数字端点、Include、无 DNS 字段；不自动删除不支持的配置字段。签名不是独立恢复观察、真实统计、长期运行质量等剩余开发工作的替代品。

## 本次仓库变更与回归边界

本次仅登记用户证据并同步 roadmap/acceptance-status；不修改产品源码、构建脚本、依赖锁、签名或权限配置。不重写历史失败证据；保留旧 48eee07 编译成功的独立覆盖范围。文档改动不使已通过的 unsigned 产物失效，不要求为文档同步重新编译。

本次没有执行代码测试、Mac 构建、签名、安装、激活、Keychain/系统偏好读写或网络操作；没有读取用户私钥/真实 VPN 配置。交付 main，回滚使用后续 revert，保留本机结果、缓存和锁文件。
