# LocalDev：WireGuard 结构与配置范围检查

LD-02A 的结构导入在 LD-02B 中保留；当前更新、凭据和恢复入口统一见 [Keychain 操作指南](localdev-keychain.md)。旧版 LD-02A 的实际测试记录保留在 [历史证据](evidence/localdev-wireguard-02a.md)，不把旧测试提升为本轮 Mac 验收。

## 结构导入

用户主动选择本地 `.conf`，经有上限的常规文件读取和格式解析显示报告。新增策略默认不勾选凭据保存，确认“仅保存结构”时只持久化网络元数据，不调用 Keychain。需要完整凭据存储时必须明确勾选并确认；密钥值永不进入结构报告/工作区 JSON。原文件不被复制、修改或删除。

解析 Interface/Peer、地址、DNS、端点、AllowedIPs、端口、MTU、Keepalive 与密钥格式。脚本钩子、未知指令、重复单值字段拒绝，不能静默忽略必要语义；IPv6、尚未解析的主机名 Endpoint 等保留结构并说明阻断原因。格式正确不代表服务端身份/回程/认证成立。资源上限、语法子集见 [ADR-009](adr/ADR-009-wireguard-structural-import.md)。

新导入不覆盖其他策略，不把 AllowedIPs 自动变成规则。菜单重新导入会替换当前策略结构并保留名称、规则、默认动作，凭据事务见新指南。接口地址保留主机位，规则编辑不改协议 AllowedIPs。

## 合成检查示例

导入 `tests/fixtures/wireguard/synthetic-ipv4.conf`，确认保存结构或结构与凭据。新增 `10.9.0.0/16 → VPN`，保存并检查 `10.9.4.5`，应显示预期 VPN 和 peer-1；检查 `10.9.0.53` 会显示配置 DNS 的约束。这些操作不会访问目标。

增加 `198.51.100.7 → VPN` 后检查应拒绝，因为目标超出 Peer 范围；不自动扩张 AllowedIPs，旧成功预览应失效。删掉或禁用错误规则可恢复检查。

导入 `synthetic-hostname.conf` 应保留 hostname 并标明未解析，不能展示“端点直连已确认”。不要把真实端点替换成随意 IP 来去掉警告。重新导入测试用 `synthetic-reimport.conf`，此样例改变测试密钥/地址/端点但保留同一 AllowedIPs；名称和规则应保持。

所有夹具只含固定字节模式测试密钥及合成地址，不属于任何真实服务，不能用于真实 VPN。

## 约束编译不是路由执行

PolicyCore 调用 IPv4ConstrainedPolicyCompiler 做 first-match、最长前缀 Peer 选择及端点/DNS/接口要求冲突检查。不通过空拓扑或虚构 peer 伪造检查。数据限于导入配置，不探测物理网关/局域网，不解析端点，不证明实际出口。

预览把文件中 DNS 地址作为 VPN DNS 要求，这项假设在报告中显示；不代表完整 DNSPlan 或服务端 DNS 行为。相同前缀跨 Peer 歧义拒绝，与显式规则相反的基础设施要求拒绝。输出是 planning-only，不能直接安装。

主界面结构与技术详情可折叠，但阻断项仍可见。移除结构需确认且会解除/尝试清理关联凭据；名称规则保留，此后只检查规则意图，不再检查配置 Peer/基础设施。v3 不自动降级。开发签名继续暂停，所有真实协议连接和 Network Extension 共享留待后续分别验证。
