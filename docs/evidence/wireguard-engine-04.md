# WG-INT-04：Go 桥接层归属、错误传播与并发回归

日期：2026-09-26。基线 `d42d683ad3e913779cf8e620708e35258193ffe5`，tree `db608105d2792aed98cfffd4851edd794860537d`。任务 S1-04/S1-06 部分，T-WGD01–05；Refs #1。[ADR-016](../adr/ADR-016-go-bridge-ownership.md)、[操作](../wireguard-bridge.md)。用户本轮只要求继续，没有新的 Mac/Keychain/引擎构建通过反馈。

## 实现

保持上游协议核心与依赖版本不变，新增薄 C/Go 适配与纯 Go 生命周期协调器。IpcSet/Up 成功才发布；失败后 Device.Close；单活动对象；标识不复用；未知 SetConfig 非零；部分更新失败关闭并使旧标识失效；重绑合并、取消、对象身份复核与工作者退出等待。没有另写 WireGuard 协议或改 AllowedIPs。

按锁定的 Darwin TUN 源码确认 CreateTUNFromFile 错误已关闭其传入文件，之后不再 raw-close 同一 fd；该文件 blob 已加入构建锁。关闭 Go 原始日志回调与 SIGUSR2 栈输出，但不声称 Swift 日志及原始 GetConfig 已完成安全诊断改造。候选仍不连接任何 Provider。

桥接三个 Go 文件、安装器与 review patch 均锁定。原 engine 命令增加共享生命周期 Go race 测试，失败不继续下载模块/原生编译；完整通过才在原成功结果里增加 bridge_lifecycle_tests=PASS。所有八个既有 C 导出符号都必须实际定义。没有新开发工具要求，也没有改 doctor/run/engine-test 的前置条件。

## 本轮执行

环境：x86_64 Linux，Go 1.23.2、Python 3.13.5。本机 Go 仅用于标准库生命周期测试，不作为 Go 1.26.8/1.27.1 原生候选通过证据。Mac Runner 返回 404 / tunnel_client_not_seen，普通 git 访问 github.com DNS 失败；没有下载核心/模块或运行真实 VPN。

| 检查 | 本轮实际结果 | 边界 |
| --- | --- | --- |
| Go 生命周期测试 | PASS，18 项 | 共享生产 lifecycle.go，设备为明确的内存替身 |
| go test -race -count=100 | PASS | 18 项重复 100 轮；真实线程/锁/定时器，非网络/真实 Device |
| Go 语句覆盖率 | 97.9% | 仅 lifecycle.go，不包含 C shim、Darwin TUN 或协议引擎 |
| Python WireGuard 工具回归 | PASS，48 项 | 原 37 保留，新增 11；编译命令为显式替身 |
| 官方完整 api-apple.go blob | PASS，5d24982ac5b71ba0ab84afe972652a2d4f8549e5 | connector 读取后重建并核对，未采用错误摘要代替源文件 |
| review patch 独立 git apply --check / apply | PASS | 在完整官方桥接文件上应用，逐字节等于生产适配文件；重复应用拒绝 |
| gofmt / go tool cgo | PASS | Go/C 语法与 cgo 生成，不是依赖包类型检查/原生链接 |

当前 build.py、policy_hook.py、runtime_hook.py、test_build.py、test_runtime.py、Probe.swift、build.sh、SettingsCompletion.swift、锁和旧许可/补丁都在修改前或作为不变依赖核对到远端 blob。旧 test_build 只调整编排顺序断言并改用完整固定桥接夹具，原 28 个测试未删除；test_runtime 的 9 项完整保留。

复现：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -v
GOENV=off GOWORK=off GOPROXY=off GOTOOLCHAIN=local go test -race -count=100 -timeout=60s tools/wireguard/bridge/lifecycle.go tools/wireguard/bridge/lifecycle_test.go
```

T-WGD01：工厂错误、非空错误对象释放、初次配置失败、Up 失败、无效/超限配置、单活动对象、64 并发开始、标识耗尽和旧标识不复用。

T-WGD02：更新未知标识、非零/零错误码、部分更新后关闭、读取失败/超限、同步更新与关闭序列化、重复关闭不二次释放。

T-WGD03：关闭取消长时间重绑等待并 join、十次上限、通知合并、成功只发一次 keepalive、30 轮并发读/改/重绑/关闭不接触关闭对象。race 只证明这些已执行路径未报告竞争。

T-WGD04：完整上游桥接 hash/差异应用、全部导出符号、源/安装器/差异漂移、链接父路径、文件集、版本身份、重复 staging 保留原文件，来源不符先于写入。

T-WGD05：资产异常早于公开下载；Go helper 测试失败不继续模块下载或编译；没有 Provider/界面接线；C shim 的 fd 移交与日志禁用只做源码合同，不算原生行为 PASS。

## 未执行和门槛

NOT RUN：Darwin 设备/fd 生命周期、C ABI 执行、完整 Go 静态库与 Swift/Apple SDK 链接、完整两阶段 Swift Adapter 补丁在原始文件上的本轮复验、真实 Keychain、签名 Provider 激活、协议握手/双出口、DNS 或撤销。没有重跑不变的 WireGuardSupport Swift 12 项、AppCore 202 项、ManagedSettings 26 项、PolicyCore 79 项或 tests/dev；不把历史结果计入本轮。

协调器不提供对阻塞底层调用的强制取消；停止协议不证明 OS 网络设置已撤销。正确 utun 身份、敏感配置/Swift 日志、受控凭据、运行期新鲜策略、Provider 终止观察、睡眠行为及传递依赖许可/可达漏洞审查仍开放。签名继续暂停，首次真实联调前恢复；runtime_approval 仍为 NOT_GRANTED。

权限/数据：没有自动安装、下载工具链、提升权限、创建隧道、修改路由/DNS/Keychain；本轮没有接入 LocalDev/正式 Provider。工作区与凭据格式不变，不碰原 .conf。源码回退用后继提交，不改写 main、不清空 .local/锁/用户数据。
