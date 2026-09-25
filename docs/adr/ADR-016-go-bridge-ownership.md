# ADR-016：Go 桥接层的资源归属与单活动对象

日期：2026-09-26。状态：Accepted（WG-INT-04 构建候选，不批准真实运行或发行）。任务 S1-04/S1-06 部分；T-WGD01–05；Refs #1。承接 ADR-014/015，不改变签名、Provider 或 S0–S5 门槛。

## 依据和范围

保持官方 WireGuard 协议核心 revision `ecfc5a8d54462e18e13c72173e2623d16d8e25a0` 及依赖图不变。只适配官方 Apple `api-apple.go` 的 C/Go 桥接边界，不另写握手、加密、包处理或 AllowedIPs 算法。完整官方桥接基线保留于测试夹具，blob 为 `5d24982ac5b71ba0ab84afe972652a2d4f8549e5`；适配差异在 `0003-bridge-ownership.patch`，上游版权与 MIT 许可保留。

官方 [Apple bridge](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKitGo/api-apple.go) 未检查 Up 结果，未知 handle 的 SetConfig 返回 0，并在持有 Device 后直接关闭原始 fd。固定核心的 [Darwin TUN](https://github.com/WireGuard/wireguard-go/blob/ecfc5a8d54462e18e13c72173e2623d16d8e25a0/tun/tun_darwin.go) 会在 CreateTUNFromFile 的失败分支关闭传入文件；桥接层再次 close 同一个数字可能关闭被复用的 fd。本轮把该 TUN 文件 blob 纳入锁，不能以新版本名称推断同一归属约定继续成立。

## 决策

使用 `tools/wireguard/bridge/api-apple.go` 的薄适配及同目录 `lifecycle.go`。保持全部八个原 C 导出符号和参数类型；生产 factory 继续调用上游 Dup、SetNonblock、CreateTUNFromFile、NewDevice。借用 Provider fd，只关闭自己持有的复制品；交给 Darwin TUN 后不再手动关闭 raw fd，取得 Device 后失败由 Device.Close 释放。没有证明 fd 属于正确 Provider，该约束仍待完成。

生命周期协调器通过锁串行化 Start/Set/Get/Close 和单次 BindUpdate；一次只允许一个活动 Device。完成 IpcSet 和 Up 才发布非负标识。已发布的标识只增不复用，到 Int32 上限即拒绝新建，不绕回旧标识。失败初始设置或 Up 关闭整个 Device，不发布句柄；更新错误可能是部分更新，立即关闭并使句柄失效，返回非零错误。未知、已关闭标识不能成功更新。无直接恢复为旧配置或自动新建连接。

重绑保留最多十次尝试和 500 毫秒间隔，每个 Device 最多一个工作者。每次调用前重新核对同一对象；关闭先取消等待，再关闭对象，等待工作者离开。不会只依赖可复用的整数去认领新会话。锁和等待不提供强制取消：底层 BindUpdate/IpcSet/Close 卡住时仍需要未来 Provider 层的终止策略，不能称为有界停机。

候选关闭 Go 原始日志回调：wgSetLogger 保留 ABI 但不保留或调用 Swift 指针，设备日志使用 DiscardLogf，不注册 SIGUSR2 栈输出。Swift Adapter 自身日志仍须受控。wgGetConfig 保留已有敏感 ABI，可能返回密钥；绝不能作为日志或诊断导出。C 字符串上限 1 MiB，调用者必须提供有效可读指针；这不是内存指针安全证明。wgVersion 返回编译锁中完整核心 revision，不依赖同模块缺失的依赖版本条目。

## 构建和测试边界

桥接源、共享生命周期及测试源、安装器和可审查差异都记录哈希。先校验，再下载固定公开源；导出完整源文件仍按原 tree/blob 检查，staging 再核对原桥接 blob。只复制白名单三个文件到每次独立的 splitterbridge 目录；不覆盖上游缓存或既有产物。

原 `dev.sh engine [--fetch]` 内增加 `go test -race`，仅指定生命周期源码与内存设备替身，不编译/运行 C shim 或真正 Device；通过后才下载模块并继续 native build。测试失败停止，不生成 PASS。Go race 只覆盖执行到的竞争，不能证明不存在所有竞争，见 [Go race detector](https://go.dev/doc/articles/race_detector)。保持 `engine-test` 无 Go 前提，它只跑原 Swift/工具测试及新 Python 接线测试。

## 未关闭的门槛

真实 Darwin fd 交接、C ABI/静态库与 Swift 链接、Up/Close 在原生设备上的失败清理、阻塞调用终止、睡眠语义、utun 身份、凭据交付、敏感运行态配置和 Swift 日志、最新策略绑定、Provider 撤销观察，以及依赖许可/可达漏洞审查仍需完成。停止协议不等于撤销 OS 路由/DNS，也不提供 Kill Switch。候选不链接正式 Provider/LocalDev，开发签名继续暂停。

结果见 [WG-INT-04 证据](../evidence/wireguard-engine-04.md)。回撤用普通后继提交，不改写 main，不清空用户配置、Keychain、锁文件或构建目录。
