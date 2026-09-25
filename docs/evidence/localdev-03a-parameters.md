# LD-03A：WireGuard 参数编辑与凭据一致性

日期：2026-09-25。基线：`a12aaaeaeb09019156e3420457a3cbd3b59cf50c`，tree `fb02ffa8c905819133ad091ae4ecca77fcffde40`。任务 LD-03A、S1-03 部分、S4-04 前置；测试 T-LD-A01–A06；Refs #1。决策：[ADR-011](../adr/ADR-011-wireguard-parameter-editing.md)。

## 用户反馈

本轮用户明确反馈“显示正常了，你继续推进吧”。记录为 LD-02C 顶部遮挡/显示的 USER_REPORTED PASS。用户没有提供新的系统/SDK 版本、逐项批量规则测试或 Keychain 结果，不补造这些证据，也不推广为 LD-03A GUI / Security API / VPN 验收通过。历史证据保留原执行归属。

## 新增代码

在现有单编辑事务中加入参数编辑，入口在导入后的 WireGuard 区域及策略菜单。接口地址、DNS 地址、ListenPort、MTU、每个已有 Peer 的 Endpoint / PersistentKeepalive 可编辑；复用导入解析和上限。预览列出修改字段、将保存结构和兼容性限制，不展示密钥。

参数映射逐项保留 Peer ID/顺序、AllowedIPs、预共享密钥标记和搜索域；其他策略字段不变。未支持的主机名/IPv6 等保留结构并继续阻止当前规划，不转成虚假的部分通过。原 .conf 不修改。

有关联凭据时，参数保存先写新随机引用的准备记录；以旧引用和旧结构读取并验证原 envelope，在 vault 内复制原始密钥与新结构到新记录，读回后再发布新引用，最后由界面显式清理旧引用。没有凭据时只保存结构。普通草稿保存入口拒绝参数类型，防止跳过换绑事务；原 Keychain 记录不就地覆盖。

保存进行中阻止重复操作、旁路编辑与普通退出。失败后把已持久化的恢复状态返回 UI，未保存输入仍在；编辑窗口内可明确重试清理，不需先丢弃输入。参数编辑的退出检查不启动异步保存，须先回编辑器保存或明确放弃。

## 本轮实际执行

环境：x86_64 Linux、Swift 6.2.1。Mac Runner 请求返回 tunnel_client_not_seen / 404，无法执行原生 SDK 或 GUI。本地重建的基线生产 Swift、AppCore 测试、项目和统一脚本已按远端 Git blob 核对；不以不完整替代算法参与测试。

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| 基线 AppCore Debug | PASS，152 tests | 新代码前执行 |
| 新版 AppCore Debug，warnings-as-errors | PASS，175 tests | 原 152 加 23 个参数测试函数，部分含参数化子用例 |
| 新版 AppCore Release，warnings-as-errors | PASS，175 tests | 同一测试集优化构建 |
| LocalDev Python 合同/编排 | PASS，59 tests | 原 51 加 8；不是 GUI 自动化 |
| 统一 tools/localdev/test.sh | PASS，exit 0 | 真实顺序执行上述 Debug、Release、Python |
| SwiftUI / Keychain 源码 parse、项目 plist、Bash 语法 | PASS | 非 macOS SDK 类型检查或签名 |

初次前台回归进程遇到工具执行超时；随后完整统一回归重新执行并得到 exit 0。超时运行不计作 Release 或完整入口 PASS。未单独重跑 PolicyCore 的 79 项独立测试，也未重跑 S0 / S1 原套件；依赖的 PolicyCore 生产源码完全不变。

复现：

```sh
/bin/bash tools/localdev/test.sh
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift Packages/AppCore/Sources/AppCore/KeychainCredentialVault.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh tools/localdev/test.sh
```

T-LD-A01：地址主机位与多值顺序、端点/端口/MTU/keepalive 语法与资源限制、off/空白、无变化、错误不回显输入。

T-LD-A02：Peer 身份/顺序/数量、AllowedIPs、PSK 标记、搜索域不变；原密钥 payload 完整复制；不允许普通编辑保存旁路。

T-LD-A03：仅结构保存不调用 vault，名称/规则/默认出口/其他策略保留；旧选择、基线、磁盘冲突阻止覆盖，取消保留输入；Linux 文件保存/重启读取往返。

T-LD-A04：新引用准备先于 vault，旧 envelope 元数据或归属不符、权限拒绝、missing、部分写入、最终磁盘保存失败、清理和清理确认失败的恢复；新旧活动引用不误删。凭据后端是可注入故障的替身，系统 Keychain 未参与。

T-LD-A05：兼容性限制仍阻止真实 PolicyCore 检查；保存新的端点与 VPN 显式规则冲突时拒绝，恢复参数后可重新检查。未发起网络探测。

T-LD-A06：UI 入口、单编辑事务、后台调用、busy 保护、退出不触发异步写入、编辑器内恢复、布局保持与无网络命令的静态合同。不是原生窗口行为证明。

## 未执行、权限与恢复

NOT RUN：LD-03A macOS SDK 构建、ad-hoc 产物检查、参数窗口实际尺寸/输入绑定/滚动/取消/退出；真实 Keychain 参数换绑、系统授权、重编译身份变化与错误恢复。前几批真实 Keychain 验收仍开放，用户显示正常不补齐这些缺口。

没有新第三方依赖、工作区或 envelope 版本、根权限、访问组/ACL 放宽、联网、路由/DNS 修改、扩展激活或正式 App/PacketTunnel 变更。沿用用户主动授权的本机 Keychain 服务，只查询已知引用，不枚举或批量清空。参数保存是配置持久化，不是服务器认证或隧道生效。

失败保持原策略及恢复记录；已发布新参数后的旧项清理失败不回滚新引用。强退、掉电、外部进程忽略 advisory lock 和同用户路径竞态不作强保证。保管原 .conf，不通过清空 JSON、手改版本、删除锁文件或恢复旧备份解决凭据问题。源码撤回用普通后继提交，不 force/reset/clean。

main 是唯一日常更新入口；指南见 [参数编辑](../localdev-wireguard-editing.md)。下一步继续连接生命周期准备和已有 Keychain 合成验收；首次真实 Managed 联调前恢复开发签名，目前继续暂停，不以参数可编辑关闭 S0–S5 门槛。
