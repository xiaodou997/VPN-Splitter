# LocalDev：本地策略、配置与凭据开发版

当前批次 **LD-02B**：在编辑修复和 WireGuard 结构导入基础上增加 Keychain 凭据保存、重新导入、移除/删除与可重试清理。不是可连接的 VPN。新 macOS 构建、Keychain 与 GUI 仍待真机验证；旧版用户启动成功不是新版验收。[本轮指南](localdev-keychain.md)、[证据](evidence/localdev-wireguard-02b.md)、[ADR-010](adr/ADR-010-localdev-keychain-transactions.md)。

## 更新与打开

条件：macOS 26+ / arm64、完整 Xcode / SDK 26+。本地 ad-hoc 签名，不需要 Team ID 或 VPN 描述文件。开发签名仍按 ADR-007 暂停。

本次已将 UI 修复、WireGuard 结构导入和 Keychain 三批改动统一纳入 `main`。之前的补丁和 ZIP 都不需要下载或应用；没有安装中间版本也可以直接更新。先保存并完整退出旧程序，在仓库根目录执行：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash tools/localdev/build.sh run
```

有本地未提交修改或分支分叉时先保留工作，不 reset / clean / force 覆盖。Git 更新只改变源码，不迁移用户数据；数据格式变更发生在应用内确认保存时。最新执行与未执行项见 [main 整合证据](evidence/localdev-main-integration.md)。

日常只运行 `/bin/bash tools/localdev/build.sh run`；只构建用 `build`。旧 S1 preflight / unsigned 不需重跑，development 继续暂停。独立目标不嵌入扩展，不安装到 Applications，不申请 root，不修改网络。产物日志仍在 `.local/localdev/`，不要整体上传。

成功终端应有 `schema=localdev-build-v1`、`exit_code=0`、`network_settings=NOT_APPLIED`、`extension_activation=NOT_REQUESTED`。窗口顶部应显示 **本地开发模式：不接管网络** 和 **LD-02B**。构建成功与实际窗口/Keychain 交互须分别记录。

## 日常流程

选择/新建策略或导入 `.conf` → 编辑规则 → 检查结果。主页面保留“规则 / 检查”，开发测试控件、技术路由和配置结构折叠展示。“设置”编辑名称与“仅指定目标走 VPN / 除指定目标外走 VPN”；模式只改默认出口，不改已有规则动作。

规则编辑在独立窗口里显式保存；开关、排序在无编辑窗口时立即保存。编辑窗口打开时不能旁路修改或切换；保存比较原始策略，拒绝旧副本覆盖。取消有修改时需继续/放弃，保存失败保留输入。退出也检查未保存编辑，不保证强退/崩溃保留未保存输入。

删除规则/策略需确认，无撤销。保存、切换、删除和重新检查会使旧预览失效。first-match 顺序、禁用草稿、未支持规则拒绝逻辑不变。模拟状态不等于认证或真实连接。

## 凭据操作

首次导入默认只保存结构，勾选并确认才保存到 Keychain；报告不会显示密钥。展开 WireGuard 区域可手动检查 Keychain 读取；“已关联”不表示本次读取/认证通过。菜单支持重新导入、仅移除凭据、移除结构及删除策略。后两项先解除引用再清理；失败显示待清理并可重试，不在启动时自动删。

重新导入保留名称、策略/规则 ID、顺序、默认出口；新凭据先写入验证，再替换引用，旧项最后清理。取消/失败不默默把旧凭据改写为新凭据。详细流程和合成验证见 [Keychain 指南](localdev-keychain.md)。原 `.conf` 始终保留，不上传真实材料。

## 能力与边界

| 已提供代码 | 尚未验证 / 实现 |
| --- | --- |
| 配置/规则编辑、结构导入、局部并发保护、Keychain 适配与事务恢复 | 本轮 macOS SDK / Keychain / GUI 真机验证，完整配置参数编辑 |
| PolicyCore IPv4 first-match、配置中的端点/DNS/接口/Peer 范围检查 | 物理拓扑发现、Endpoint DNS 解析、真实出口探测 |
| 本地 Keychain 引用与读回校验入口 | 正式扩展共享、真实 WireGuard / OpenVPN / External 执行 |

DOMAIN、后缀、IPv6、REJECT 仍只可保留草稿，启用未支持项阻止检查。IPv6 未覆盖，无系统级 Kill Switch。Keychain 保存与读回不是 VPN 认证。无 DNS 请求、路由写入、扩展激活或新 VPN 权限。

## 数据与恢复

位置仍是 `~/Library/Application Support/VPN-Splitter-LocalDev/workspace.json`。旧 v1/v2 可读；结构导入至少 v2；凭据事务的准备阶段升级 v3，即便其后授权失败。普通 JSON 只有规则/结构/随机引用/待清理引用，无密钥或原始配置。旧程序拒绝 v3，不手改版本回退。

目录 0700、JSON 0600，原子替换与错误拒绝保留。启动损坏/未来版本/无法读写时不自动清空。私有 workspace.lock 是本版 advisory 锁，退出释放但锁文件保留；不允许与旧版并发写，不删除锁文件来绕过。不保证对抗同用户竞态、掉电或备份回滚导致的引用遗失。

有活动/待清理凭据时不要重置工作区或恢复旧 JSON 来回退源码；那可能留下孤立 Keychain 项。本批不扫描/批量清理，归属不明保持报错。先保留原 .conf 和当前可读版本。规则/结构可能私密，不上传 workspace、授权材料或全量 .local。

## 回归与人工验证

```sh
/bin/bash tools/localdev/test.sh
```

Python 仅用于开发测试。合成 `synthetic-ipv4.conf` 与 `synthetic-reimport.conf` 的导入、读取、重导入和删除清理先在 Mac 验证，再考虑真实配置。同时复验旧版的编辑取消、排序、保存失败和 Command-Q/菜单/Dock 退出。没有原生 Keychain 通过证据前不关闭 LD-02B 的真机项；S1-03、S0–S5 门槛也不因本轮代码交付而关闭。
