# EX-INT-02：用户报告新执行器只读检查通过

记录日期：2026-09-28。记录前远端 main：`eae389ca2f6fcd613c3bf831e7114ec5b76d7670`。关联 EX-INT-02、FIX-03～05；External 优先，WG 签名暂缓。本文只登记用户反馈，不关闭真实分流或恢复验收。

## 已报告的构建与测试

用户此前贴出 PhysicalLinkEvidenceTests 的完整 XCTest 汇总：12 项执行，0 失败。记录为 USER_REPORTED PASS。没有本轮完整 ExternalCore、ExternalExecution、Python 或 C 套件输出，不推导为全量回归；不从命令串推导未贴出的测试数量。

随后报告新执行器 `executor.8ecvh41b/VPNExternalLease` 的原生构建摘要：

```text
schema=external-executor-build-v1
compile=PASS
execution=NOT_RUN
network_settings=NOT_APPLIED
helper_installation=NOT_REQUESTED
sha256=b208243ddbe77e0077cdd436948879dcf458c58b8b34fe4cab5e35ddf975bded
```

该摘要登记为 USER_REPORTED 原生构建及脚本前置 arm64/ad-hoc 签名/严格验证流程通过。哈希由用户报告，助手未读取二进制复算。没有本地 commit、工作区差异、完整构建日志或源码指纹，不能声称产物与上述远端快照逐字匹配。

## 明确产物路径后，inspect 通过

用户先前通过 `$EXEC` 调用仍得到 physicalUnknown。本次打印变量确认它指向 `executor.ds7e1o56/VPNExternalLease`，并非新构建的 `executor.8ecvh41b`。这说明之前检查结果不能直接归给新产物；仅由目录名不能判断另一副本的准确版本。

用户随后绕过变量，以新执行器的完整路径运行同一个本机 IPv4 目标的 inspect。结果实际列出了一个物理接口、一个 VPN 接口线索，以及通过所观察物理网关的单个 `/32` DIRECT 提案，disposition 为 `wouldAdd`，末尾为 `network_settings=NOT_APPLIED`。

为避免把本机网络资料提交仓库，目标、网关、接口名与用户完整目录在本文不展开。输出关系概括如下，不是逐字终端转录：

```text
physical_interface=P
vpn_interface_hint=T
D/32 -> currently_observed_physical_gateway / P
proposal=wouldAdd
network_settings=NOT_APPLIED
```

证据等级：**USER_REPORTED PASS — 当前现场的只读采集、物理/VPN 路由线索识别与单目标有限计划检查**。本次成功说明新产物运行已越过此前 physicalUnknown 阶段，不代表任何厂商全量兼容或以后网络变化仍有效。

## 不升级的状态

inspect 不打开写入驱动、不创建 root 执行日志、不申请管理员权限，也不主动向目标发流量。wouldAdd 只说明拟添加，不是已添加。因此实际 PF_ROUTE ADD/DELETE、直连/VPN 双路径、内核竞争、断线/睡眠/崩溃恢复与 GUI 授权 Helper 均未由本次反馈验收。构建摘要的 execution=NOT_RUN 是构建当时状态；后续 inspect 是独立的已执行只读步骤，不能混为执行器从未运行。

下一项是经明确现场授权的单目标短时应用、内核响应/读回、正常停止与独立前后观察。使用刚通过检查的精确产物；无须为本文再构建。应用会重新采集，不能把旧 inspect 当作写入权限或缓存网关。只在有本机控制及恢复办法、没有企业强制策略或路由争用的环境中操作；不靠远程唯一控制通道测试。

真实 apply 需管理员直接启动并在终端核对新预览、输入 APPLY。默认 60 秒不续租；回车或 Ctrl-C 请求停止。不改原 VPN 配置/默认路由/DNS；强杀、挂起或崩溃不能保证撤销。若出现 recoveryRequired 或结果不明，停止新写入，保留恢复标记，仅先 audit，不能用 flush、盲删路由、删除锁或标记来强行继续。详见 [执行边界](../external-execution.md)。

`route_add_ack_and_readback=PASS` 仅表示添加响应和读回，`state=closed` 与 `owned_receipts_remaining=0` 仅表示无剩余已知回执/未知写入；`snapshot_comparison=unchanged` 是有限系统观察对照，不是全系统、DNS 查询行为或实际出口保证。真实分流仍需分别观察 D 新流量与原 VPN 内 V 流量。

## 本次仓库操作

只新增本文，未修改产品、构建脚本、测试、依赖或权限；未执行新的编译、测试、inspect、apply、系统采集、服务安装或凭据读取。旧测试失败、旧原生构建成功与 S0 实测证据保留。不需要重新下载更新包、重建或清空本机缓存。main 追加提交交付。
