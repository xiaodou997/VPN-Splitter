# WG-INT-05：运行绑定、显式描述符与完整补丁链

日期：2026-09-26。基线 main `3a9a0616481fe7164bb5b576d0bca491392f0e87`。任务 S1-04/S1-06 部分；T-WGE01–05；Refs #1。[ADR-017](../adr/ADR-017-runtime-admission.md)、[操作](../wireguard-runtime-admission.md)。用户本轮只要求继续开发，没有新增引擎构建、Keychain 或 VPN 通过结果。

## 实现与范围

新增永久可失效的版本核对、显式描述符副本租约，并接入固定 Adapter 变换。Adapter 不再扫描 utun；构造时必须提供运行配置绑定及租约来源。接口和 Peer 快照在策略工厂边界隔离，Peer/AllowedIPs 顺序不按集合忽略；每次系统设置后、引擎调用前后继续复查，未发布的新句柄失效时先释放。停止/异常/释放使绑定失效，不在旧实例上恢复或替换绑定。

描述符租约在副本上查询类型/名称，只关闭自有副本；借用期间串行关闭。对端为 AF_SYSTEM、socket 为 SOCK_DGRAM、接口名匹配不证明真实 Provider 归属。生产描述符来源、完整 PolicyCore/凭据投影及控制层失效通知仍未接通。没有修改 Go 引擎、Go 桥、LocalDev、正式 Provider、数据格式、构建入口或工具链候选。

完整官方 Adapter 作为测试参考加入，保留版权及既有 MIT COPYING.reference。原文件 Git blob `f7be19b15f5cbe39fd0e6496cdf0b2d426d83b6b`，原策略阶段 `ecce2a45f1136eab99ebfd423577de2ccce543f7`；旧失败处理阶段 `f15679abbec8f219c450690e3f12aee70d2b11f4`；本批最终阶段 `d349ebe6eb7e07062cb1cf4007dada150465c008`。旧两份 review patch 与远端 blob 分别为 `c6483836eaf078e89c92771743024f484305d6d8`、`11d041c25b58dadee20348e584693d166f3bc5c1`，内容不变。

## 本轮实际执行

本地环境 x86_64 Linux、Swift 6.2.1。已连接的 Mac Runner 未暴露本项目路径，隔离验证目录请求被允许目录范围拒绝；未在其他项目绕过，也没有获得 Mac 原生结果。普通容器 Git 网络不可用，源代码通过 GitHub connector 读取并按 Git blob 重建。原 Support Package.swift、原 12 项测试、policy_hook、runtime_hook 和候选锁均核对到远端基线后再修改。

| 检查 | 本轮结果 | 限制 |
| --- | --- | --- |
| WireGuardSupport Debug，warnings-as-errors | PASS，29 tests | 原 12 项完整保留，新增 17 个函数，部分参数化 |
| WireGuardSupport Release，warnings-as-errors | PASS，29 tests | 同一生产源码与测试集优化构建 |
| 新增 test_admission.py | PASS，10 tests | 固定完整源码/补丁、接线、哈希拒绝及绑定逻辑 harness |
| 原/策略/失败处理/绑定三段 Swift 补丁 | PASS | 独立 git apply --check/apply，逐阶段字节核对，重复应用拒绝 |
| 共享支持源码 Swift 5 typecheck | PASS | Linux Foundation/POSIX，不是 Apple SDK |
| 最终 Adapter、Probe 单文件 Swift parse | PASS | 仅语法，不是 WireGuardKit/NE 类型检查 |
| 实际绑定类的可执行 harness | PASS | 编译相同 BINDING_SOURCE；上游配置类型是明确的替身，不是 WireGuardKit |

开发期间将含顶层 print 的 Probe 与 Adapter 一起 parse 的命令被 Swift 拒绝；随后按两个独立编译单元重新执行并通过，不计失败命令为 PASS。本轮没有执行全套 dev.sh engine-test、旧 48 项构建/桥接 Python 套件、tests/dev、Go race、AppCore 或 ManagedSettings；不把旧记录计入本次。原构建入口会自动发现新增测试，但这不是已运行整套入口的证据。

复现本轮已执行范围：

```sh
swift test --package-path Packages/WireGuardSupport -Xswiftc -warnings-as-errors
swift test --package-path Packages/WireGuardSupport -c release -Xswiftc -warnings-as-errors
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -p test_admission.py -v
swiftc -swift-version 5 -warnings-as-errors -typecheck Packages/WireGuardSupport/Sources/WireGuardSupport/SettingsCompletion.swift
swiftc -frontend -parse tools/wireguard/Probe.swift
```

T-WGE01：全部五项版本字段、当前值缺失、显式撤销、不可 ABA 复活、并发核对/撤销、成功设置完成不能授权过期会话。

T-WGE02：真实 POSIX dup/close/CLOEXEC、不同 owner 拒绝、检查失败释放副本、原 fd 保留、异常借用解锁、等待活动借用、重复关闭、释放对象、旧租约不可借新 fd。接口检测用明确替身；macOS 分支未执行，Linux 公共入口拒绝。

T-WGE03：完整上游、三段变换与原有补丁的一致性，最终哈希校验、漂移/重复应用/缺锚点拒绝；支持源码及变换锁保持有效。

T-WGE04：实际绑定类配合配置类型替身验证键/端点/DNS/MTU/端口/数组顺序变化、引用副本隔离、Peer 数量变化、名称非策略字段、失效及反射隐藏。该 harness 不是上游类型或 Apple SDK 通过证据。

T-WGE05：无扫描/无默认描述符来源、三个设置路径的后置检查、更新前后核对、未发布句柄释放、停止/异常/路径事件失效、探针仍不执行协议或系统设置的源码合同。

## 原生门槛与恢复

NOT RUN：完整 Go/Swift/Apple SDK 构建链接、新 socket 核对的 Darwin 行为、真实描述符所属 Provider、签名/NE/Keychain、握手/双出口/DNS/撤销。运行和发行批准仍为 NOT_GRANTED。门控检查不等于 OS 取消，停止协议不证明路由撤销，底层阻塞也无强制停止保证。实际控制层的版本观察/失效、fd 可信来源、配置/凭据投影、Swift 日志过滤和依赖审查继续开放。

权限及数据：没有安装工具、激活扩展、创建 TUN、联网运行协议、访问 Keychain 或修改路由/DNS。测试只用临时普通文件句柄和合成文本。用户工作区/原 .conf/凭据格式不变；源码回退用普通后继提交，不 force/reset/clean，不清空锁、JSON 或 .local。交付仍是 main，开发签名仍暂停。
