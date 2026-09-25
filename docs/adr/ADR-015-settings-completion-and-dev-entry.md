# ADR-015：设置完成门控与统一开发入口

日期：2026-09-26。状态：Accepted（WG-INT-03 构建候选，不批准真实执行）。任务 S1-04/S1-06 部分、DEV-01；T-WGC01–04；Refs #1。承接 ADR-013/014。用户同意保留上游 Go、将 Python 限于开发工具并简化手工步骤；没有新增安装、签名或网络授权。

## 开发入口

新增根目录 dev.sh，默认只读 doctor。界面 run 不经过 Python/Go 检查；需要开发脚本的模式先用 Shell 检查 Python 3.9+。doctor 聚合 macOS/架构、Xcode、SDK、Swift、Clang、Git、Python、Go 结果，分别报告界面与引擎环境；缺 Go 不阻断界面。只有显式 engine --fetch 允许原有固定公开下载。没有自动安装、依赖升级、PATH/开发目录变更或新的程序运行依赖。

## 设置完成

Apple 要求 Provider 等待 setTunnelNetworkSettings 完成后再报告隧道可用；completion 表示设置调用结果，而不只是发起成功。依据：[startTunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/starttunnel(options:completionhandler:))、[setTunnelNetworkSettings](https://developer.apple.com/documentation/networkextension/netunnelprovider/settunnelnetworksettings(_:completionhandler:))。

在现有强制策略补丁之后增加独立的受控变换：每个设置请求创建 SplitterSettingsCompletion；使用 NSLock 保护单个终态，以 DispatchSemaphore 的单调 DispatchTime 截止等待。同步完成不会丢失信号；多次回调只采纳一次；超过截止时间的成功也不被接受。回调只捕获完成门控，不捕获 Adapter，因此迟到结果不会修改 Adapter 状态。参考 [DispatchSemaphore.wait](https://developer.apple.com/documentation/dispatch/dispatchsemaphore/wait(timeout:))。

五秒只界定主动等待期限，不保证阻塞 OS API、线程调度、睡眠或引擎清理的总耗时，不等同于取消系统请求。超时/设置错误/缺失 Provider、设置之后无法启动引擎或 wgSetConfig 非零时，标记 requiresProviderReset，停止当前已知协议句柄与监视，不报告系统设置已撤销。同实例 start/update/stop 和路径事件均不能清掉此标记；不自动重建或重试。普通 stop 仍只代表上游引擎停止，不被提升为路由撤销证明。

更新错误可能是部分应用，不假设旧配置仍完整有效；wgSetConfig 的非零结果经 checkedSetConfig 包装为错误。Go bridge 对未知句柄返回零、忽略 Device.Up 结果及部分失败清理仍是独立未关闭问题。

## 复用与验证

门控是独立纯 Swift 小包 WireGuardSupport 的内部类，单元测试实际编译这份源码；构建候选逐字节复制同一文件进入 WireGuardKit，并校验锁中记录的 helper / runtime_hook Git blob。原始 Adapter 与第一阶段策略补丁的完整 SHA 检查不变。第二阶段按唯一上下文转换，变换程序自身锁定，最终 Adapter 实际 hash 写入构建结果，不用未经核验的本地重建 hash 取代上游锁。

构建时合入补丁并不说明实际系统调用、Go 引擎、Provider 恢复已验证。本轮不接入 LocalDev 或正式 Provider；前几批原生对象、Keychain、完整核心编译/链接与签名联调门槛全部保留。不宣称系统级 Kill Switch、完整 IPv6、自动真实重连或崩溃后的安全撤销。结果见 [证据](../evidence/wireguard-engine-03.md)。
