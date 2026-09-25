# WireGuard 核心构建与 Swift 链接探针

当前 WG-INT-03 在 WG-INT-02 构建流程上增加统一环境入口和设置失败门控。目标仍是验证 Go 静态库及 Swift/Apple 类型的构建链接，不是可连接或可发行的 VPN。完整 Mac 构建尚待验证；见 [统一入口](development.md)、[最新证据](evidence/wireguard-engine-03.md) 与 [ADR-015](adr/ADR-015-settings-completion-and-dev-entry.md)。历史构建决策和结果保留在 [ADR-014](adr/ADR-014-wireguard-build-only-candidate.md) 与 [WG-INT-02 证据](evidence/wireguard-engine-02.md)。

## 从 main 更新

不需要历史补丁或 ZIP。保留本地修改，Git 无法快进时停止，不强制覆盖：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash dev.sh doctor engine
```

只读检查会一次列出环境缺项，不安装或下载。条件仍是 macOS 26+ / arm64、完整 Xcode/SDK 26+、Python 3.9+、PATH 中的 Go 1.26.8 或 1.27.1。Go 版本来自候选锁，本轮未升级。缺 Go 仅阻断引擎构建；`/bin/bash dev.sh run` 不要求 Python 或 Go，仍能构建普通 LocalDev。

条件满足后使用：

```sh
/bin/bash dev.sh engine --fetch
```

旧的 `/bin/bash tools/wireguard/build.sh preflight` 与 `build --fetch` 仍有效。统一入口不自动安装 Go、不切换 Xcode、不配置团队或全局 PATH。

`--fetch` 明确允许从固定 WireGuard 官方 GitHub 镜像、proxy.golang.org、sum.golang.org 及服务重定向下载公开源码/模块。初次构建可能较久；省略该参数时只使用缓存，缺少缓存即停止。不读取或上传 VPN 配置，不关闭 TLS 或模块校验，不绕过网络策略。

## 构建做什么

先校验原始源码 revision/tree/逐文件 Git blob，再在隔离目录依次应用强制策略入口和设置失败门控变换。相同的已测试 Swift 门控源经锁校验后复制进 WireGuardKit；遇到同名文件或源码漂移拒绝。原始 Adapter 和第一阶段 patched blob 约束不变。

Apple bridge 放在固定 Go 核心模块的独立 main 子包中，按核心自身 go.mod/go.sum 构建 arm64 libwg-go.a；不运行旧 Makefile、不修改 GOROOT、不自动选择或下载 Go 工具链。随后 SwiftPM 链接 WireGuardKit、ManagedSettingsApple 和 WGLinkProbe，并检查静态库/探针中桥接符号是实际定义，而不是未解析引用。

Adapter 必须显式接收策略设置工厂，start/update/resume 不回退到 AllowedIPs 默认路由。第二阶段代码让设置错误/超时、缺失 Provider、设置后引擎启动失败以及非零 wgSetConfig 结果结束正常成功路径，标记当前实例需 Provider 重建；不自动重试。同步/重复/迟到回调由独立门控处理。

**等待超时不代表系统请求已取消，协议停止也不证明路由已撤销。** 正式 Provider 的终止和撤销观察仍未实现；候选不可直接运行。Go bridge 的 Device.Up、未知句柄、部分资源清理、utun 身份、日志与凭据交付仍有开放项。真实上游两阶段完整应用及原生链接仍需实际构建验证，离线上下文测试不替代它。

脚本不运行 WGLinkProbe，不打开 App，不创建/激活扩展，不启动协议，不访问 Keychain 或申请 root。LocalDev 与正式 Provider 不链接此候选；界面仍为 LD-03B，已有用户数据不迁移。

## 查看结果

所有原生构建与符号检查通过才输出：

```text
schema=wireguard-native-build-v1
compile_link=PASS
artifact_execution=NOT_RUN
provider=NOT_LINKED
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
```

`.local/wireguard-engine/build.*` 每次独立输出；result.json 记录实际工具版本、源码 revision、补丁后/门控源码/产物哈希以及 runtime_approval=NOT_GRANTED。失败保留本次目录和错误，不借用旧产物，不输出成功结果。锁文件不删除，进程退出释放锁。日志可能含本机路径，反馈首个错误片段即可，不上传整个目录。

不需要 Go 的本轮离线回归入口是 `/bin/bash dev.sh engine-test`。它执行门控 Debug/Release 和 Python 构建工具/入口测试，不运行真实引擎，也不能证明 Apple 系统行为。

## 运行前门槛

编译链接 PASS 仍不表示握手、分流、DNS 或安全停止通过。完整传递依赖许可证及可达漏洞评估、Go bridge 清理、正确 utun 与运行配置绑定、受控凭据交付、Provider 事务和原生证据仍须完成。开发签名继续暂停，首次真实 Managed 联调前恢复。不要清空用户 JSON/Keychain、手改版本或删除锁文件来解决构建和凭据问题。
