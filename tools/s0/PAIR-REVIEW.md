# S0 配对复核与单目标实验准备

关联任务：S0-02；为 S0-03 提供准备材料。关联需求：EX-01/02/06、SEC-01。关联产品测试：T-E01、T-E04 的辅助观察，不是产品通过判定。

## 1. 已有 before / after 后，不再重复采集

在 PR #2 的 `feat/s0-readonly-baseline` 分支，使用已经生成的 `.local/s0/before.XXXXXX` 和 `after.XXXXXX`。无需 Python、Homebrew 或额外授权：

```sh
/bin/bash tools/s0/review-pair.sh
```

只有恰好一份 before 和一份 after 时才自动选取。多份时不会按名字/修改时间猜测，也不会删除旧证据；请使用原采集打印的两个目录**末尾名称**：

```sh
/bin/bash tools/s0/review-pair.sh before.XXXXXX after.YYYYYY
```

上面的后缀是占位符，替换成本机真实名称。不要把完整目录上传。阶段参数按 before、after 顺序，工具检查记录的采集区间没有倒序或重叠，但不能证明标签、时钟、同一台设备、网络稳定性和文件来源真实无误。

这是离线文件分析：不用 sudo，不读取当前系统网络状态，不发包、不改路由/DNS、不自动连接 VPN。不必为了运行复核再次断开/连接 VPN。若电脑期间切网或 VPN 重连，候选可能过时；实际修改前必须重新进行目标相关的现场检查。

## 2. 检查内容

原始快照必须完整、命令状态一致，相关目录/文件必须属于当前用户且为非符号链接，目录 700、文件 600。最多读取单文件 4 MiB；异常和不支持的输入报错，不修饰成成功。PARTIAL 快照需先本地检查原因，本版不会自动忽略失败项。

复核 numeric IPv4 路由：连接前是否有唯一 unscoped、UP、非 reject/blackhole、带网关的 enN 默认路由；连接后该默认路由是否保留；默认路由查询结果是否一致；两条 /1 是否为同网关、同 utun；是否有其他使用中的 IPv4 隧道路由。不是仅凭接口命名就认定真实物理路径，还交叉检查 hardware ports、接口 active/UP 和 IPv4 地址一致性。

DNS 和系统代理仅比较原始文本，`CHANGED_TEXT` 不等于语义一定变化，`IDENTICAL_TEXT` 不等于数据流量一定走该出口。扩展清单存在仅提示本地审查，不能确定谁接管流量；清单为零也不能证明没有系统/应用/MDM 强制策略。

## 3. 输出与隐私

结果新建在 `.local/s0/pair-review.XXXXXX/`，不会覆盖快照。

- `share-summary.txt`：固定字段和枚举，不含 IP、接口名、用户名、域名、MAC 或扩展标识。仅分享这个文件。
- `path-candidates.private.tsv`：通过格式校验的物理/VPN 网关和接口候选，仅留本机。不含可执行命令，不是写路由许可。
- `path-summary.txt`：中间枚举；`PRIVATE.txt`：限制说明。

与原采集相同，权限不能抵御同账号进程、ACL、备份或人为强制上传。分析结果没有签名，也不是不可篡改证据。请人工确认是在同一测试 Mac、同一预期网络条件下采集。

`pair_readiness=CANDIDATE_REQUIRES_LIVE_PREFLIGHT` 只表示这两个存档里存在一致的路由候选，可准备现场单目标实验。即使出现此值，`compatibility` 仍为 `UNKNOWN`，`actual_egress` 仍为 `NOT_TESTED`。`REVIEW_REQUIRED` 表示有歧义或缺少支持条件，不是工具应当强行修复的系统故障。退出码 0 表示完成分析，不是“允许添加路由”；必须读取枚举。

## 4. 下一关 S0-03：一个受控 IPv4 目标

配对复核不够证明路由可修改。正式测试必须满足以下条件，不使用旧快照直接执行 sudo：

1. 获得该网络/VPN 管理方允许，具备本机控制台和恢复条件；不要在唯一的远程控制连接上试验，也不关闭企业安全机制。
2. 在本机场景清单指定一个可授权观察的普通公网 IPv4 目标 D，以及一个应继续走 VPN 的不同服务 V。D 不得是 VPN Endpoint、物理网关、DNS 服务器、本机/局域网基础设施或维持当前远程会话的目标。没有受控服务时先准备测试环境，不默认使用第三方出口查询站。
3. 原 VPN 已连接。重新只读确认 D 的实际系统选路、物理网关的 on-link 路径、当前接口/地址，以及该目的是否已有 /32。记录现有 VPN/过滤组件与实际政策；观察到强制策略或路由争用就停止。
4. 先通过受控服务端日志/受限链路观察，记录 D 与 V 的现状。路径查询不是流量证据。普通浏览器访问还可能受系统代理、浏览器代理、DNS 缓存或已有 TCP/QUIC 会话影响。
5. 独立执行方案只为 D 增加一个临时 /32，不替换/删除第三方默认路由、不改 DNS，不借用别人已有的 /32 当作自己的。需要写入前的精确状态、成功记录、状态验证及归属确认后的撤销；相同路由可能被别人重建，字段相等不是绝对归属证明。
6. 验证 D 的新建连接确实变为 DIRECT，同时 V 保持 VPN 可用；撤销后再检查 D 回到原来路径且没有自有残留。失败或冲突不得循环抢路由。此阶段不承诺 IPv6 或已有连接迁移。

**本次提交没有实现步骤 3–6 的现场执行器，也没有给出可盲贴的写路由命令。** 候选数据用于减少重复采集与私有资料分享；现场目标/授权/归属确认没有完成时，不自动升级成特权操作。

## 5. 测试与资料

```sh
/bin/bash -n tools/s0/review-pair.sh
python3 -m unittest discover -s tests/s0 -p 'test_pair_review.py' -v
```

离线测试使用合成快照，覆盖普通/异常路由、不同隧道/网关、多快照选择、失败命令、时间倒序、私有输出、权限与符号链接。运行环境与用户回报证据见 [新增记录](../../docs/evidence/s0-mac-summary-and-pair-review.md)。不把这些测试替代 macOS 原生测试或 S0-03。

API/限制依据（2026-09-25 复核）：[Apple WWDC25 NetworkExtension](https://developer.apple.com/videos/play/wwdc2025/234/) 对路由强制与直接改路由兼容风险的说明；[Apple route 手册源码](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.8) 对 `get`、numeric 与 scoped 查询的说明。路线不变：Managed 采用 Network Extension，External 仍是受限验证路径。
