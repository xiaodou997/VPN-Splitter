# ADR-WG-INT-10：正式 packetFlow 运行会话与设置事务

日期：2026-09-27。状态：Accepted（实现边界）；原生构建及真实网络验收 NOT RUN。起点 e79f889；S1-03/04/05 部分；WG-03/04/05、SEC-01、RULE-05、FAIL-03、REL-01/02。继承 [09](ADR-WG-INT-09-public-packet-flow.md)，不改变 v0.1 范围。

## 同一条运行代码路径

正式 App 独立连接确认 → 已认证 XPC run-v2 → Provider 消费及 08D 材料校验 → 实际网络快照 → 09 原生转换 → PolicyCore/ManagedSettings → setTunnelNetworkSettings 成功回调 → SplitterPacketFlowBackend → 原 Go 引擎。复用 ProviderSessionController，不建立第二套完整会话状态机，不使用描述符扫描、上游默认路由或校验中的占位计划。

旧交付检查仍编码原 v1，默认 purpose=check。只有严格 v2 + purpose=run 才产生运行授权；未知字段/目的拒绝。正式源中的运行调用有编译门控，独立集成构建还为两个签名 bundle 加 VPNPacketFlowRuntime 标记。旧 S1/LocalDev 不会因为更新 main 自动连接。这个构建标记不是身份认证；原 OS Team/角色/XPC 用户身份检查不变。

## 授权、网络与生命周期

已消费的 run 将已认证连接提升为内存运行租约。无消费的挑战仍 15 秒过期；已消费连接不再被原固定计时器强制关闭。取消、App 退出、XPC 失效、显式 discard 或精确 attempt 结束均撤销授权。后台收发每次检查，宿主 250ms 看门检查覆盖空闲会话。没有新增共享 Keychain/文件、任意执行接口或宽权限回退。进程被入侵不在这层防护保证内。

原生网络适配使用 NWPathMonitor、只读 SCDynamicStore、SCNetworkInterface 和 getifaddrs；要求主 IPv4 服务对应 Wi-Fi/以太网，拒绝初始观察到的活动 IPv4 utun/tun/点对点歧义，观察实际地址/前缀、路由器和 MTU。初次观测后生成本会话 epoch=1；任何变化使其永久失效，不自动重建。1 秒快照复查捕获 DHCP/MTU 等变化，设置前后再次检查。睡眠请求停止，唤醒不自动重连。

首轮 MTU 为配置显式值或 min(1280, 物理 MTU - 80)，显式值越界拒绝而非改写。将观察到的物理 LAN/网关与保留地址交给既有约束编译，不扩大 AllowedIPs。此观察器不是完整路由表/过滤器/企业策略探测器，不证明实际出口；多个接口、第三方路由争用和变化窗口仍需扩展与验收。没有全局禁用 IPv6 或 Kill Switch。

## 设置与停止顺序

PacketFlowSettingsGate 为一次 apply/remove。仅在及时成功 ACK 且授权和网络仍有效时启动引擎。所有可能阻塞的 Go start/stop 在专用串行 worker，不阻塞 MainActor。取消/超时先撤销，等待启动操作结算后关闭引擎，再移除设置。

apply 超时不是 OS 取消；移除必须等原 apply 的真实回调后才能提交，避免晚到 apply 覆盖 clear。清除超时包含等待 apply 的时间，迟到 ACK 不升级原结果。保存、运行加载、启动、关闭分别有门控；不自动重试。静态单会话持有对象直至资源已知静止；不确定资源保留并拒绝新会话，不以终止未知系统进程解决。

setTunnelNetworkSettings(nil) 的成功回调仅记录 clearAcknowledged。它不等于路由/DNS 独立恢复证据；本实现没有将其传给 observeSystemTeardown。UI 区分 NE 状态、引擎 ready 与未验证握手/出口，停止时仍显示恢复未独立核查。

## 构建及未关闭门槛

provider-build 使用原固定引擎下载/缓存/哈希验证和 packet-flow-lock，生成独立 Xcode 工程，将实际会话/网络/转换源码和 WireGuardKit/Go archive 链接进真实 PacketTunnel target。不修改已有 S1 工程或锁。默认 unsigned，--sign 才使用本机签名配置；两者都不安装、打开或激活。签名校验命令成功不代表原生认证接受/拒绝通过。

首轮仍单 Peer、IPv4 数字端点、Include、无 DNS 字段。握手与统计查询、实际双出口、系统路由/DNS 独立撤销观察、完整持久化旧记录清理、切网/睡醒重连质量、DNS/S2 尚未完成。先完成新增正式工程的原生构建与现场授权验收，不能以本 ADR 宣告 WG/S1 已结束。48eee07 用户反馈只覆盖原基线。

API 依据：[NE 设置](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/settunnelnetworksettings(_:completionhandler:))、[NWPathMonitor](https://developer.apple.com/documentation/network/nwpathmonitor)、[SystemConfiguration](https://developer.apple.com/documentation/systemconfiguration)。实际执行证据见 [WG-INT-10](../evidence/wg-int-10-provider-runtime.md)。回滚使用后续 revert，保留配置、凭据、缓存、锁和旧证据。
