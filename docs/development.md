# 统一开发入口与当前开发状态

当前为 WG-INT-07；从 `main` 更新，不需要历史补丁或 ZIP。
**48eee07 的 Mac 原生编译链接已获用户报告通过。** 详见[独立记录](evidence/wireguard-native-user-result.md)。
这不是运行结果，也不能代替后续代码的原生验证；无需重复证明同一提交的同一结果。

当前继续开发配置与规则到真实后端的连接路径，不是只剩测试或签名。
本批新增[Provider 会话控制与一次性配置交付](wireguard-session.md)，将已组装 Adapter 的
start/stop 接入可测试控制器。生产跨进程凭据读取、可信描述符与正式 Provider 尚未连通。
LocalDev 仍是 LD-03B，不接管网络。
OpenVPN 和应用内 External 后端尚未实际接入。真实握手、双出口、DNS 和撤销仍待验。

## 日常只记 dev.sh

| 命令 | 行为 |
| --- | --- |
| `/bin/bash dev.sh` 或 `doctor` | 只读检查界面开发环境，Go 标为可选；不下载、不构建 |
| `/bin/bash dev.sh doctor engine` | 汇总引擎构建环境缺项；Go 是必需项，不安装工具 |
| `/bin/bash dev.sh run` | 原 LocalDev 构建/打开；不要求 Python 或 Go，不建立隧道 |
| `/bin/bash dev.sh test` | 原 AppCore/LocalDev 离线回归，需要 Python/Swift，不需要 Go |
| `/bin/bash dev.sh engine-test` | WireGuardSupport、ProviderSession 和 Python 构建/入口回归；不执行 ManagedSettings/Go 测试，不需要 Go |
| `/bin/bash dev.sh engine --fetch` | 环境检查、固定公开源码下载、Go 生命周期测试、模块下载、原生编译链接；不运行 VPN 产物 |
| `/bin/bash dev.sh engine` | 同上但只使用缓存；缺缓存拒绝，不自动添加 --fetch |

原 `tools/localdev/build.sh`、`tools/managed/test.sh`、`tools/wireguard/build.sh` 仍有效。
新 ManagedSettings 组装测试由 `tools/managed/test.sh` 自动发现；Mac 还运行原生设置
对象测试，只分配对象，不安装设置。原生组装源由 engine 自动加入隔离探针编译。

需要更新并验证新的原生接线时，仍执行：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash dev.sh engine --fetch
```

Git 出现本地修改冲突或无法快进时保留工作并停止，不 reset、clean 或 force。
统一入口本身不执行 git pull/提交/推送；不自动安装软件或更新全局 PATH/Xcode/Go。
仅有 `engine_environment=PASS` 是环境检查，不是编译。完整成功仍以
`compile_link=PASS` 为准；`artifact_execution=NOT_RUN`、`provider=NOT_LINKED` 是预期边界。
`bridge_lifecycle_tests=PASS` 来自同一生命周期源码和内存设备，不是 VPN 认证。

## 环境与文件边界

界面/引擎要求 Apple Silicon、macOS 26+、完整 Xcode/macOS SDK 26+、Swift 6+。
Python 3.9+ 只用于开发工具。引擎构建沿用锁文件中的 Go 1.26.8/1.27.1；本批
不增加语言或安装要求。缺工具由 doctor 汇总，Shell 处理 Python 缺失/过旧；
Go 不可用不阻断 `dev.sh run`。已安装但找不到时先检查 PATH 或重开终端。

工具安装由用户明确操作；参考 [Go 官方下载](https://go.dev/dl/) 和
[Python macOS 指南](https://docs.python.org/3/using/mac.html)。脚本不使用 sudo、
不运行安装器，不自动下载 Go toolchain，保持 GOTOOLCHAIN=local。
--fetch 只允许固定 WireGuard 官方源、Go 模块代理/校验服务及服务重定向；
不关闭 TLS/模块校验，不绕过网络策略，不读取用户 VPN 配置或 Keychain。

失败结果留在当次 `.local/wireguard-engine/build.*`，不以旧产物顶替失败。
不编辑或删除旧构建目录、源码缓存、build.lock、工作区 JSON 或 Keychain 来处理
构建失败；锁在进程退出时释放，文件保留。错误只需反馈阶段和片段，不上传全量日志。

## 下一阶段门槛

正式 Provider 的配置/凭据交付、可信隧道来源、失效控制和停止后的设置撤销仍未完成。
显式描述符名字一致不是所属 Provider 的证明；版本复核不是系统观察器；
停止协议不证明路由已撤销，超时也不取消已提交的 OS 操作。
开发签名在首次真实 Managed 联调前恢复，发行签名/公证/DMG 留到发行验证。

本轮不改工作区/凭据格式、原 .conf、UI、正式 Provider、Go 核心或已有补丁链。
源码回撤用正常后继提交，不改写历史。新测试和未测项见
[WG-INT-07 证据](evidence/wireguard-session-07.md)与[ADR-019](adr/ADR-019-provider-session-control.md)。
