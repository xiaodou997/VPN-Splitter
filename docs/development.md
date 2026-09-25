# 统一开发入口与环境检查

当前为 WG-INT-03；从 `main` 拉取即可，历史补丁/ZIP 不需要处理。LocalDev 仍是 LD-03B，不接管网络。Python 仅做开发工具；Go 编译上游 WireGuard 引擎。最终应用不以用户安装这些编译工具为运行前提，正式发行包尚未提供。

## 现在先做什么

在仓库根目录执行：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash dev.sh doctor engine
```

遇到 Git 冲突就停止并保留本地修改，不 force/reset/clean。doctor 不拉取 Git、不联网、不安装、不创建构建目录、不访问配置或 Keychain；一次列出可检查的全部项目，而不是修完一个才显示下一个。Xcode/Go 只运行版本查询，子命令有时间上限；缺失 Python 时由外层 Shell 给出错误和下一步，不显示 Python traceback。

报告区分 `app_environment` 与 `engine_environment`。没有 Go 或 Go 版本不在候选范围，会阻止引擎构建，但不会把已满足条件的界面开发环境判为不合格。`compile_link=NOT_RUN` 始终显示：环境检查通过不是编译、运行或 VPN 验收。

## 日常只记 dev.sh

| 命令 | 行为 |
| --- | --- |
| `/bin/bash dev.sh` 或 `doctor` | 默认只读检查界面开发环境，同时把 Go 状态标为可选 |
| `/bin/bash dev.sh doctor engine` | 检查完整引擎构建环境，Go 是必需项 |
| `/bin/bash dev.sh run` | 原 LocalDev 构建/打开；不要求 Python 或 Go，不建立隧道 |
| `/bin/bash dev.sh test` | 原 AppCore/LocalDev 离线回归，需要 Python 和 Swift，不需要 Go |
| `/bin/bash dev.sh engine-test` | 本轮设置完成门控与构建工具/入口离线回归，需要 Python 和 Swift，不需要 Go |
| `/bin/bash dev.sh engine --fetch` | 环境检查通过后，下载固定公开源码/Go 模块并编译链接候选，不运行产物 |
| `/bin/bash dev.sh engine` | 同上但只用缓存，缺缓存拒绝；不偷偷添加 --fetch |

旧 `tools/localdev/build.sh`、`tools/managed/test.sh`、`tools/wireguard/build.sh` 仍有效。统一入口不自行提交或推送 Git，不自动运行 S0 路由实验、签名命令或 Keychain 验收，不配置全局 PATH/Xcode/Go。

## 缺工具时

界面构建需要 Apple Silicon/macOS 26+、完整 Xcode/SDK 26+。仅 Command Line Tools 不足以构建本工程。doctor/test/engine 工具需要 PATH 中的 Python 3.9+；仅打开和构建 LocalDev 不需要 Python。

引擎构建候选仍限 Go 1.26.8 或 1.27.1，读取 `third-party/wireguard-go/build-lock.json`，本轮没有更改这两个版本。开发机可从 [Go 官方下载](https://go.dev/dl/) 手动获取对应 macOS arm64 版本；版本依据 [官方发布记录](https://go.dev/doc/devel/release)（2026-09-26 复核）。Python 安装参考 [Python 官方 macOS 指南](https://docs.python.org/3/using/mac.html)。已有工具却找不到时，先重开终端并核对 PATH，不要为了构建绕过系统安全设置。

脚本不运行安装器、不使用 sudo、不自动升级 Go，也不自动下载 Go toolchain；保持 GOTOOLCHAIN=local。只运行界面开发时无需为本批安装 Go。用户同意技术路线不被解释为同意自动安装软件。

## 本批后端变化与未完成项

候选 Adapter 新增设置完成的线程安全门控。同步回调、重复回调、超时和迟到完成有独立处理；设置失败或超时不能继续启动协议。已知非零 wgSetConfig 返回码会报错，不再报告成功。发生不确定设置/更新后，Adapter 标记需 Provider 重建，停止其已知协议句柄和网络监视，拒绝在同实例直接重试。

**超时不是取消系统操作，停止协议也不是系统路由已撤销。** 本轮不以立即清空设置来假装回滚，更不创建新的 Adapter 自动重试；正式 Provider 的终止/撤销观察仍待实现与签名真机验证。Go bridge 的 Device.Up/部分资源清理、句柄归属、日志过滤、传递依赖安全和许可审查仍开放。

新 Swift 门控源与受控变换源码均记录在候选锁中，构建时检验后把同一 Swift 文件复制进隔离 WireGuardKit。原上游和第一阶段策略补丁的 SHA 约束保留；后端从未接入 LocalDev/正式 Provider，运行批准仍为 NOT_GRANTED。测试执行和未执行项见 [WG-INT-03 证据](evidence/wireguard-engine-03.md)。

新入口和这些候选源代码不改变工作区/凭据版本，不修改原 .conf，不激活扩展或改变路由/DNS。开发签名仍暂停。源码回撤使用后继提交，用户数据不需要清理或回滚。
