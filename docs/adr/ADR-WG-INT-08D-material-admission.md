# ADR-WG-INT-08D：正式材料语义校验，不冒充可运行隧道

日期：2026-09-26。状态：Accepted（本批代码边界）；原生构建和真实功能未验收。起点 27dde34。任务 S1-03/04 部分；需求 WG-01/02/03/04/06、P-06、RULE-02、SEC-01。继承 08C，不关闭 S1/S2 的真实技术门槛。

## 决策与实际调用链

正式 App 保存之前、认证 hello 后读取旧记录但 XPC stage 之前、真正 Provider 消费交付之后，均调用 `ManagedWireGuardInput.prepare`。App 使用返回快照的字节写入/交付，不在检查后又使用外部可变输入。Provider 不信任 App 的“已校验”标志，重新解析实际收到的字节。

依赖本地 AppCore 的完整 `WireGuardImport.prepareCredentials` 与 `WireGuardPlanning`，实际执行 PolicyCore 约束编译，不复制一份简化配置解析器。ProviderConfiguration 增加显式本地 AppCore/PolicyCore 依赖，最低平台与它们及正式产品统一为 macOS 26。不新增第三方/远程依赖，不更改 LocalDev 的入口、权限或存储。

## 首轮接受范围

仅单 Peer、IPv4 Include、明确 IPv4 数字端点。接口须为非重复单播地址，不能使用 /0 或与端点相同；不能缺少 AllowedIPs。脚本、未知指令、非法/缺失密钥、重复关键字段和越界参数由已有完整解析器拒绝。密钥仅验证格式，不证明远端身份、握手或可达性。

任何 IPv6 成分、多 Peer、主机名端点均明确拒绝而非丢弃。本轮还没有 DNS 选择与 Split DNS 运行方案，因此 DNS 地址和搜索域均报专门阻断错误；不能偷偷忽略或自动删除。此限制仅收窄第一条受控路径，不取消 v0.1/S2 目标，不建议修改原始有效配置来冒充等价支持。

规则沿用 08C 二进制 property-list 归档 `managed-ipv4-include-draft-v1`：精确字段、DIRECT 默认、1–256 条规范 IPv4 CIDR；拒绝额外字段、错误类型/版本、XML 格式或隐藏动作。UI 编码器只规范化规则网段，保留顺序/重复项；不改接口 host bits、密钥、AllowedIPs 或配置其他原始字节。配置和归档各限 64 KiB，保留导入器的行/字段/Peer/prefix 上限。

实际编译核对 VPN 规则在协议 AllowedIPs 覆盖内，冲突端点/接口自身则整体拒绝。另为本里程碑明确保留 0/8、127/8、169.254/16、224/3 的非隧道路由意图，明确规则冲突时拒绝，不剪裁用户规则。它们不是物理网络发现；不制造物理网关、接口或 LAN。

`CheckedManagedWireGuardInput` 保存不可变源材料、元数据和类型化 IPv4Policy，描述/反射脱敏，不提供公开构造或 Codable。只在已持有原输入的调用范围内访问字节，不新增 LocalDev 凭据导出。Swift/Data/IPC 副本不承诺全部清零。

## 文件选择和错误

正式选择文件通过 O_NOFOLLOW/O_NONBLOCK/O_CLOEXEC 打开，在同一 fd 上 fstat 常规文件并有界读取；拒绝目录、符号链接、FIFO、空/过大文件。读取失败清空待保存的上次内存选择及其保存同意，不影响已保存记录。原路径不持久化，原文件不改动。

语义错误使用静态代码和说明，不附原文/路径/Keychain 引用或底层错误。保存时先拒绝才可能准备 Keychain/保存偏好；旧记录再次交付也会检查。Provider 的语义拒绝为 2004，无活跃交付 2003，元数据错误 2002；合格材料仍返回 2001 引擎未安装；旧 smoke 1001 保留。未执行路由/DNS 设置，没有成功连接返回。

## 必须继续实现的边界

本批是语义校验与类型化快照，**不是 WireGuardKit TunnelConfiguration 的原生转换实现**。还须保持所有协议字段不变地转换、接可信自有数据通道、实际 underlay/epoch、WG-INT-07 会话及运行撤销。校验中使用的私有占位 context 不外传、计划不返回，绝不能安装到 NE 或宣称观察过系统网络。

08C 的真实签名/Keychain/XPC/偏好/GUI 仍未验收。本批不更改其认证、组、entitlement 或超时/取消策略。新代码的 Apple SDK 构建、运行授权、握手、双出口和停止后的系统恢复仍待验证。代码回滚为后续 revert，旧记录/配置/锁/缓存和历史证据保留。

执行范围见 [08D 证据](../evidence/wg-int-08d-material-admission.md)。
