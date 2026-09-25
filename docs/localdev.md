# LocalDev：本地策略、配置与凭据开发版

当前批次 **LD-03A**：WireGuard 参数编辑与凭据安全换绑；保留批量 IPv4 规则、搜索、结构导入及 Keychain 恢复。用户已反馈 LD-02C 显示正常，记为该布局的 USER_REPORTED 结果，不等于新版参数窗口、真实 Keychain 或 VPN 已验收。[本轮证据](evidence/localdev-03a-parameters.md)、[参数指南](localdev-wireguard-editing.md)、[ADR-011](adr/ADR-011-wireguard-parameter-editing.md)。

## 更新与打开

条件：macOS 26+ / arm64、完整 Xcode / SDK 26+。本地 ad-hoc 签名，不需要 Team ID 或 VPN 描述文件。开发签名仍按 ADR-007 暂停。

只从 main 更新，不需要历史补丁或 ZIP，也不需要依次运行中间版本。先保存并完整退出旧程序，在仓库根目录执行：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash tools/localdev/build.sh run
```

本地修改冲突或分支分叉时停止并保留工作，不 reset / clean / force。Git 拉取与构建不迁移用户数据。LD-03A 不新增工作区格式或凭据记录版本。

成功终端应有 `schema=localdev-build-v1`、`exit_code=0`、`network_settings=NOT_APPLIED`、`extension_activation=NOT_REQUESTED`。窗口应显示 **本地开发模式：不接管网络** 和 **LD-03A**。这些日志不代替窗口或真实 Keychain 验证。

日常只运行 `/bin/bash tools/localdev/build.sh run`，只构建用 `build`。旧 S1 preflight / unsigned 无需重跑，development 继续暂停。独立目标不嵌入扩展、不安装到 Applications、不申请 root、不修改网络。日志在 `.local/localdev/`，不要整体上传。

## 日常流程

选择/新建策略或导入 `.conf` → 编辑规则或配置参数 → 检查结果。主页面是“规则 / 检查”；开发工具、技术路由与结构折叠显示。设置中的分流方式只改变默认出口，不改已有规则动作。

规则页支持批量添加和搜索。搜索仅筛选显示，检查仍使用完整策略，筛选中暂停排序。独立编辑窗口有保存/取消及旧副本覆盖保护；开关和排序在无编辑窗口时立即保存。删除有确认但无撤销。保存/切换/重新检查使旧结果失效；模拟状态不等于真实连接。详见 [批量规则](localdev-rules.md)。

已导入 WireGuard 的策略可展开结构区域点击“编辑参数”。本轮支持 Address、DNS IP、ListenPort、MTU、每个已有 Peer 的 Endpoint 和 PersistentKeepalive，保存前显示修改字段与结构预览。名称、规则、AllowedIPs、Peer 身份及密钥保持不变；范围/密钥变更用重新导入。保存后必须重新检查，不写回原 .conf。详见 [参数指南](localdev-wireguard-editing.md)。

## 凭据与恢复

首次导入默认仅保存结构；明确勾选并确认后才保存凭据到本机 Keychain。已关联不等于认证，手动读取检查也不代表隧道可用。重新导入保留规则和默认出口，先写入及校验新凭据再替换引用，最后清理旧项。[Keychain 指南](localdev-keychain.md)记录完整的导入/重导入/移除/删除与合成验证。

参数修改对仅结构策略不访问 Keychain；有关联凭据时在 vault 内保留原密钥创建新的参数绑定，验证后才关联和清理旧项。拒绝访问、格式错误或磁盘失败保留输入和恢复记录；编辑窗口可重试清理后重新保存。新参数已发布但旧项清理失败会明确提示，不回滚新引用。

参数编辑的退出提示只允许继续编辑或放弃，需保存时先回编辑窗口保存再退出；不在退出回调里启动异步 Keychain 写入。操作期间禁止重复保存和普通退出。强退/崩溃不保证恢复未保存输入。

工作区仍在 `~/Library/Application Support/VPN-Splitter-LocalDev/workspace.json`。旧 v1/v2/v3 可读取；结构导入至少 v2，首次凭据事务准备阶段使用 v3，即便随后授权失败。普通 JSON 只含规则/结构/引用/待清理引用，不含密钥或原始配置。旧程序会拒绝 v3，不手改版本回退。

目录 0700、JSON 0600；损坏/未来版本/读取失败时不自动清空。workspace.lock 为 advisory 锁，退出释放而文件保留，不删除锁文件绕过。归属不符、损坏或不可读的 Keychain 项不盲删，也不放宽 ACL 或回退明文。不要重置工作区或恢复旧 JSON 来回退引用；保管原 .conf 及当前可读版本。不承诺对抗同用户竞态、掉电或外部忽略锁的写入。

## 验证与边界

```sh
/bin/bash tools/localdev/test.sh
```

该入口只执行 AppCore Debug/Release 与离线合同检查，不打开 App、不访问真实 Keychain。新版原生窗口/授权行为仍需 [参数合成清单](localdev-wireguard-editing.md) 验证，不能拿 Linux 替身测试填补。

真实 WireGuard/OpenVPN/External、Endpoint DNS 解析、物理拓扑探测和实际出口均未实现。DOMAIN、后缀、IPv6、REJECT 草稿启用时仍拒绝检查；IPv6 未覆盖，无系统级 Kill Switch。保存格式正确也不代表配置约束检查或服务器认证通过。

首次真实 Managed 联调前恢复开发签名；当前不请求扩展授权或写入路由/DNS，不降低 S0–S5 门槛。原始配置、workspace、授权材料和日志可能私密，不上传公共仓库。
