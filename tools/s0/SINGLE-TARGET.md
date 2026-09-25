# S0-03：现场单目标实验（人工操作规程）

状态：准备工具已实现；实际路由写入、双出口和撤销尚未验证。任务 S0-03；需求 EX-01/02/03/04/05/07、SEC-01；验收 T-E02、T-E03、T-E11。

本规程只用于获得授权的本机实验，不是产品 Helper。不绕过管理员强制策略，不关闭过滤器、Kill Switch 或 MDM。**准备脚本只读；下文明确标出的 add/delete 是管理员手动写操作。没有自动回滚、租约或崩溃清理；关窗口、Ctrl-C、结束脚本都不会自动移除手工添加的路由。** 不能保证恢复或只有远程控制入口时，不执行写入。

## 1. 不再重复 before/after，直接准备 D 与 V

保持原 VPN 已连接，网络不切换。D 为一个获准测试的普通公网 IPv4 服务，V 为另一个应继续走 VPN 的 IPv4 服务。V 可以是内网服务。D/V 不相同；D 不能是 VPN Endpoint、DNS、网关、本机/局域网基础设施、远程会话目标。不要从旧配置猜当前 Endpoint；本工具不能自动发现所有控制连接。没有合适目标则停在准备阶段，不默认访问第三方 IP 查询站。

```sh
/bin/bash tools/s0/preflight-target.sh
```

按本地提示输入 D、V；阅读范围确认后输入 `PREPARE`。这只同意现场只读采集，不会调用 sudo 或发包。也可使用两个规范 IPv4 参数，仍需本地终端确认。

工具只用系统 Bash/awk；复用 `collect-network.sh` 的超时、输出上限和私有目录函数。采集当前路由首尾、接口、hardware ports、DNS、代理、扩展、默认/网关/D/V 的 route get。普通 on-link 网关的 IFSCOPE 记录允许用于确认该接口；D/V 的 scoped 查询不当作普遍选路证明。

只在 `preflight_readiness=MANUAL_EXPERIMENT_CANDIDATE` 时生成 `targets.private.txt` 与本规程的本地副本。任何 BLOCKED、采集失败、路由格式歧义均先停下。工具要求单个成对 /1 样本，不自动扩展到任意 VPN。

`gateway_path=ON_LINK_ROUTE_OBSERVED` 不是 ping、ARP 或转发成功；`VPN_ROUTE_OBSERVED` 不是实际 VPN 出口。首尾路径候选相等不是原子快照：中间变化后又恢复可能漏检，必须现场观察并在写入前重查。

## 2. 本地恢复准备与观测

确认网络/VPN 管理方允许分流、同一测试 Mac、有物理控制台与恢复入口。检查生成目录中的 `extensions.txt` 和 `proxy.txt`；存在组件不等于它在强制拦截，没有列出也不代表不存在。不能解释当前策略时不进入写入。

在本地记录精确 macOS build、客户端版本、工具 commit、时间和测试目标代号。复制 `targets.private.txt` 中 D/V/G/P/T 五行到**本地终端变量**，逐项核对：G=物理网关，P=物理接口，T=VPN 接口。不要 source 或执行整个生成文件，不把它当签名授权。所有输出留在权限 700 的本次目录；先设置 `umask 077`。

先准备下文的删除操作并保持同一终端可用。另开一个本地终端只读观察路由事件：

```sh
/sbin/route -n monitor
```

它不会自动识别归属或回滚。若不能判断是否有争用，就不做修改。实验期间不切网、不重连、不睡眠、不让其他管理工具更改同一目的路由。

## 3. 记录修改前的实际流量，而不只是 route get

使用受控服务端连接日志，或管理员授权的、仅针对测试目的的链路观察。记录 D/V 的新连接均沿预期 VPN 路径。D 的物理直连出口须有独立依据（已知直连源地址或限定物理接口观测）；源地址变化本身不足以证明直连。如果 VPN 与直连共用出口或没有证据，只能记 INCONCLUSIVE。

HTTPS 服务可使用下面模式。D_HOST 是本地填写、证书有效的受控服务主机名；V 同理。命令不跟随重定向，不发送认证信息，不读取 curl 默认配置，不使用显式 HTTP/SOCKS 代理，不绑定物理接口。服务非 HTTPS 则用实际协议及相应服务端证据，不通过关闭 TLS 校验凑成功。

```sh
/usr/bin/curl -q --ipv4 --proxy '' --noproxy '*' \
  --connect-timeout 5 --max-time 15 --proto '=https' \
  --resolve "${D_HOST}:443:${D}" --output /dev/null \
  --write-out 'remote=%{remote_ip} status=%{http_code}\n' -- "https://${D_HOST}/"
```

将 D_HOST/D 替换为 V_HOST/V 后再测 V。每次独立启动 curl，避免旧 TCP/QUIC 会话；不能用 `--interface` 强行选路冒充路由规则生效。`remote_ip` 是服务端地址，不是本机出口 IP；用服务端日志核验源地址和时间。`--resolve` 只控制本次请求解析，不改系统 DNS，也不证明域名规则已实现。

必要时管理员可在 P 上限于 `host D`、所需端口、有限包数观察包头；不要抓全机流量或公开原始抓包。该方式需独立授权，不由准备脚本启动。

## 4. 写入前最后核对（仍只读）

```sh
/sbin/route -n get -inet "$G"
/sbin/route -n get -inet "$D"
/sbin/route -n get -inet "$V"
/usr/sbin/netstat -rn -f inet
```

要求 G 仍 on-link 于 P；D/V 仍选择 T；D 没有任何现存 /32（包括 scoped、cloned、动态或别人安装的条目）；成对 /1 与物理默认路径仍一致。探测可能产生缓存 host route，**发现后不删除缓存、不假装归属自己**；先停止并调整测试方法。所有检查/写入之间仍有竞态，实验必须保持人工观察，不能据此宣称产品事务安全。

## 5. 唯一允许添加的条目：D 的一个临时 host route

只有上述检查与授权均满足，用户才手动执行一次：

```sh
sudo /sbin/route -n add -inet -host "$D" "$G"
```

记录准确命令、退出状态和时间。非零退出、超时、`File exists` 或任何歧义都停止：不要循环重试、不要 change/replace、不要删别人的条目。添加失败不意味着已取得任何路由的所有权。

成功后立刻核对 D 的 /32、gateway=G、interface=P，V 仍为 T。再执行第 3 节相同新连接，要求 D 的实际直连证据与 V 的 VPN 证据同时成立。若路由被第三方重装或目标失败，不关闭强制机制、不再添加；转入归属检查与恢复。

## 6. 撤销与检查（同样是管理员手动操作）

只在确认添加确实成功、当前 D 的唯一 unscoped host route 仍为 G/P、且没有他方覆盖/删除重建迹象时，手动执行一次：

```sh
sudo /sbin/route -n delete -inet -host "$D" "$G"
```

**参数相同不构成绝对归属证明或原子 compare-and-delete。** 发生重连、争用、接口变化或身份歧义时不要盲删，标 `RECOVERY_REQUIRED` 并由现场管理员核验；禁止 route flush、恢复整个旧路由表或批量删 utun 路由。条目已不存在则不再删，不以“恢复”为由重建它。

撤销后再次确认 D 不存在本次添加的条目，D 的新连接回到原 VPN 路径，V 保持 VPN，原 DNS/默认路由未被我们修改。比较时允许动态计时/缓存变化，不以整份文本字节相同作为恢复条件。正常断开原 VPN 的快照不能代替“VPN 保持连接时撤销例外”的验收。

## 7. 回报与通过标准

只手工反馈经核实的固定状态；原始 IP、域名、日志和生成目录留在本机。以下是模板，不是工具生成结果，未测保持 NOT_RUN：

```text
schema=s0-single-target-manual-v1
preflight=NOT_RUN
route_add=NOT_RUN
direct_target_actual_path=NOT_RUN
vpn_control_actual_path=NOT_RUN
route_remove=NOT_RUN
post_remove_target_path=NOT_RUN
owned_route_residue=NOT_CHECKED
dns_configuration_mutations=NONE_BY_THIS_PROCEDURE
result=NOT_RUN
```

成功示例字段分别为 `CANDIDATE`、`SUCCESS`、`DIRECT_VERIFIED`、`VPN_VERIFIED`、`SUCCESS`、`VPN_VERIFIED`、`NONE_OBSERVED`、`PASS_SINGLE_SAMPLE`；只能按实际证据填写。缺出口证据用 INCONCLUSIVE；写入/恢复异常用 FAIL 或 RECOVERY_REQUIRED。一次成功只验证这个 IPv4 目标、VPN 版本与现场环境，不等于域名/IPv6/重连/睡醒已经支持，更不等于完整 S0 或 v0.1 已通过。

## 8. 接口依据与测试边界

[Apple route 手册](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.8) 描述 get、host、gateway、delete 与 ifscope；本规程未在真实 Mac 执行 add/delete。以本机 man route 和实际行为核对，语义有差异即停止。

[curl 官方手册](https://curl.se/docs/manpage.html) 描述 -q、--proxy、--noproxy、--resolve、TLS 与输出变量。[Apple WWDC25](https://developer.apple.com/videos/play/wwdc2025/234/) 明确 Network Extension 的路由强制与直接改路由的兼容风险；本实验不改变 Managed 使用 NE 的路线。
