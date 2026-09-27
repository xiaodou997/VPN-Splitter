# ADR-EX-INT-02：有限前台路由执行候选

日期：2026-09-27。状态：工程候选，非 External 功能验收。继承 EX-INT-01 的 External 优先顺序、IPv4 Bypass 和不修改第三方客户端/DNS 的边界。S4-02/03、SEC-02/03 未关闭。

## 决策与权限边界

新增独立 `VPNExternalLease` 前台执行器：复用真实采集和 PolicyCore 预览，现场操作员使用系统管理员权限启动，并在真实 TTY 输入 APPLY。程序不自行提权、不安装 launch daemon、不通过无认证 socket/XPC 接收计划，不使用已弃用的通用授权执行接口。构建拒绝 root；原预览 GUI 继续只读，不会在升级后暗中取得写路由能力。

这先提供可联调的有限执行内核，不代替最终 SwiftUI + 经签名身份验证的最小权限 Helper。管理员直接执行自己审核的工程二进制是本次信任模型，不是应用调用方的代码签名认证。未来 GUI 不能自动包装此命令来跳过 SEC-02；服务安装、身份和撤销协议需要另行实现。没有更改 WG/LocalDev Keychain 权限或签名要求。

## 执行链

当前只读快照 → IPv4 Bypass 检查 → 最多 8 个 /24–/32 编译结果、总计不超过 2048 地址 → 30 秒内前台确认 → root 私有意图标记落盘 → 再采集及 GET 核对 → 单次 ADD → 匹配内核响应 → 完整路由读回 → 有限 active → 逆序复核/DELETE/缺失核查。

保留已有 DIRECT 条目，不获得删除权。每次 ADD 仅发送一次；不从 `route` 退出码推导成功。PF_ROUTE 响应检查 type/pid/seq、IPv4 目标/掩码/网关/接口和 errno，成功回执只存在于本进程的 socket context。RTF_PROTO2 是可识别标记，不是所有权凭证。完整快照不匹配、确认超时、取消或原 VPN/物理网络变化均停止，不重试、不重放旧网关。成功设置路由不是实际出口证据。

租约默认 60 秒、不续期，用包含睡眠时间的连续时钟检查；回车/EOF、SIGINT/SIGTERM/SIGHUP 请求停止。检查点的截止时间不是内核自动过期保证：系统调用、磁盘同步或进程挂起可能延迟清理，睡眠期间不能承诺后台撤销。

## 归属及恢复的真实限制

对自身 ACK 的回执持续监听同键 ADD/DELETE/CHANGE 等事件，检测到替换即永久撤销该回执。每次删除前再次 GET、比对快照并排空事件；scope/克隆/替换/不明响应/已知事件缺口均拒绝删除。部分应用失败仍清理可确认的先前项，不清理未知写入或借用项。

**BSD 路由接口没有本实现可用的原子 compare-and-delete 或不可伪造对象 ID。** 查询与删除之间的并发特权写入仍可能竞争；字段恢复原值的 ABA 或无法检测的内核通知丢失不能被全部排除。因此只可在无争用、现场授权且有恢复手段的测试环境使用，不宣称绝对“不删错”或已满足完整 EX-07。强制策略/企业管理/持续抢路由样本不支持。

意图标记固定在 root 专用 `/private/var/run/io.github.xiaodou997.VPNSplitter.ExternalLease`，目录 0700、文件 0600；openat/no-follow、类型/归属/硬链接检查、flock、写前同步和 inode 复核。锁不删除。标记只存候选地址和静态事件，不含密钥、密码、原 VPN 配置或浏览记录。它提供同次系统启动内的崩溃核查，不承诺跨重启或断电持久性。

超时未知写入、清理拒绝、日志失败或进程被强杀可能遗留路由；标记阻断后续新写入。重启工具只能 audit，**不能从磁盘记录恢复删除权**。只有候选及更具体路由在所有 scope 均不存在，才可清除该标记；否则保留并人工审核，不自动删除路线、扫库或重置 VPN。部分/损坏日志也不自动清空。

## 原始接口核对与证据

只参照公开接口自行实现，不复制 route 工具：Apple [route.tproj/route.c](https://github.com/apple-oss-distributions/network_cmds/blob/97e27e6244c16d399bfeb254315ddc5828711c56/route.tproj/route.c) 的 sockaddr 使用 4 字节对齐；结构体大小使用本机 SDK sizeof/offsetof，不把测试替身布局写死进产品。Apple [rtsock.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/rtsock.c) 的 RTM_DELETE 调用与本次并发限制分开记录。公开源码不能证明用户安装内核的具体行为。

本批实际执行和 NOT RUN 见 [证据](../evidence/ex-int-02-foreground-route-lease.md)。新的本地测试替身不是 Darwin ABI 或路由权限验收；首轮真实联调必须另收 VPN/直连新连接、停止后路由及 DNS 对照，不重复把旧 S0 样本当新工具通过。
