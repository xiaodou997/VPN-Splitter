# ADR-009：LocalDev WireGuard 结构导入与配置范围约束检查

> 本文的“无 Keychain”限于 LD-02A；LD-02B 已由 [ADR-010](ADR-010-localdev-keychain-transactions.md) 增加显式凭据持久化，结构模式仍保留。当前从 main 更新。

日期：2026-09-25。状态：Accepted（LocalDev 增量设计；不是完整 S1-03、Keychain 或真实 VPN 验收）。
任务：LD-02A；S1-03 的解析/凭据边界部分、S1-02 约束编译器接入。关联 WG-01/03/06、T-W06、T-U02–U04、T-P10。
前序：ADR-007、ADR-008、ADR-006。继续暂停开发签名，不修改正式 App / Packet Tunnel 工程。

## 决策与范围

本批提供单向的 `.conf` 结构投影：本机选文件 → 检查语法、密钥格式及兼容性 → 用户确认 → 新建独立策略并持久化非密钥网络结构。禁止把“可导入结构”描述成“可连接配置”。`.ovpn`、真实协议后端和 Keychain 持久化未实现；不是取消这些后续任务。

所有产品逻辑仍为 Swift，AppCore 依赖现有 PolicyCore；不新增第三方代码或协议依赖。原始配置、私钥、公钥、预共享密钥、文件路径、文件名和文件 bookmark 不进入返回的 metadata、工作区 JSON、日志或模拟状态。报告仅记录是否存在预共享密钥；Peer 用导入顺序的非密钥 ID 标识。

不把密钥先写到普通 JSON“以后再迁移”；也不通过未经真机验证的 Keychain 调用宣称凭据持久化已安全。本批不调用 Security / Keychain。原 .conf 必须由用户保留，未来真实连接需重新导入到正式凭据路径。Swift String/Data 可能复制，释放引用不等于可靠内存清零；源文件仍含密钥。网络结构仍可能包含私有地址和域名，绝非完整脱敏材料。

## 导入子集与失败行为

接受一个 Interface 和随后 1–64 个 Peer；支持 PrivateKey、Address、DNS、MTU、ListenPort、PublicKey、PresharedKey、AllowedIPs、Endpoint、PersistentKeepalive。Address/DNS/AllowedIPs 可重复，累积列表；其他重复字段与重复 Peer 公钥拒绝。支持 UTF-8 BOM、CRLF、# 注释及大小写不敏感的字段/节名。

密钥只做规范 Base64、32 字节、非全零格式检查，不计算握手、不证明公钥有效性或服务器授权。IPv4 限规范十进制；IPv6 使用本机纯地址解析，不调用 DNS；不接受 zone ID。主机名限 ASCII 标签。数值限规范十进制，ListenPort 为 0–65535、Endpoint 端口为 1–65535、Keepalive 为 0–65535 或 off、MTU 为 576–65535。这是本轮解析子集，不代表所有上游合法配置均可导入。

PreUp/PostUp/PreDown/PostDown 一律拒绝；Table、SaveConfig、FwMark 和未知指令也明确拒绝，不删除、不运行、不读取引用文件。不支持的脚本可能承担重要网络语义，不能指导用户仅删掉它们就宣称配置等价。

文件最多 256 KiB、4096 行、单行 4096 字节；地址最多 64、DNS 地址和搜索域各 32、所有 Peer 共 2048 个 AllowedIPs。所选文件使用 O_NOFOLLOW / O_NONBLOCK / fstat 检查为常规文件，并限制读取字节数。拒绝末级符号链接、目录、FIFO 和远程 URL；不是对同一用户进程的路径/内容竞态防护保证。

## 原始协议结构与策略分离

接口 Address 保留主机位；AllowedIPs 保留各自文本值与 Peer 顺序。只在约束检查边界调用 IPv4CIDR 做地址集合规范化，不回写配置，不因用户添加规则而扩张 Peer 范围，不把 AllowedIPs 自动变成用户规则。

本轮预览将文件里的 DNS 地址按 VPN DNS 检查，此假设在导入报告中展示并随结构确认；它不是对原 wg-quick 选路行为的推断，也不是完整 DNSPlan。需要其他 DNS 路径的配置留待 S2 明确设计。

有数字 IPv4 端点、IPv4 接口地址及非空 Peer 范围时，将配置中的端点、DNS、接口自身地址及 Peer 表交给真实 IPv4ConstrainedPolicyCompiler。保留 first-match，拒绝显式规则/基础设施冲突、Peer 范围外 VPN 区域和相同前缀的歧义归属，展示必要的默认例外及 Peer 分配。

这只检查“配置提供的拓扑”。不探测物理网关、局域网、当前路由、DNS、Network Epoch 或实际出口，也不是完整可执行计划。域名 Endpoint 未解析时、缺少端点/接口地址/Peer 范围时，阻止配置约束计划。IPv6 字段可保留并显示，但不偷偷过滤后返回部分成功的 IPv4 计划。DNS 搜索域仅为信息，不变成 DOMAIN 规则或解析器设置。

无关联 metadata 的草稿仍使用原来的规则意图预览；移除 metadata 必须确认，并明确提示此后不再检查 Peer 或配置基础设施。导入不改变现有规则，不自动连接，模拟始终标注模拟。

## 保存、编辑与版本

导入报告与编辑窗口互斥。导入确认采用工作区基线比较；发生变化时拒绝旧确认覆盖。只有成功原子保存后才选择新策略和关闭报告；失败保留报告、原内存及磁盘数据，允许重试。取消/放弃退出不写入工作区。

旧 schemaVersion 1 草稿可继续读取、编辑；只有首次成功导入时升级为 schemaVersion 2，并添加可选 wireGuard 结构。v2 移除结构后不自动降级。旧开发版拒绝 v2 而不是忽略新字段后保存掉数据。未知未来版本仍拒绝加载且保留文件。metadata 有自己的 formatVersion 1，读取后重新验证，兼容状态每次重算。

开发源代码回滚不会自动回滚用户数据格式。退回旧应用前必须保留工作区备份；不能修改版本号或删字段来伪造迁移。新版本可继续使用 v2，无需为源码更新先删除原数据。

## 证据与未完成项

代码、Linux 单测、静态合同、macOS SDK 编译、原生文件选择/确认交互、Keychain 和真实 VPN 分别报告。后续继续 LD-02B / S1-03 的凭据持久化、删除/重导入失败恢复及正式扩展访问边界；首次真实 Managed 联调前恢复开发签名。S0–S5 退出门槛不改变。

规范参考（仅使用格式/语义，没有复制第三方实现）：
- WireGuard `wg(8)` 配置格式：https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8
- `wg-quick(8)` 的 Address、DNS、脚本和路由扩展：https://git.zx2c4.com/wireguard-tools/about/src/man/wg-quick.8

操作见 [WireGuard LocalDev 指南](../localdev-wireguard.md)，本批证据见 [LD-02A](../evidence/localdev-wireguard-02a.md)。
