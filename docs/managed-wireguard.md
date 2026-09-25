# WireGuard 接入准备：WG-INT-01 / WG-INT-02

当前增加了 WG-INT-02 的**固定源码编译、强制策略入口补丁与 Swift 链接探针**；构建脚本和离线验证已提供，完整 Mac 构建链接仍待执行。不是可连接 VPN，也没有把核心接入正式 Provider。新版指南见 [核心构建](wireguard-engine-build.md)，结果见 [WG-INT-02 证据](evidence/wireguard-engine-02.md)。

## 从 main 获取

不需要历史补丁或 ZIP，不要求运行中间版本。LocalDev 界面仍为 LD-03B，原有启动入口不变。新增核心构建入口：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash tools/wireguard/build.sh build --fetch
```

此命令会先检查 macOS 26+ / arm64、完整 Xcode / SDK 26+、Python 3.9+ 和本机已安装的 Go 1.26.8 或 1.27.1。`--fetch` 明确允许下载固定公开源码和 Go 模块；不自动安装 Go，不申请签名，不运行产物或改用户网络。没有 Go 时会提前提示 E_GO。详细失败与缓存行为见 [构建指南](wireguard-engine-build.md)。

## 保留的 WG-INT-01 对象验证

```sh
/bin/bash tools/managed/test.sh
```

该独立入口不需要 Go，也不下载 WireGuard。它只执行 ManagedSettings Debug/Release 与源码检查；macOS 还会编译 ManagedSettingsApple 并执行四项原生对象测试，不安装到系统。无需 Team ID、profile、真实配置或 Keychain 授权。没有收到本轮用户执行结果，不把新脚本交付算作原生对象测试已通过。

## 网络设置层的职责

`Packages/ManagedSettings/Sources/ManagedSettings` 把真实 PolicyCore 约束结果转换为设置草稿。协议 AllowedIPs 只参与一致性核对，不作为系统路由来源。例如 Peer 是 `0.0.0.0/0`、Include 规则只有 `10.9.0.0/16 → VPN`，includedRoutes 只取该 /16，不自动加入接口整个网段或默认 VPN 路由。

Bypass 使用 /0 加显式 DIRECT 排除集合。输入的端点、接口地址、Peer 范围和完整上下文必须与编译结果一致，构造前再次校验。没有任何 VPN 区域或缺失基础设施约束时拒绝，不生成部分通过结果。first-match 语义不变，实际系统优先级尚未验证。

`ManagedSettingsApple.PacketTunnelSettingsFactory.makeForInspection` 只分配真实 Apple SDK 设置对象，不接收 Provider 或调用系统应用 API。DNS 显式选择保留系统或 Bypass 默认隧道 DNS，Include 不自动接管全 DNS；不创建搜索后缀，不提供名称映射。类型与字段依据 [includedRoutes](https://developer.apple.com/documentation/networkextension/neipv4settings/includedroutes)、[excludedRoutes](https://developer.apple.com/documentation/networkextension/neipv4settings/excludedroutes)、[matchDomains](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains)。

## 核心构建层的职责

WG-INT-02 使用独立编译候选锁、完整源码树和逐文件哈希验证，保留对应许可证。Apple bridge 使用已审查 Apple revision，Go 核心固定到官方 2026-05-22 revision，不继承旧 2023 Go 模块版本，也不运行修改 GOROOT 的上游 Makefile。模块校验不代表漏洞与完整传递许可审查通过。

Adapter 补丁强制 start/update/resume 提供策略设置工厂，缺失或抛错时没有上游路由回退；协议 UAPI 不变。探针仅用于类型检查与链接，函数不被执行，也不是可直接用于运行的配置绑定。详细边界见 [ADR-014](adr/ADR-014-wireguard-build-only-candidate.md)。

## 真实运行前仍要完成

Mac 原生编译/链接、模块安全与许可审查、设置超时/迟到回调和部分生效恢复、协议返回值与资源清理、utun 身份、凭据交付、日志和并发保护、实时上下文一致性仍需完成。上游的设置超时后继续和 update 忽略返回值**不在本轮补丁的修复范围内**，不能拿构建候选去连接 VPN。

现有 Provider 继续有意返回 1001，LocalDev 没有链接协议核心。首次受控 Managed 联调前再恢复开发签名和系统授权，之后验证 Include/Bypass 实际出口、DNS、IPv6 提示、失败与撤销。已有 Keychain 合成验收也仍需独立证据。源码撤回用后继提交，不重置工作区、Keychain、锁文件或原 .conf。
