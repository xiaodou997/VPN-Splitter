# WG-INT-04：WireGuard Go 桥接层

本批继续使用原 WireGuard 协议引擎，只修改 Swift/C/Go 之间的调用和资源管理。代码已接入构建候选，不接入 LocalDev 或正式 Provider，不是可连接 VPN。

## 更新命令不变

```sh
git switch main &&
git pull --ff-only &&
/bin/bash dev.sh engine --fetch
```

engine 自带环境检查；缺工具时会停止，不自动安装、修改 PATH 或配置开发签名。仍沿用已有的 Go 候选版本，不增加语言、安装器或手工更新包。`--fetch` 明确允许下载固定公开源码与 Go 模块；缓存齐全后可使用 `dev.sh engine`，缺缓存拒绝，不偷偷联网补齐。Git 出现冲突先保留工作，不 force/reset/clean。

只继续操作界面时仍使用 `dev.sh run`，不需要编译 Go；界面版本仍是 LD-03B，已有策略和凭据格式不变。

## 本批变化

* 启动只有在配置和 Device.Up 均成功后才返回有效标识。失败关闭整个协议对象，不只关闭一个 fd。
* 未知或过期标识更新返回错误；更新出错后关闭可能部分修改的对象。不会把旧标识分配给新连接，也不会自动重连。
* 读取、更新、关闭及重绑按对象隔离。关闭取消重绑等待并等待其退出；连续网络通知合并为一个工作者，不对已关闭对象继续重试。
* 候选关闭 Go 的原始日志/栈输出和 Swift 指针回调。原始 wgGetConfig 仍含敏感信息，不是可导出的诊断接口；Swift 自身日志过滤仍未完成。

Darwin TUN 错误时接管并关闭复制文件的约定已按固定源码审查并入锁；桥接层不会再次关闭同一个数字 fd。真实 fd 所属 Provider、原生设备清理和系统路由恢复仍未验证。

## 构建结果

现有 engine 命令先核对源和桥接清单，自动运行 18 项 Go 生命周期测试，再进行 Go 静态库和 Swift 链接。测试使用内存设备，不创建接口或发送包；无需再手工记住一个测试命令。构建步骤自身不启动协议或运行 WGLinkProbe。

成功后才有：

```text
schema=wireguard-native-build-v1
compile_link=PASS
bridge_lifecycle_tests=PASS
artifact_execution=NOT_RUN
provider=NOT_LINKED
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
```

`bridge_lifecycle_tests` 只表示共享 Go 管理逻辑和内存替身通过；`compile_link` 表示真实编译链接，而不是连接、认证或分流。两项必须分开读。失败日志仍留在当次 `.local/wireguard-engine/build.*`；失败不产生 PASS，也不替换旧产物。

维护者可以单独执行 `GOENV=off GOWORK=off GOPROXY=off GOTOOLCHAIN=local go test -race -count=1 -timeout=60s tools/wireguard/bridge/lifecycle.go tools/wireguard/bridge/lifecycle_test.go`。它只需可用 Go 和 race 所需的 C 工具链，不等于通过本候选原生工具链检查。`dev.sh engine-test` 仍不要求 Go，也不执行这套 Go 逻辑，避免悄悄增加旧入口前置条件。

## 当前状态

本轮 Linux Go 生命周期及竞争测试、构建工具测试已执行，详见 [证据](evidence/wireguard-engine-04.md)。macOS Go/Swift 完整链接、真实 TUN 失败路径、Provider 停机/撤销、Keychain 和 VPN 尚未通过。底层调用卡住时协调器也可能等待；没有承诺强制停机或路由已撤销。

下一步先取得原生构建结果，再连接 Provider 的会话、正确 utun 身份、最新策略绑定和受控凭据交付；签名在首次真实隧道联调前恢复。原 .conf 和用户数据不改动，不上传真实配置或全量日志。
