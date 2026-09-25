# WG-INT-03：统一环境入口、设置完成与失败隔离

日期：2026-09-26。基线 main `e48b7bd4b90f7f5231a29bfda6ba3183a5a33f9d`，tree `9eaab904fc738806d0531e1ed906304dceb2f25b`。任务 S1-04/S1-06 部分、DEV-01；测试 T-WGC01–04；Refs #1。用户仅同意技术路线并要求继续，没有新增 Mac/Keychain/引擎编译通过反馈。[ADR-015](../adr/ADR-015-settings-completion-and-dev-entry.md)、[操作](../development.md)。

## 实现

新增 dev.sh：默认只读聚合环境检查，run 不要求 Python/Go；doctor 区分 app 与 engine，Python 缺失/过旧时由 Shell 提示；缺 Go 不阻断界面。engine 先检查、再调用既有 build，默认没有 --fetch；错误参数和检查失败不继续。没有自动安装软件、Git 更新或系统配置改写。

新增 WireGuardSupport.SettingsCompletion：锁保护单次完成，独立信号和截止，同步/迟到/重复回调不产生虚假成功。构建候选新增第二阶段 Adapter 补丁：设置错误/超时、丢失 Provider、设置后引擎启动失败，以及非零 wgSetConfig 会终止正常成功路径；隔离当前实例，停止已知引擎句柄/网络监视，但不声称清理了系统路由。回调不捕获 Adapter，不自动重试。

门控源和 runtime_hook 源码 hash 纳入候选锁，构建时检验并复制同一门控源。既有原始 Adapter SHA、策略阶段 SHA、协议 AllowedIPs、Go 候选版本/依赖图、LocalDev、正式 Provider、PolicyCore/AppCore/ManagedSettings 生产代码均未更改。

## 本轮实际执行

环境 x86_64 Linux、Swift 6.2.1、Python 3.13.5、Go 1.23.2（本机 Go 不属于原生构建候选）。Mac Runner 返回 404 / tunnel_client_not_seen；容器普通 Git 下载无法解析 github.com。未安装额外工具或实际构建/运行 Go 引擎。

| 检查 | 本次结果 | 范围 |
| --- | --- | --- |
| WireGuardSupport Debug，warnings-as-errors | PASS，12 tests | 实际线程/信号/锁与超时逻辑 |
| WireGuardSupport Release，warnings-as-errors | PASS，12 tests | 同一源码优化构建 |
| tests/wireguard | PASS，37 tests | 原 28 项完整保留，加 9 项上下文/锁/复制/编排；构建调用用显式替身 |
| tests/dev | PASS，17 tests | 多缺项汇总、Go 可选性、失败停止、路径空格、显式下载、模式校验 |
| /bin/bash dev.sh engine-test | PASS，exit 0 | 实际顺序完成上述四组 |
| Linux doctor | 预期拒绝，exit 2 | app/engine BLOCKED、compile_link NOT_RUN；未运行 Apple 命令 |
| 新/补丁后 Swift 语法、Bash 语法 | PASS | 不是 Apple SDK 类型检查 |
| 门控源码 Swift 5 语言模式 typecheck | PASS | Linux Foundation；不是 WireGuardKit/macOS SDK 构建 |

旧构建工具 build.py、policy_hook.py、test_build.py、Probe.swift、build.sh 与原锁的本地重建分别核对到基线 blob；原 28 项测试没有删除或修改。第 1 份 reviewable patch 与远端 `c6483836eaf078e89c92771743024f484305d6d8` 一致。第二份变换使用真实目标片段审查和合成上下文夹具验证；本轮完整上游源本地重建未匹配原始 blob，因此不记作完整真实上游 apply PASS，也未将该重建 hash 写入原始锁。原上游和第一阶段输出 SHA 拒绝逻辑保持不变。真实源下载、完整两阶段应用和链接仍待 Mac 验证。

T-WGC01：同步成功/错误、无回调超时、截止后成功/错误、重复回调、独立请求、跨线程唤醒，50 轮并发完成及 50 轮截止竞争。真实 Swift 测试不调用 NetworkExtension。

T-WGC02：设置失败需重建标记、start/update/stop/路径处理不可复用、不自动系统回滚、更新返回码检查、上下文漂移/重复补丁/残余回退拒绝；属于源码合同，不是原生 Adapter 行为证明。

T-WGC03：helper/hook 锁和符号链接拒绝，错误先于下载/编译；显式编排替身检查先策略补丁再失败补丁，同一 helper 字节进入隔离工程，最终记录 hash / NOT_RUN / NOT_GRANTED。替身产物不是实际 Go 静态库。

T-WGC04：doctor 一次汇总多缺项且不回显原始错误，Go 不可用只阻断引擎，run 不经过 Python，root engine 不添加隐式下载、doctor 失败不构建，无工具安装；路径含空格与 Shell 参数验证。

## 未执行、恢复和下一步

NOT RUN：本批真实上游完整补丁应用、macOS arm64 Go/Swift 编译链接、原生完成回调/超时/错误与 Provider 生命周期、真实 Keychain、隧道/路由/DNS/双出口或撤销。此前 AppCore 202、ManagedSettings 26、PolicyCore 79 项及 LocalDev 旧套件没有重跑，相关生产代码未改；不借用历史 PASS。

无新权限、Go/Python 自动安装、工作区或凭据版本、实际 VPN/系统 DNS/路由变化。候选仍未获运行/发行批准。线程门控拒绝迟到成功，不证明迟到 OS 设置没有生效。仍需 Provider 终止/观察、Go bridge 返回值/清理、utun 归属、凭据交付、日志过滤、完整传递依赖审查和原生构建证据；签名在首次真实联调前恢复，目前暂停。

源码回退用普通后继提交，不改写 main；不清理用户 JSON、锁文件、.local、Keychain 或原 .conf。唯一交付仍是 main，不提供新的更新包。
