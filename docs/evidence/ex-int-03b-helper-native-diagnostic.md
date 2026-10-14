# EX-INT-03B：系统批准与首次 XPC 诊断

日期：2026-09-30。基线 main `0bbfb36`。关联 EX-INT-03B/03D、T-E06、T-U01。当前候选仍为 `route_trial=DISABLED`。

## 真机证据

用户在已公证的 External Control 中依次报告 `notFound`、注册后的 `requiresApproval`、系统批准后的 `enabled`（USER_REPORTED）。独立 `launchctl print system/io.github.xiaodou997.VPNSplitter.ExternalHelper.v1` 确认系统已注册服务，首次恢复核查后服务进入 running，启动次数 1，没有退出。日志显示双方设置了预期的代码签名要求、Helper 接受了控制 App 的连接。这些事实不等于应用协议往返已完成。

用户点击“核查恢复状态（只读）”后报告 `操作未完成：unavailable`。尚无成功的 hello/recoveryAudit UI 结果；不标记真实双向认证、恢复核查或 Helper 分流通过。没有请求 prepare/apply，没有改变路由或 DNS。

## 诊断变更与验证

客户端把原有通用 unavailable 拆为 serviceNotEnabled、channelMissing、requestInFlight、proxyUnavailable，分别定位服务状态、通道、并发请求与协议代理转换。签名要求、root UID 检查、超时和失败关闭行为不变，不自动重试。

- `external-helper-test`：ExternalControl Debug/Release、14 项 Python/原生合同测试通过。
- 新增诊断场景后 `tests/external_helper/test_client.py` Debug/优化构建通过，覆盖上述四类失败及不发送/不重复发送请求。这里的系统接口为替身，不是实际签名验收。
- 2026-10-01 继续收窄真实 XPC 失败面：客户端不再把 Foundation 的代理错误统一折叠为 disconnected，而是区分 code-signing requirement 拒绝、interrupted、invalid、reply invalid 与其他 transport；中断/失效 handler 也保留各自类别。没有自动重试、没有放宽签名要求、没有新增任何路由/DNS 写入。对应原生客户端替身回归新增五类错误场景；Mac 真机只读复验仍待执行。
- 同日新增独立“测试 Helper 通信（只读）”入口：只执行已签名客户端 connect/hello/root 对端校验与 status 往返，随后立即关闭通道；不读取恢复 marker、不 prepare/apply、不创建路由事务。这样可把 XPC/身份问题与 Recovery 逻辑分开验收。UI 模型替身回归新增 probe 场景；真实系统结果仍待本机复验。
- 本机忽略目录中的匿名 NSXPC 实验完成 hello→第二次请求；身份与服务注册使用本地替身，不连接特权服务，不能作为 Helper 验收。
- Developer ID 原生构建通过，路由试验禁用。候选 `.local/external/control.c1wj8svq/VPN-Splitter-ExternalControl.app` 为避免同时更换服务端，已复制当前安装版的原 Helper 二进制，并重新签名主 App、严格校验通过。
- 新候选公证最初因既有 profile 无法读取而阻断；用户在本机重新保存凭据后，提交 `e68185c3-0fbb-4893-96a1-87983c0366a2` 返回 Accepted，staple/validate 通过。归档 SHA-256：`978f531283bb2b8b97a92f0a70c7fd0d497b4be3637fdafbec646f19b5b6821b`。
- 普通权限覆盖安装被系统拒绝，随后交由用户在终端管理员更新。独立检查确认 `/Applications` 下控制 App、Helper、签名资源与候选完全一致，strict codesign 和公证票据验证通过；Helper 二进制仍与更新前相同。新控制 App 已启动，待用户反馈只读复验。

当前根因未定位。此提交提供诊断能力，不宣称修复首次 unavailable；下一步取得明确错误类别，再针对性修复。旧版本签名/公证成功证据保留。

## 恢复页结果显示修复（backup 线）

用户在诊断版点击只读核查后报告“尚未应用；请用已保存方案重新预检”。源码确认 `.idle` 回包没有更新 message，可能继续显示旧文案；另一个确定问题是断连回调 invalidate 会改变 generation，使等待中的错误被略过。两者都不能凭旧文案判断通信成功或失败。

修复让 idle/noRecovery 显示明确结果，并将断连原因传给界面，在撤销待处理状态后保留安全错误码。新增模型/真实客户端结合替身的成功审计、断连提示回归；调整测试代理失败模式编号，避免与既有恢复故障模式冲突。完整 external-helper-test（Debug/Release 和 14 项合同测试）、Developer ID Mac 构建通过。签名及 root UID 要求不变，路由写入仍禁用。

候选 `.local/external/control.hstd5sk8/VPN-Splitter-ExternalControl.app` 保留当前已安装的 Helper 二进制；Apple 公证提交 `2b9cb5a9-3223-4581-a559-1194f5329bd4` Accepted。尚未安装此界面修复版，先请用户查看现有诊断版分流会话中的实际回包状态。真实协议成功仍待反馈，不能用源码推断填作 PASS。

## 修复版真机回包（backup 线，USER_REPORTED PASS）

用户以管理员权限完成更新后，独立比对安装版 App、Helper、签名资源与 `control.hstd5sk8` 候选相同，strict codesign 与 stapler validate 均通过。启动新版后，用户点击只读核查，报告：

> Helper 只读核查完成：当前没有待恢复会话（noRecovery）。未应用分流。

该 UI 文案仅在收到 idle/noRecovery 回包后显示；调用路径先完成带双方签名要求的 hello、客户端验证服务端 root UID，再发送 recoveryAudit。因此本次真实认证连接与 hello→recoveryAudit 往返为 USER_REPORTED PASS，独立 launchctl 同时确认已注册 Helper 仍运行、启动次数 1、未退出。noRecovery 表示服务当前没有待恢复会话；它不是对全系统路由进行扫描后的零残留证明。未发送 prepare/apply，路由能力仍禁用。

首次旧版 unavailable 的历史原因没有被此次成功反向证明；本轮确定修复的是成功回包不更新文案及断连错误被覆盖。下一步验证查询→quiesce→SMAppService 注销；签名拒绝反例、Helper 路由会话与异常恢复仍待验收。

## 安全注销闭环（backup 线）

用户执行设置页“注销 Helper → 查询并注销”后，检查状态为 `notRegistered`（USER_REPORTED）。独立系统检查：launchctl 返回 113 / Could not find service，且 pgrep 未发现 VPNExternalHelper 进程。因此本次注册→系统批准→认证只读往返→查询/quiesce/注销→服务与进程退出闭环通过。注销未删除规则或恢复记录，没有路由写入。

本轮结束状态为 Helper 未注册；后续原生 Helper 测试需要再次注册/批准。仍未验证错误签名客户端被拒绝、Helper 实际路由会话、60 秒到期、睡眠/切网/VPN 重连等场景，不能标记 External MVP 完成。

## 2026-10-13 真机定位：协议代际不匹配（非签名/非 XPC 传输）

在 `bb60cf3`（外加 panel 替身修复 `bf3b91d`）上完成本机复验：

1. 修复一处先行存在的离线回归失败：`tests/external_helper/test_panel.py` 的 recovery 场景复用替身 mode 5，与 `0b46271` 引入的“mode 5 = 代理不可用”冲突，apply 未发出即前置失败；改用空闲 mode 11 后 `external-helper-test` 全绿（Swift 26/26、Python 14/14）。
2. Developer ID 构建通过；按既有做法保留当前安装版 Helper 二进制、重签主 App，strict/团队要求/安全时间戳校验通过，安装至 /Applications（无 quarantine，未公证；普通权限替换成功，旧版备份在 `.local/external/installed-backup-20261013.app`）。
3. GUI 点击“测试 Helper 通信（只读）”：注册状态 enabled，结果为 `操作未完成：authentication`。系统日志确认 Helper 接受连接、完成代码签名检查，连接由客户端正常关闭。
4. 一次性只读探针（同标识 Developer ID 签名，hello+status，无规则/无写入）逐级打印：对端 euid=0 通过，但 hello 回包为 `refused/invalidRequest`。改用 backup 线协议（每请求携带递增 sequence，hello=1、status=2）后同一 Helper 返回 `idle/none` + `idle/none`，PROBE=PASS。

结论：签名、root 校验、XPC 传输与 Helper 服务全部正常。真正原因：**当前安装的 Helper 是 backup 线 sustained 构建，要求每个请求携带 sequence；main 线（`bb60cf3`）客户端无 sequence 字段，hello 被拒为 invalidRequest，客户端把 hello 的 refused 统一映射为 `authentication`**。9 月 30 日 USER_REPORTED PASS 的往返发生在两条线协议一致时。

待办：backup 线（保留在 `backup/main-local-31commits-f2d3690`）的 sequence/sustained 协议与面板修复正在 `integration/ex-int-03b-protocol-v2` 分支整合进 main，统一为协议 schema=2 + `.v2` 服务名（ADR-EX-INT-06）；从同一 merged commit 重建 App 与 Helper 后复测探针与 GUI 只读入口。探针二进制与源码为 /tmp 一次性产物，未入仓库、未保留。
