# S0：只读网络基线工具

对应任务：S0-01、S0-02。需求：EX-01/02/04/06、SEC-01。关联产品测试：T-E01、T-E04；本工具及其离线测试不代表这些真机测试通过。

本目录是开发验证工具，不是 VPN 客户端、路由 Helper 或正式产品 CLI。产品仍按 Swift / Network Extension 方案推进。

## 安全边界

只读取接口、IPv4/IPv6 路由、DNS、系统代理、VPN 服务和扩展清单。使用固定的系统命令与参数；不调用 sudo、不修改路由/DNS、不连接或断开 VPN、不读取配置/钥匙串/进程环境，不运行 ping/curl/抓包或公网出口查询。可选目标仅接受最多 16 个规范的数字 IPv4 地址，用 `route -n get` 查询系统选路；不接受主机名，不发起主动连接。

原始输出包含 IP、MAC、域名、服务名、扩展标识等敏感信息，**并未自动脱敏**。它们仅写入仓库内被忽略的 `.local/s0/`：父目录必须属于当前用户、非符号链接且权限 700；新快照目录 700，输出文件由 umask 077 限制为 600。不会修改已有目录的权限，也不会覆盖旧快照。文件系统 ACL、备份和同账号进程不在这种权限隔离的保证范围内。

`.gitignore` 不是安全边界，不能抵御强制添加或把文件复制到别处。不要提交、上传或粘贴整个原始目录。不要将真实配置和采集结果放进公开 PR、Issue、测试夹具或 CI。

## 在测试 Mac 执行

目标为 macOS 26+ / arm64；脚本使用 Bash 3.2 兼容语法，但本次仅做了 Linux 离线测试，原生 macOS Bash/awk/路径仍需首次运行验证。运行采集本身不需要 Python、Xcode 或 Homebrew；Python 仅用于开发者离线测试。

在仓库根目录，先关闭**被测 VPN**，保持测试网络和其他软件状态不变，执行：

```sh
/bin/bash tools/s0/collect-network.sh before
```

然后正常使用原客户端连接被测 VPN，再执行：

```sh
/bin/bash tools/s0/collect-network.sh after
```

如果需要记录指定目标的系统选路，在两次命令后加同一组真实 IPv4 地址。目标应来自本机、经授权的场景清单；不要把示例网段当成实际业务目标。查询路由仍不能证明流量实际走了该出口。

结束本轮观察并正常断开被测 VPN 后，可执行：

```sh
/bin/bash tools/s0/collect-network.sh reverted
```

这里的 reverted 仅是用户选择的快照标签；工具没有实施任何修改，也不执行“恢复整个路由表”。后续 S0-03 的例外应用/撤销需要独立授权与执行方案，本脚本不包含写路由命令。

每次打印唯一目录路径和可分享摘要。只有 `share-summary.txt` 采用固定字段和枚举输出，不回显 IP/MAC/域名/厂商/用户名。原始文件需本地人工审查与脱敏；不要用正则替换几个 IP 就声称完全匿名。

## 快照文件与含义

- `commands.tsv`：固定命令 ID、OK/FAILED/TIMEOUT/UNAVAILABLE 和退出码。
- `capture-state.txt`：IN_PROGRESS、CAPTURED、PARTIAL 或 INTERRUPTED；这是采集状态，不是网络兼容结论。
- `routes_v4.txt`、`routes_v6.txt`、`dns.txt` 等：本机原始输出；同名 `.stderr.txt` 记录错误。
- `started-utc.txt`、`finished-utc.txt`：采集区间。命令顺序执行，不是原子网络快照；网络期间变化时需要重新采集。
- `share-summary.txt`：采集失败数、IPv4 路由迹象、UNKNOWN 兼容状态和未测试的实际出口。

脚本对每条采集命令设置约 10 秒的终止阈值，另有终止宽限/调度时间和文件大小限制。超时/命令失败保留错误，不伪装成空配置。无 IPv6 默认路由也可能导致 PARTIAL；这不自动代表 VPN 故障。返回 0 表示所有采集命令返回成功，2 表示存在未成功项；64/69/73/74/77 表示参数、环境、目录、存储或权限问题。仍需读取状态清单，而不是只判断退出码。

## 路由迹象的保守解释

`route-hints.awk` 只接受 numeric IPv4 netstat 输出，并按实际 Netif 列定位接口；忽略 scoped、非 UP、reject/blackhole 路由。两条 `/1` 必须出现在相同 utun、相同 gateway，才报告 SPLIT_DEFAULT_PAIR。不同网关/接口、残缺半边或多候选不能拼成一个可用 VPN。

输出值为 SPLIT_DEFAULT_PAIR、TUNNEL_DEFAULT、MULTIPLE_CANDIDATES、INCOMPLETE_OR_MIXED_PAIR、NONE_OBSERVED、UNKNOWN。NONE_OBSERVED 只表示没有发现工具认识的模式，不表示没有 VPN。UNKNOWN 或识别成功都不能证明/排除过滤器、Kill Switch、MDM、按流量路由或其他强制机制。

**无论识别何种模式，始终输出 `compatibility=UNKNOWN` 和 `actual_egress=NOT_TESTED`。** 工具不决定物理网关、不选择可安全修改的对象、不生成可执行路由建议。

## 场景与证据

先读 [历史基线复核](../../docs/evidence/s0-baseline.md)。将 [本机场景模板](scenario.local.template.md) 复制到 `.local/` 后填写真实目标；公开证据只保留目标代号和经过审查的结论。现有历史快照已用于离线复核，不必为了重新解释旧资料而再次上传。

共享摘要仅说明采集与结构线索。进入 S0-03 前仍需要授权的当前测试环境、确定的物理路径、一个 VPN 目标和一个 DIRECT 目标，以及实际出口与撤销的证据；不要用摘要替代这些条件。

## 离线测试

贡献者使用 Python 3.10+ 和 bash/awk，不安装第三方库：

```sh
/bin/bash -n tools/s0/collect-network.sh
python3 -m unittest discover -s tests/s0 -v
```

测试只使用内联合成网段和无害子进程，不调用真实 macOS 采集命令，不修改系统网络。参见 [本次测试记录](../../docs/evidence/s0-tooling-tests.md)。

实现参考的一手接口语义：[Apple route 手册源码](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.8) 中的 `-n` 和 `get`；[Apple scutil 手册源码](https://github.com/apple-oss-distributions/configd/blob/main/scutil.tproj/scutil.8) 中的 `--dns`、`--proxy`、`--nc`。这不是 macOS 26 真机兼容认证。
