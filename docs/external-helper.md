# External 控制 App / Helper 开发入口

EX-INT-03B/03D 已有从已保存方案、原生身份验证到受限会话/原路由事务及恢复核查的调用代码；不是已通过系统验收的日常版。旧 `external-run` 仍能使用规则管理，其 ad-hoc 身份不能注册或调用特权 Helper。本页不要求重做旧网络实验、不恢复 WG 签名。

## 当前安全入口：只测试、只构建

在现有项目中以普通用户执行：

```bash
git pull --ff-only && \
/bin/bash dev.sh external-helper-test && \
/bin/bash dev.sh external-helper-build
```

测试包含新的 ExternalControl 完整包 Debug/Release 和 tests/external_helper；模拟系统服务/对话框不会注册 Helper 或修改路由。构建同时编译真实 ExternalPreview 和 VPNExternalHelper，打包为独立 VPN-Splitter-ExternalControl.app，检查 arm64、重签及严格校验，最后输出哈希。默认摘要：

```text
schema=external-helper-build-v1
compile=PASS
execution=NOT_RUN
network_settings=NOT_APPLIED
helper_installation=NOT_REQUESTED
signing=ADHOC_NOT_AUTHORIZED
route_trial=DISABLED
```

默认产物仅用于编译检查，不安装或激活。构建器不会下载依赖、打开 App、执行产物、提权、修改 /Applications 或运行 launchctl。无需清缓存、锁或旧恢复标记。旧 LocalDev、前台执行器和 WG 入口保留。

## 签名联调候选（不是当前必须操作）

准备好本机可用的 Apple 代码签名身份时，构建器接受成对的 `--identity` 与 `--team-id`。两个 ID/Team 都会独立核对；不输出私钥、profile 或 VPN 配置。签名不是公证或系统批准，不能把构建 PASS 当成可发布。

Developer ID 模式要求主 App 和内嵌 Helper 均带 Apple 安全时间戳；构建后会拒绝缺失时间戳的产物。本机一份签名候选的 Apple 公证与票据验证已单独完成，见 [Helper 签名/公证证据](evidence/ex-int-03b-helper-signing-notarization.md)。默认 ad-hoc 构建没有系统服务授权能力。

```text
dev.sh external-helper-build --identity <本机签名身份> --team-id <10位团队ID>
```

这仍是禁止路由写入的候选。显式 `--route-trial` 只能和真实身份参数一起使用，编译有限写入分支，不会安装或执行。首次 route-trial 之前，应集中完成签名身份正反测试、服务批准/撤销和原生路由自动撤销验证；未经批准不得把它用于日常分流或远程唯一控制通道。

服务联调时使用本次精确控制 App（不是旧 ExternalPreview），由本机操作员将其放入 /Applications，再打开页面并点击“申请系统授权”；系统要求管理员批准。不得用 sudo 启动 GUI，不禁用 Gatekeeper/SIP，不直接加载裸 Helper。控制 App 与 Helper 拒绝 ad-hoc 或错误团队/ID；身份检查失败不要降低要求。

## 已接入的页面流程

保存并选择方案 → 检查服务/申请系统授权 → 用已保存方案进行 Helper 预检 → 核对实际目标/网关/接口提案 → 单独确认 → 应用有限 60 秒分流 → 停止/查看真实诊断。

prepare 与 apply 前，页面重新读本机方案文件比较版本与完整内容；Helper 自己重新读取网络并在原生事务启动时复核基线，消息不能指定任意网关或接口。预检只保留 15 秒一次性票据；注册成功不会自动准备或应用。普通签名构建 canApply=false，不能通过复选框绕过。

已应用只表示原生添加确认和读回通过；实际 DIRECT/VPN 流量另验。停止返回闭合/零回执及快照对照，不等于全系统或 DNS 行为恢复。配置变化、睡眠、心跳丢失、控制台用户变化或连接断开会请求停止；同步系统调用和进程崩溃仍可能让清理延迟/失败。

遇到 recoveryRequired、失联或清理不明，不重试应用、不注销后强行重装、不 rm 标记或 flush 路由。现有标记会阻断新的 Helper 会话；当前未提供跨进程重建删除权或 GUI 一键恢复。使用已有受控审计/人工恢复流程，不能把程序重启当成已恢复。无未确认会话时，页面注销会先做服务端 quiesce，再请求系统注销；不会删除规则文件或恢复标记。

## Recovery UI（03D）

Helper 启动发现旧 active marker 时继续锁定新会话。控制 App 可执行“核查恢复状态（只读）”：Helper 读取既有 root 私有记录、重新采集当前路由，只返回候选总数和仍存在/歧义数量，不回传真实地址。

只有一次核查结果为“候选存在记录，但当前候选及更具体路由均未发现”时，页面才开放“重新核查并清除恢复标记”。清除动作再次读取同一 marker 并重新采集网络；第二次仍为零残留时只删除本工具 marker。它不调用 RTM_DELETE、不改 DNS、不删除锁文件，也不会把旧 marker 转成路由所有权。

若第二次观察出现候选/歧义，marker 保留，页面继续 recoveryRequired；没有“一键强删”。人工恢复仍只在既有受控流程中进行。

## 待验收

新的 Mac 完整构建、真实双向签名/XPC、管理员批准、客户端退出/失联、Helper 启停、实际路由添加与自动撤销均未由离线回归证明。03A 的用户验证通过只覆盖此前反馈范围。OpenVPN 导入尚未实现；不把本批当成完整 v0.1。
