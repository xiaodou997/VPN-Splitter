# External 前台执行候选：先构建，后现场联调

EX-INT-02 不是已经可用的一键 GUI Helper。原 `external-run` 仍只读；新增执行器带真实路由写入代码，仅适用于已授权、无路由争用、可本机恢复的短时工程测试。不得在企业强制 VPN/MDM、远程唯一控制通道或不能接受残留的机器上运行。限制与删除竞争见 [ADR](adr/ADR-EX-INT-02-foreground-route-lease.md)。

## 1. 当前应执行：没有网络副作用的检查

```bash
git pull --ff-only && \
/bin/bash dev.sh external-execution-test && \
/bin/bash dev.sh external-executor-build
```

普通用户构建，不用 sudo，不需要 Go、WG 签名、Network Extension 或开发证书。构建输出精确 Executable 路径与 sha256，只做编译/本机 ad-hoc 签名，不运行、不安装 Helper。本批开发环境没有 Apple SDK 编译结果，先反馈这一步；不要把离线测试通过当作允许真实 apply。

## 2. 后续受控联调流程（不是自动执行指令）

先核对本机原生构建、测试权限、原 VPN 样本和恢复办法；审核二进制来源及输出 hash。启动该次精确产物，不运行旧副本或未经审核的脚本；不要用管理员权限构建整个项目或打开预览 GUI。原 VPN 由原客户端保持连接，不要求导入它的密钥。

`inspect <IPv4/CIDR> ...` 只读。只有独立 `apply <IPv4/CIDR> ...` 才可能写路由，它要求本机操作员自行取得 OS 管理员权限、stdin/stdout 是终端、并在 30 秒内输入 APPLY；不会代用户提权。网关和接口由实时观测取得，不接受外部参数覆盖。最多 8 个编译后 /24–/32 结果、2048 地址；超限整体拒绝，不裁剪。

应用后保持前台，按回车或 Ctrl-C 请求结束；默认 60 秒截止且不续租。默认路由、第三方配置和 DNS 不写。使用本机授权的 D/V 目标新建连接分别验证物理接口和原 VPN，不能仅看网页打开、ACK 或路由存在。不要用文档示例地址充当真实验证目标，也不要上传真实配置或整个本机网络日志。

退出摘要 `state=closed` 只表示本工具没有剩余已知回执/未知写入。`snapshot_comparison=unchanged` 只是观察到的路由、接口、物理服务和 DNS 地址集合对照，不是 DNS 查询行为、全系统恢复或未来状态保证。租约到期会打印 expired 并可能返回非零；需同时看清理状态，而不是只看进程退出码。

写入前若输出 `failure=networkChanged`，继续保持拒绝；不要把 `state=closed` 当成已应用。新版会另打印 `snapshot_change=`，仅列接口/物理路径/DNS 是否变化及路由增减条数，不含真实地址。该诊断用于判断下一步查哪个网络类别，不授权忽略变化后直接重试。

## 3. 出现 recoveryRequired 时

停止继续尝试，不删除锁/active 标记、不 flush 路由、不停掉别人的 VPN。`audit` 只读检查本工具 root 私有标记和当前候选残留，不取得删除权。日志放在 `/private/var/run/io.github.xiaodou997.VPNSplitter.ExternalLease`，只供本机管理员审核；不是跨重启/断电恢复机制。

`clear-absent-marker` 只在所有候选及更具体路由在全部 scope 均不存在时移除本工具标记；不写网络。残留存在、日志损坏或归属不明时不会清理，也不应通过移除标记强行继续。进程崩溃/SIGKILL 后不能靠重新启动工具自动删除旧路由，须现场人工核对和既定恢复流程。

只读 `audit` 对确实不存在的 active marker 报 0 个候选；这不是“已恢复旧路由”的证明。`clear-absent-marker` 在无 marker 时仍拒绝清除。目录/锁权限、符号链接或损坏 marker 继续作为日志故障处理，不能用零候选报告掩盖。

后续产品工作仍包括签名身份验证 Helper、GUI 应用/撤销、完整异常恢复及真实双路径验收。OpenVPN 导入保持提前排队，本批没有新增 OpenVPN 支持；WG 已有原生构建证据保留且不要求恢复签名。
