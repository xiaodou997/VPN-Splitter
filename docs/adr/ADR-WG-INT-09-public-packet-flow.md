# ADR-WG-INT-09：原生配置转换与公共 packetFlow 数据通道候选

日期：2026-09-26。状态：Accepted for build candidate；不是原生运行或发行批准。起点 ca1a25d。任务 S1-03/04/05 部分；WG-01/03/04/05、SEC-01、FAIL-03。继承 08D 的配置检查和 08C 的认证交付，不降低门槛。

## 决策与来源

已有描述符路径要求可信 Provider 描述符，但其实际取得方式尚未实现。本批新增独立、显式选择的公共 `provider.packetFlow` 路径：Swift 调用 `readPackets` / `writePackets`，经有界 C ABI 队列接到 pinned wireguard-go 的 `tun.Device`。不扫描 utun，不用 KVC/私有描述符，也不创建第二个系统隧道。只使用构造时传入 Provider 自身的 flow；其授权和生命周期仍由正式控制层负责。

Apple 公共接口及协议数组语义见 [NEPacketTunnelFlow](https://developer.apple.com/documentation/networkextension/nepackettunnelflow) 和 [readPackets](https://developer.apple.com/documentation/networkextension/nepackettunnelflow/readpackets(completionhandler:))。Go 接口固定于 ecfc5a8d54462e18e13c72173e2623d16d8e25a0 的 [tun/tun.go](https://github.com/WireGuard/wireguard-go/blob/ecfc5a8d54462e18e13c72173e2623d16d8e25a0/tun/tun.go)。这是适配数据通道，不重写 WireGuard 加密或协议。

保留原 `engine` / 描述符构建、已有补丁、Go 工具链和模块锁。新 `engine-flow` 才加入这些源码及新增符号检查；默认不自动切换后端。两种路径不可同时运行，也不可混用各自 start/stop ABI。正式 Provider 本批不调用新后端，合法请求仍返回 2001。

## 原生转换

`ManagedWireGuardNativeInput` 接收 08D 的不可变检查快照。固定 wireguard-apple 2fec12a6e1f6e3460b6ee483aa00ad29cddadab1 的 quick-config parser 与数组 helper 原样加入候选 WireGuardKit；不复制整个上游 App。保留 MIT 声明和许可证，逐文件哈希验证。

门面只处理已被 08D 接受的 BOM/CRLF 和 `PersistentKeepalive=off` 到 0 的等价写法；错误统一脱敏。原生对象与检查快照再核对接口 host bits/顺序、ListenPort、MTU、AllowedIPs 原值/顺序、端点、Keepalive 和 PSK 存在性。无掩码地址按上游 /32 表示；不规范化或扩大协议 AllowedIPs。每次输出独立 TunnelConfiguration 引用，不让调用者修改内部快照。密钥由同一原始字节的固定解析器转换；不增加日志、文件或凭据导出渠道。

## 数据包与并发

新 Go TUN 不拥有文件描述符，`File()` 为 nil；Name 只是内部标签，绝非系统接口名或所有权证明。双向队列各 32 包，单包上限为显式 MTU（576–65535）；检验 IPv4 版本、IHL 与总长度，拒绝 IPv6/错长度。队列满时背压，不无限堆积；关闭清除引用并唤醒读写。BatchSize 固定 1，保留上游 offset/sizes 语义。

C ABI 借用调用者缓冲区，不跨调用保留指针。句柄由既有生命周期注册表分配；另加 starting/stopping 门控保证一个 flow。关闭顺序为摘除 flow 句柄、唤醒队列、关闭协议引擎，再允许新 flow。不会用旧指针或旧句柄误写新会话；不保证任意无效 C 指针可以安全检查。

Swift 每次只挂一个待完成的 NE 读取，令牌拒绝重复或过期回调；每批最多 128 包/2 MiB，Go 队列限额独立。框架在回调前的分配不受本层控制。两条工作队列处理包，单独队列处理失败关闭；public owner 释放可关闭阻塞工作者，不形成 owner 自引用永久存活。并发 stop 会加入已提交的关闭，不提前报告协议停止。NE 已挂起读取没有本层取消方法，迟到回调会被丢弃。

只有当前控制层提供的 isCurrent 检查通过才能开始和继续包处理；它不是系统网络发现。空闲时不会凭空观察到授权撤销，宿主必须在授权、网络、睡眠等失效事件上明确 stop。同步原生引擎调用可能阻塞，不在 MainActor 调用；本批不承诺强制终止阻塞协议调用或全部内存副本安全清零。停止只指协议/包通道，不证明路由/DNS 已撤销。

## 正式接入前必须完成

本后端只复用 WireGuardKit 的 UAPI 序列化，绝不调用其默认网络设置生成器。正式宿主仍需：认证交付保持有效；真实 underlay/epoch；PolicyCore/ManagedSettings 计划与来源匹配；成功应用 NE 设置；明确有效 MTU；随后在工作队列启动引擎；将取消/超时/失效接入停止及独立设置撤销观察。无配置 MTU 时本原语不猜测默认值，宿主须解决并验证。

实际 macOS SDK 编译、真实 WireGuard UDP/加密/握手、Apple packetFlow 行为、性能/睡眠及目标出口均需验收。本批选择公共 API 消除了对未实现 FD 来源的依赖，但不能写成“真实通道验收通过”或“只剩签名”。首轮仍单 Peer/IPv4 数字端点/Include/无 DNS；不取消 S2、OpenVPN、External 或其他原需求。
