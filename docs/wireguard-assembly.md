# WG-INT-06：配置、规则计划和 WireGuard Adapter 的组装

`48eee07` 的 Mac 原生构建已获用户报告通过，见[独立记录](evidence/wireguard-native-user-result.md)。
这关闭的是该提交的编译链接缺口，不是握手或分流验收。此次新增代码不借用旧 PASS。

## 本批交付

新增 PreparedWireGuardPlan 和 ManagedWireGuardAssembly。前者将协议配置网络字段、
IPv4 用户规则及同版本 underlay 输入交给真实 PolicyCore，输出设置草稿；后者使用
真实 WireGuardKit 类型完成投影、快照绑定和 NE 设置对象工厂接线。

例如无额外 VPN DNS、Peer AllowedIPs 为 `0.0.0.0/0`、接口为 `10.8.0.2/24`，
用户仅指定 `10.9.0.0/16 → VPN`：Include 只生成这个 /16 的 VPN 路由，不自动把
Peer 的 /0 或整个接口 /24 加入 VPN。Bypass 则保留默认 VPN 与显式 DIRECT 例外。
密钥不进入新规划类型；原 AllowedIPs/Peer 顺序不被改写。

协议端点、接口主机地址、配置 DNS 地址和 supplied underlay 冲突时拒绝整个计划。
DNS resolver 选择单独显式给出；即使保留系统 DNS，配置 DNS 地址仍保留 VPN
可达约束，与 AppCore 既有规划一致。默认隧道 DNS 仅允许 Bypass。
主机名端点、IPv6 和 DNS 搜索域当前拒绝，不会被静默丢弃。

## 尚未打通的连接路径

本批已经提供“实际 TunnelConfiguration + 用户规则 → 计划 → 设置回调 → Adapter”
这一段。尚未提供“工作区/Keychain → 正式扩展”的生产凭据交付、可信 Provider
描述符来源、完整控制器及停止后的系统撤销观察。S1 Provider 仍返回未实现错误。
没有新的连接按钮；LocalDev 仍是 LD-03B，OpenVPN 仍未接入。

已成功的旧版构建不必为了确认同一个结果再跑；下一轮需要验证新增接线时仍使用：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash dev.sh engine --fetch
```

原入口自动把组装源文件加入隔离探针并编译；不运行探针、不启动 VPN。
缓存齐全时可省略 --fetch。Git 冲突时保留工作并停止，不强制覆盖。
纯规划测试由既有 `tools/managed/test.sh` 自动发现；新 Python 接线测试由既有
`dev.sh engine-test` 自动发现，后者不执行 ManagedSettings/Go 的测试套件。

无需新的安装工具、手动补丁包、工作区迁移或签名资料。签名在首次真实隧道联调前
恢复。实际回归和未验项见[证据](evidence/wireguard-assembly-06.md)、[ADR-018](adr/ADR-018-wireguard-plan-assembly.md)。
