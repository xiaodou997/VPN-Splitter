# WireGuard 接入准备：WG-INT-01

本批从界面/模拟开发转向实际 NetworkExtension 设置对象的生成。代码已在独立包提供，尚未接通协议核心和 Provider，不是已经可以连接 VPN。

## 从 main 获取与验证

只使用 main，不需要历史补丁或 ZIP。此批不改变 LocalDev 界面版本，顶部仍为 LD-03B；没有新增连接按钮。Git 拉取不访问凭据或迁移数据。

```sh
git switch main &&
git pull --ff-only &&
/bin/bash tools/managed/test.sh
```

这个新入口运行 ManagedSettings Debug/Release 和源码合同检查。macOS 还会编译 ManagedSettingsApple、执行四项原生对象测试，只分配对象，不安装到系统。无需 Team ID、profile、真实配置或 Keychain 授权。正常 LocalDev 启动仍使用原来的 tools/localdev/build.sh；不要求重复旧 S1 检查。

成功输出包含 `schema=managed-settings-tests-v1`、`core=PASS`、`contracts=PASS`、`wireguard_engine=NOT_LINKED`、`network_settings=NOT_APPLIED`。`native_settings_objects` 在 Linux 为 NOT_RUN；在 Mac 全套成功后为 PASS。这一 PASS 只表示对象测试通过，不代表隧道、路由和出口通过。命令失败时即停止，不继续输出 PASS；不要上传整个 .local 或真实配置。

## 已交付的代码

`Packages/ManagedSettings/Sources/ManagedSettings` 将真实 PolicyCore 的约束结果转换为系统设置草稿。协议 AllowedIPs 只参与一致性核对，不成为路由来源。例如协议 Peer 是 `0.0.0.0/0`、规则只有 `10.9.0.0/16 → VPN`，Include 的 includedRoutes 只有该 /16，不变成全局 VPN，也不把接口所属整个 /24 自动加入 VPN。

Bypass 使用 /0 加显式 DIRECT 排除集合。输入中的全部端点、接口地址保护都必须存在且无多余旧项；系统设置构造前再次核对完整输入。没有任何 VPN 区域时拒绝生成，缺失约束或超范围规则也不会生成“部分可用”结果。原规则顺序和 first-match 保持不变。

`ManagedSettingsApple.PacketTunnelSettingsFactory.makeForInspection` 实际创建 Apple SDK 对象，填充地址、掩码、包含/排除路由、显式 DNS 选择和 MTU。它不接受 Provider，也没有调用 setTunnelNetworkSettings。Apple 类型只出现在独立 macOS target，没有侵入纯 PolicyCore 或普通 LocalDev。

DNS 显式区分“不设置本隧道 DNS，保留系统选择”与“Bypass 的默认隧道 DNS”。不从导入字段自动推断隐私选择，不创建搜索后缀，不提供域名映射或查询；Include 的默认全 DNS 被拒绝。引用：[Apple includedRoutes](https://developer.apple.com/documentation/networkextension/neipv4settings/includedroutes)、[excludedRoutes](https://developer.apple.com/documentation/networkextension/neipv4settings/excludedroutes)、[matchDomains](https://developer.apple.com/documentation/networkextension/nednssettings/matchdomains)。对象字段与路由表示已可测试，系统实际优先级和 resolver 行为仍未验证。

## 固定的上游审查基线

`third-party/wireguard-apple/reference.json` 固定官方 revision `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1` 和五个源文件 Git blob。保留对应 MIT 许可副本；没有复制协议源码、下载依赖或接入新的 SwiftPM/Go 构建依赖。此旧源码基线的 Go 依赖版本只是记录，不推荐直接用于发行；完整依赖、许可证、安全与现代工具链兼容性须另审查。

当前上游 [Package.swift](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Package.swift) 依赖 wg-go 静态库，[集成文档](https://github.com/WireGuard/wireguard-apple/tree/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1#wireguardkit-integration) 要求单独构建 Go bridge，不能把 Swift package 解析成功当成协议核心构建完成。

源码审查发现：[WireGuardAdapter.swift](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Sources/WireGuardKit/WireGuardAdapter.swift) 在网络设置等待 5 秒未完成时仍继续，在 update 路径未检查 wgSetConfig 返回码；macOS 切网只调用 wgBumpSockets。它还扫描 utun 描述符并输出端点解析日志。这些行为不能直接继承为“设置成功、身份正确、恢复完成”的证据。

## 接下来要打通的部分

1. 构建经过版本、许可证与安全审查的 WireGuardKit/Go bridge；在 start、update 和 restart 接入必选的策略设置生成入口，不允许回落到 AllowedIPs 默认路由生成器。
2. 处理设置超时、协议更新失败、迟到回调和部分设置已生效的恢复；绑定正确 utun、提供受控凭据交付及日志过滤，不枚举或输出密钥。
3. 本地 unsigned 编译通过后，恢复开发签名进行首次真实 Provider/WireGuard 联调；随后验证 Include/Bypass 双出口、DNS、IPv6 提示、失败与撤销。现有 Provider 仍保留故意返回 1001 的行为。

以上都是未完成门槛，不会因本批对象工厂和离线测试关闭。现有 Keychain 原生合成验收也仍需独立证据。本批不新增模拟场景，不改变已经确认的界面布局。
