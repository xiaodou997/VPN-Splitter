# ADR-017：显式隧道描述符与不可复活的运行绑定

日期：2026-09-26。状态：Accepted（WG-INT-05 构建候选；不批准真实执行）。任务 S1-04/S1-06 部分；T-WGE01–05；Refs #1。承接 ADR-013–016，不更改首发范围、签名或实际出口验收门槛。

## 决策

候选 Adapter 不再扫描进程 0…1024 的描述符，也不以“第一个 utun”作为本会话隧道。初始化必须显式提供 `SplitterWireGuardBinding` 和 `tunnelDescriptorProvider`；没有默认值、KVC 或扫描回退。描述符提供者必须来自未来 Provider 控制层。本批不提供伪造的生产提供者，现有正式 Provider 继续有意拒绝连接。

`SplitterTunnelDescriptorLease` 先复制一个明确传入的 fd，再在该副本上检查 AF_SYSTEM、SOCK_DGRAM 和 UTUN_OPT_IFNAME 与预期名称一致。使用 CLOEXEC 副本；租约借用期间不能关闭它；借用完成/失败后关闭副本，不关闭来源 fd。Go 仍按既有桥接契约复制其传入 fd。所有这些检查都是 socket/名称一致性，不是操作系统授予的 Provider 所有权证明。原描述符和预期名称的可信来源，以及原生行为，仍是运行前门槛。

运行绑定保留接口和 Peer 的值快照；显式比较 Peer 顺序和 AllowedIPs 顺序，不直接依赖上游 `TunnelConfiguration ==` 的集合比较。地址顺序、密钥、端点、DNS、MTU 等配置值不允许悄悄更换；显示名称及运行计数不参与策略身份。源类型见固定 [TunnelConfiguration](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKit/TunnelConfiguration.swift)、[InterfaceConfiguration](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKit/InterfaceConfiguration.swift)、[PeerConfiguration](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKit/PeerConfiguration.swift)。不修改协议算法或 AllowedIPs。

控制层须维护 Provider 实例、会话、generation、networkEpoch 和凭据绑定 ID。每次读取必须来自当前控制层而非捕获的常量。观察到不匹配/缺失或显式 invalidate 后，该绑定永久失效；即使旧值恢复也不复活。控制层仍须在每次变化时主动失效并停止会话：轮询式检查本身不是网络/凭据观察器，也不能发现两个检查之间发生又撤销的变化。

开始时先检查并复制配置，再解析端点；策略工厂得到独立副本，返回后复查，不能修改协议生成器中的对象。系统设置完成后、引擎启动/更新前后继续复核身份。引擎启动成功但尚未发布到 Adapter 状态时发现失效，显式关闭该新句柄。普通停止、异常隔离与释放都撤销绑定。原始调用者不得在并发线程上无同步地修改 TunnelConfiguration。

本候选保守采用“一份绑定、一份配置、一段 Provider 生命周期”。相同配置可复查/更新，真正配置或策略版本改变则要求由控制层停止、观察旧会话结束后重建；不提供就地替换绑定 API，也不自动新建 Adapter。应用层配置编辑和模拟的现有行为不变。

## 不作出的保证

Apple [packetFlow](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/packetflow) 文档提供包读写抽象；它不构成本项目获取 fd 的已验证实现。本批不使用未验证的属性/KVC 来填补缺失。实际 Provider 描述符来源、配置/凭据与 PolicyCore 输入的投影、网络 epoch 观察、终止与 OS 撤销确认仍未完成。

停止 Go 对象、拒绝迟到成功或关闭副本均不证明系统网络设置已撤销。系统请求可能仍然生效，必须另行处理终止/观察。底层调用阻塞时不承诺强制取消。原生 C ABI/Swift 构建、日志过滤、凭据交付、依赖许可/漏洞审查仍开放。未创建真实 TUN、激活扩展或改变路由/DNS。

## 复查与恢复

完整固定上游 Swift 源码作为 MIT 测试参考入库，Git blob 与原始锁相同；保留版权头及现有 COPYING.reference。三段 Swift 变换、对应 review patch 和最终输出哈希一致性有自动回归；Go 补丁是独立路径，不与 Swift 补丁混淆。支持文件仍通过原构建脚本精确校验并复制，不增加依赖或用户命令。

证据见 [WG-INT-05](../evidence/wireguard-engine-05.md)。回撤使用后继提交，不 force/reset/clean，不改用户 JSON/Keychain/锁文件/原 .conf。开发签名仍暂停；首次真实联调前恢复。
