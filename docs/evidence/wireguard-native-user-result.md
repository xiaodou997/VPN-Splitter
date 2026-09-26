# WireGuard 原生构建：首次用户报告通过

日期：2026-09-26。状态：**USER_REPORTED PASS（编译和链接，不是 VPN 运行）**。
提交：`48eee077e071c6d684fb61934342b995200f66b3`（终端显示 `48eee07`）。
任务 S1-04 构建门槛；关联 WG-BUILD-FIX-01/02、WG-INT-05；Refs #1。

## 用户实际报告

命令：`/bin/bash dev.sh engine --fetch`。
环境检查：Apple Silicon、macOS/SDK 满足 26+、Xcode/Swift/Clang/Git 可用；
Python 3.12.9、Go 1.27.1。此次结尾没有精确的 macOS、SDK 或 Xcode 构建号，
不从先前失败日志推定此次成功运行的完整环境。

```text
schema=wireguard-native-build-v1
compile_link=PASS
bridge_lifecycle_tests=PASS
artifact_execution=NOT_RUN
provider=NOT_LINKED
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
```

用户给出的运行目录末段为 `.local/wireguard-engine/build.b85xjoqh`。
不收集用户名路径、原始配置、密钥、整个构建目录或签名资料。
未独立取得 result.json/产物并核查哈希；本记录来源是用户粘贴的终端结果。

## 可以确认与不能确认的内容

该提交的构建流程已在用户 Mac 上完成 Go 静态库、Swift/Apple 模块链接和
桥接符号检查；Go 生命周期测试通过，但该测试使用内存设备。
先前两处清单和 C 头文件错误不再阻断这次完整运行。
不再将此固定提交标为“完整原生编译尚未获得通过结果”，也不要求无理由重复。

没有运行产物、加载正式 Provider、进行 WireGuard 握手或真实分流，也没有
Keychain/系统路由/DNS/停止撤销证据。`provider=NOT_LINKED` 是当前预期边界。
本记录不能当作后续改动的 Mac 编译通过结果，不能关闭完整 S1 或签名门槛。

下一开发目标是把配置/凭据、规则计划、正式 Provider 和引擎组成最小 Include
连接链路；开发签名在首次真实联调前恢复。OpenVPN 与 External 仍未实现为可用后端。
