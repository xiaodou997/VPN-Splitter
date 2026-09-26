# WG-INT-09：原生转换与 packetFlow 桥接候选证据

日期：2026-09-26。起点 main ca1a25d99817817ed38b2dba6ddcc527eedd080b。任务 S1-03/04/05 部分；决策和运行前置条件见 [ADR](../adr/ADR-WG-INT-09-public-packet-flow.md)。

## 本批实际能力

新增 `ManagedWireGuardNativeInput`：08D 检查快照 → 固定上游解析器 → 真实 WireGuardKit 类型，并核对网络字段/顺序、参数、PSK 存在性与快照一致；每次生成独立引用。新增 `SplitterPacketFlowBackend`、真实 C 入口及 Go `tun.Device` 队列适配：读取来源固定为传入 Provider 的公共 packetFlow，不扫描 utun、不使用私有描述符、不创建系统接口。

候选调用实际 pinned wireguard-go `device.NewDevice` 与原生命周期注册表。该调用已写入构建源码，不是产品中的回显引擎。回显和所有框架替身仅位于 tests/packet_flow/fixtures，生产 staging 白名单不包含它们。只复用上游 UAPI 生成，网络设置仍必须由宿主先经 PolicyCore/ManagedSettings 应用，不使用上游默认路由生成器。

新增 `dev.sh engine-flow [--fetch]`，只构建/链接候选，不运行；原 `engine`、原描述符适配、旧锁与模块版本保留。新附加锁核对所有候选源码及固定上游 parser/helper/header；同时检查原有与新增 4 个 C 符号的定义，不把 undefined 引用算链接成功。

**正式 Provider 本批没有安装新后端，仍在 2001 阻断。没有新增用户可连接的 VPN 能力。** 新路径尚须接正式会话/真实网络状态/设置应用/撤销；不存在“桥接测试通过就可连接”的隐含开关。LocalDev、GUI、签名、App Group、ACL、实际用户配置与凭据未修改。

## 实际测试环境与结果

Linux x86_64，Swift 6.2.1，Go 1.23.2，Python 3.13.5。Go 1.23.2 仅用于独立标准库/替身测试；正式候选仍使用原锁允许的 Go 1.26.8/1.27.1，未安装或更改工具链。Mac Runner 返回 project_path_not_found，未借用无关项目。容器无网络下载，测试源码按固定 GitHub 基线恢复；这是部分源码目录，不是完整产品包构建。

| 已执行检查 | 结果 | 实际覆盖 |
| --- | --- | --- |
| 构建/staging/manifest/分发 | 9 项 Python unittest，通过 | 两种实际 create_probe 的生成及 Swift manifest 求值、真实 staging、哈希漂移/符号链接/冲突拒绝、新旧命令分发 |
| 包通道与转换 | 5 项 Python unittest，通过 | 下方 Go 和 Swift/C/Go harness，加原始上游 blob、源码边界和符号定义检查 |
| Go race harness | 同一 18 项通过，包含在上述 5 项中 | 实际队列/TUN 实现；12 项队列 + 6 项 pinned tun.Device 接口/offset/close；device/conn/lifecycle 为明确替身 |
| Swift → C → Go harness | 19 组场景通过，包含在上述 5 项中 | 实际 Swift 数据泵、C ABI、Go 队列/TUN和未修改上游 quick parser；框架、模型、admission、UAPI 生成器与加密引擎为明确替身 |

14 项 Python 与其内部 18/19 场景不可相加冒充 51 项独立测试。Swift harness 使用 Swift 6、warnings-as-errors 编译；没有 SwiftPM XCTest Debug/Release 全量包运行。复查后先分组运行 9+4+1 项全部通过，再以 `python3 -u -m unittest discover -s tests/packet_flow -v` 完整运行同一组 14 项，得到 `Ran 14 tests ... OK` 与退出码 0。较早的整组调用被工具执行窗口截断，不作为成功证据；最终跟踪同一验证进程至实际退出，没有遗漏失败或凭空累计测试。

关键执行场景：三类密钥保持、host bits 和 AllowedIPs 顺序、BOM/CRLF/off、原生投影不符、错误脱敏、双向 packet 往返、停止唤醒阻塞读取、旧回调不触碰新句柄、运行前/后失效、错误地址族/包长度、写回失败、重复回调、MTU/Peer 拒绝、解析失败、并发 stop、owner 释放、128 包背压。复查修复“失败关闭已取走句柄，随后主动 stop 提前返回”的问题；stop 现在加入已有关闭。队列不会无限保留报文；性能和实际系统分配并未测量。

完整 harness 输出明确包含：`queue_tun_cabi=ACTUAL upstream_parser=ACTUAL framework_models_admission_engine=TEST_DOUBLES network=NOT_APPLIED`。所谓往返是合成明文回显，不是 WireGuard 握手、加密传输、真实 NE 包收发或系统选路。原有引擎、08A–08D、AppCore/PolicyCore/ProviderSession/S1 套件本批没有累加计数。

新增 Swift 原生源还通过 arm64-apple-macos26.0 frontend parse；仅语法解析，不是 Apple SDK 类型检查。Bash/Python 语法和原始 build.py、roadmap、验收表基线 blob 已核对；上传前后的完整变更 manifest 另行核对。

## 复现与本地原生构建

```bash
/bin/bash dev.sh packet-flow-test
/bin/bash dev.sh engine-flow
```

packet-flow-test 需要本机已安装 Swift、Go 和 C 编译器；不下载依赖、不使用真实 Keychain、VPN 偏好或网络。独立测试的临时 go.mod 与替身不是生产模块锁，也不会替换它。engine-flow 使用已有验证缓存；缺缓存时明确停止，只有 `engine-flow --fetch` 允许获取固定公开源码/模块。候选产物不运行、不安装、不激活扩展。

普通 `engine` 仍是原描述符路径；`run` 仍 LocalDev；S1 unsigned 不会自动编入这个候选后端。不要用旧 unsigned 或旧 48eee07 通过来宣称本批原生链接通过。

## 未执行与下一项

Apple SDK 完整类型检查/链接、生产 Go 模块及真实 device/conn 的本批原生构建、真实签名/Keychain/XPC/GUI、WireGuard UDP/加密/握手、实际 packetFlow、双出口、停止路由/DNS 恢复全部 NOT RUN。原生 SDK 和引擎不是被替身“验收”了。

下一项是把新原生转换与公共 flow 后端安装到正式 Provider 的会话生命周期：提供实际 underlay/epoch 和明确 MTU，经网络设置成功回调后启动；连接取消/超时/授权撤销/切网均停止并独立观察设置撤销。新后端的 isCurrent 闭包不是实际网络观察器；空闲撤销须由宿主明确 stop。单独 stop 返回、队列清空或无密钥引用均不是系统恢复证据。

48eee07 用户报告的原生编译/链接/桥接符号 PASS 保留，仅覆盖原基线。没有读用户配置、操作真实 Keychain、安装工具、激活扩展或修改系统网络。main 非强制交付，无更新包；回滚使用后续 revert，保留用户数据、锁、缓存和历史证据。
