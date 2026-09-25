# WG-INT-02：构建 WireGuard 核心与 Swift 链接探针

这一步验证真实 Go 静态库和 Swift/Apple 类型的构建链接，不是再增加模拟场景。脚本及受控补丁已提供；本轮尚无 Mac 上的完整构建结果，不代表隧道已经可用。决策见 [ADR-014](adr/ADR-014-wireguard-build-only-candidate.md)，测试范围见 [证据](evidence/wireguard-engine-02.md)。

## 从 main 更新

不需要任何历史补丁或 ZIP。保留本地源码修改；拉取无法快进时停止，不强制覆盖：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash tools/wireguard/build.sh build --fetch
```

前置条件：macOS 26+、Apple Silicon、完整 Xcode/macOS SDK 26+、Python 3.9+，以及已安装并位于 PATH 的 **Go 1.26.8 或 1.27.1**。只检查环境可执行：

```sh
/bin/bash tools/wireguard/build.sh preflight
```

没有 Go 或版本不匹配会在下载和创建构建目录前停止并提示 E_GO；本脚本不安装 Go、不切换 Xcode、不配置开发团队。候选版本依据 [Go 官方发布记录](https://go.dev/doc/devel/release) 固定；未来版本需显式审查更新锁文件，不自动升级。

`--fetch` 表示允许下载固定版本的公开 WireGuard 源码及 Go 模块，初次构建可能需要较长时间。下载源固定为 GitHub 上 WireGuard 官方镜像、proxy.golang.org 和 sum.golang.org（以及服务自身的下载重定向）；不读取或上传用户 VPN 配置。缓存齐全后可省略 --fetch，缓存不足则拒绝，不偷偷联网补齐。网络代理或公司策略不允许访问这些服务时正常报错，不关闭 TLS 校验，也不绕过策略。

## 构建做什么

先核对源码 commit、tree、全部导出文件的 Git blob；在隔离快照应用固定 Adapter 补丁。Apple bridge 与更新的官方 Go 核心按该核心的 go.mod/go.sum 构建 arm64 `libwg-go.a`，不运行上游修改 GOROOT 的 Makefile。随后 SwiftPM 链接 WireGuardKit、ManagedSettingsApple 和 WGLinkProbe，检查静态库与最终探针中的 wgTurnOn / wgTurnOff / wgSetConfig / wgGetConfig / wgBumpSockets / wgVersion 定义。仅有未解析的符号引用不算成功。

补丁要求 Adapter 构造时显式提供策略设置工厂，start/update/resume 不再回落到上游 AllowedIPs 路由生成。只是入口编译准备，尚未验证真实控制器、最新网络快照、错误恢复或退出撤销。

**脚本不运行 WGLinkProbe，不打开 App，不创建/激活扩展，不启动协议、不申请 Keychain 或 root。** 正式 Provider 和 LocalDev 均不链接这份候选，所以界面仍为 LD-03B；原来的 LocalDev 启动和 ManagedSettings 测试入口不变。

## 查看结果

所有步骤通过后才输出：

```text
schema=wireguard-native-build-v1
compile_link=PASS
artifact_execution=NOT_RUN
provider=NOT_LINKED
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
```

日志和结果位于每次单独创建的 `.local/wireguard-engine/build.*`。`result.json` 记录实际 Go/Xcode/SDK/Swift 版本、源码 revision、补丁后哈希和产物哈希。日志可能含本机路径，不要上传整个目录；反馈阶段与错误片段即可。失败运行没有 result.json PASS，目录中的失败产物不可用。锁文件保留，退出进程释放锁；不要删除锁来强行并行。中断留下的目录不自动清理或复用为成功产物。

## 后续门槛

完整 Mac 构建和链接仍待执行；即使 PASS，也只证明编译链接，不证明握手、分流或安全停止。候选核心的传递依赖许可及可达漏洞评估、上游设置超时/返回值/资源清理、正确 utun 绑定、真实凭据交付仍是运行前任务。普通本地开发界面和已有数据不迁移；开发签名继续暂停，首次真实 Managed 联调前恢复。
