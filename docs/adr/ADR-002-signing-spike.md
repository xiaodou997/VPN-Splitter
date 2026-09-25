# ADR-002：最小签名与 Provider 加载工程

2026-09-25。状态：Proposed / 待真机验证。关联 S1-01、S1-06、T-U01/T-U06 初验；不是整个 S1 的 Accepted 结论。

采用已提交的原生 Xcode project，App + PacketTunnel system extension 两个 target，macOS deployment 26.0、arm64、Swift 6。本地 PolicyCore 链接到两个进程。无外部构建依赖，工程生成器只服务维护；不依赖 App 内动态 framework 路径，因为 system extension 会复制到系统保护目录。

Debug/Release 用 Apple Development、标准 NE entitlement；DeveloperID 用手动 Developer ID 签名及 -systemextension entitlement。每种渠道 App/扩展须有各自匹配的 profile；Team/签名设置保存在忽略的本机文件。脚本只构建/检查，安装和系统批准由用户执行。

本阶段不接管数据流量：Provider 记录携带测试 UUID 的 first-light/进入日志后返回 1001 未实现错误，不设置 tunnel network settings。因此不会用一个无协议的默认隧道吸收全部网络数据。实际系统启动可能短暂创建接口，不宣称无系统副作用。

App 仅操作 provider ID + spike ownership marker 匹配的唯一配置，禁止 on-demand；所有写入由按钮触发。未知配置、多份配置、会话仍活动时拒绝破坏性操作。激活/停用与 profile 保存/移除分开。不暴露自定义 XPC，不引入共享密钥路径。

S1-06 仍需追加：精确 Xcode/macOS build、Development 与 Developer ID 真机证据、WireGuardKit revision/适配点、enforceRoutes 实测选择。当前 no-backend 的 false 仅适用于此加载 Spike，不改变正式 Managed 路由决策。

来源：Apple [调试说明](https://developer.apple.com/forums/thread/725805)、[打包说明](https://developer.apple.com/forums/thread/800887)、[Developer ID NE 导出](https://developer.apple.com/forums/thread/737894)。系统扩展与 App 用户上下文不同；后续凭据共享不得直接假定用户 Keychain/App Group 可跨进程共享。
