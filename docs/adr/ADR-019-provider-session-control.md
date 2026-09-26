# ADR-019：单次 Provider 会话控制与进程内配置交付

日期：2026-09-26。状态：Accepted（实现/编译候选，不批准网络执行）。
任务 WG-INT-07 / S1-03、S1-04、S1-05 部分；T-WGG01–05；Refs #1。
承接 ADR-018。用户要求继续开发；没有新增对 67cac05 的原生验证反馈。

## 决策

新增独立纯 Swift ProviderSession，而不复用 LocalDev 的模拟状态来代表真实连接。
每个控制器只接受一次启动；Provider/会话/策略/凭据引用/归属 nonce/配置版本/网络
版本绑定到一次尝试。身份闭包是控制层提供的当前值，不是本模块的系统观察。
加载接口只传递不透明身份；资源对象在 start 前不得启动隧道或应用设置。

控制器 MainActor 串行处理回调，带独立加载/启动/停止期限（15/20/10 秒默认值，
可降低或调整但不得超过 300 秒）。定时器只是唤醒，结果处理还检查单调时钟，
不依赖定时器调度顺序。MainActor 或底层同步调用阻塞时不承诺强制截止。
取消加载后拒绝迟到对象；取消启动后立即撤销绑定，但等启动回调确定后再排停机。
重复回调不能多次完成请求，最多保留 16 个停止等待者，不自动开启下一会话。

后端停止确认与系统撤销分开。无回调或报错为 cleanupUnconfirmed；停止成功为
awaitingSystemTeardown，不自动改为 disconnected/idle。单独且身份匹配的系统
观察才允许 closed。超时后的迟到结果继续清理，但不改写已返回的错误。
主进程/Provider 实例终止策略和观察器仍待实现；本批不使用清空设置假装回滚。

新增 ManagedWireGuardSession：一次性配置对象 -> 已有 ManagedWireGuardAssembly
-> 真实 WireGuardAdapter.start/stop -> 同一控制器。Delivery 不 Codable、不输出
配置或密钥，描述与反射隐藏内容；消费/放弃后释放额外引用，不能重复用于连接。
它不是认证凭据：必须由未来可信 vault 验证完整记录后创建，不接收未验证 IPC。
不放宽 LocalDev Keychain ACL，不让正式 Provider 自动枚举/读取 LocalDev 凭据。
本批没有提供生产共享 Keychain 读取器，也没有更改旧凭据格式或导入行为。

## Apple 生命周期依据

Apple [startTunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/starttunnel(options:completionhandler:))
说明成功完成前应完成设置；[stopTunnel](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider/stoptunnel(with:completionhandler:))
说明停止完成时才回调，Provider 内发起停止应使用 cancelTunnelWithError。
本批的后端完成回调不直接冒充这两个系统完成回调，正式接线仍须实现。

## 门槛与后果

新源加入 engine 的隔离探针编译，但不运行；S1 Provider 保持拒绝未实现连接。
不添加新语言、远端依赖或工具链版本；Go 核心和前序补丁不变。代价是还有受控
凭据源、可信 fd/包通道、真实 Provider 回调桥、系统撤销观察与签名要完成。
原生编译结果仍按提交区分；48eee07 的用户 PASS 不覆盖本次新增代码。
