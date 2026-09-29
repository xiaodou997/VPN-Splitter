# EX-FLOW-01F Mac 原生激活首试与公证门槛

日期：2026-09-29。起点：`main` `08e5ebb`。用户现场授权对本机 Flow Probe 做 pass-through 真机探针；原第三方 VPN 当时未开启。

## 实际观察

- `/Applications/VPN-Splitter-FlowProbe.app` 已由本次 Developer ID 构建复制，主 App 与嵌套 systemextension 的 `codesign --verify --strict` 均通过，App 正常开窗。
- App 的“检查配置”只读返回“未保存 Transparent Proxy 配置”。尚无 provider 配置或流量采集。
- 点击“请求激活 System Extension”后立即得到 `OSSystemExtensionErrorDomain#8`。本机 macOS SDK 将 8 定义为 `OSSystemExtensionErrorCodeSignatureInvalid`。
- 本机 `sysextd` 日志显示扩展已从 App 暂存到系统 staging 区，在 validating 阶段出现 `Error checking with notarization daemon: 3`，随后报告代码未满足指定要求并撤销暂存。`systemextensionsctl list` 没有本项目扩展。无系统批准弹窗、无 provider 启动。
- 首次本地签名产物的 App 与扩展均没有 Apple 安全时间戳，`spctl --assess` 显示 `Unnotarized Developer ID`。这与 [Apple System Extensions](https://developer.apple.com/documentation/systemextensions/) 的公证要求一致；日志支持“公证状态是当前阻断因素”的判断，但最终仍需以公证后重试验证。

## 已完成修复与下一关

- DeveloperID 构建为主 App 和 systemextension 加入 `--timestamp`；构建后二次验签现强制要求 `Timestamp=`。重新运行 `external-flow-build --sign` 输出 `compile_link=PASS`、`signing=LOCAL_DEVELOPER_ID_VERIFIED`，并实际观察两者的 Apple 安全时间戳。
- 时间戳版产物位于 `.local/external/flow.3ythwbqb/Products/DeveloperID/VPN-Splitter-FlowProbe.app`；只保存在本机的 `cert/flow-probe-notary.zip` 包含完整 App，供 Apple 公证服务提交。压缩包 SHA-256：`06a09be38814c3f0e482eb650e37610b6eb31f207de9fd5c150142e21e7aae77`。
- `external-flow-test` Debug/Release 与合同测试通过。用户在本机钥匙串保存了 App 专用密码，密码未进入仓库或聊天。`notarytool` 提交 ID 为 `bd469f63-d018-4c61-a8d0-dc2491d9840a`，服务端状态 `Accepted`、`Ready for distribution`、`issues=null`；提交归档 SHA-256 与上文一致。
- `stapler staple` / `stapler validate` 通过；`spctl --assess --type execute` 对 App 返回 `accepted`、`source=Notarized Developer ID`，同时报告本机 `override=security disabled`，因此不能把这一步单独当成默认 Gatekeeper 环境验收。嵌套扩展的 strict codesign 校验通过。已将旧 `/Applications` App 备份到 `.local/external/flow-prenotary-20260929.app`，并将已公证版本放入 `/Applications`，再次校验票据、`spctl` 与 strict codesign 通过。
- 公证后系统再激活与 Provider 探针结果仍待现场验证，不能据此宣称 Flow Bypass 可用。

## 首次公证后的系统校验与修复

- 用户现场确认后重新提交激活，系统返回 `OSSystemExtensionErrorDomain#9`（本机 SDK：`OSSystemExtensionErrorValidationFailed`）。`sysextd` 已通过代码签名阶段，但在 `validating_by_category` 明确指出网络系统扩展缺少 `NSSystemExtensionUsageDescription`；暂存扩展被撤销，`systemextensionsctl list` 仍无本项目扩展。没有保存或启动 Transparent Proxy 配置。
- 生成器原先只在主 App 的 `Info.plist` 写入该键；现已在扩展 `Info.plist` 补齐，构建器和合同测试都检查非空。`external-flow-test` Debug/Release 和合同测试通过；新 Developer ID 构建 `compile_link=PASS`，App 与扩展均严格验签和包含安全时间戳。
- 修复版归档 SHA-256：`4c3f88d5dcbe1881da74a9d9445c74b35e5dafdaa7fb6314d547e62d838b1e6a`。Apple 公证提交 ID `69af7033-ceb5-4102-a014-8a41b74b3ed1` 返回 `Accepted`；票据已附加并验证。修复版已安装到 `/Applications`，旧公证版保留在 `.local/external/flow-notarized-before-usage-description.app`。
- 用户再次现场确认后提交修复版激活，App 先收到 `requestNeedsUserApproval`；`systemextensionsctl list` 显示本项目扩展 `[activated waiting for user]`。用户随后在系统设置中批准；再次检查显示 `enabled=* active=*`、`[activated enabled]`，Probe App 收到“System Extension 已激活”回调。至此扩展签名、公证、系统批准的真机闭环通过。
- 激活完成当时，Probe App 只读检查仍显示“未保存 Transparent Proxy 配置”；尚未启用探针或触碰路由/DNS。下面记录随后单独授权的配置和探针操作。

## 无 VPN 基线：Transparent Proxy 与诊断桥

- 用户现场授权保存禁用配置后，Probe App 重新加载确认本应用配置数为 1、`enabled=false`、连接断开。点击发布脱敏快照得到 `providerMessageStatus=not_connected`，本机 `snapshot.json` 权限为 `0600`。
- 用户现场授权短暂启动 TCP metadata 探针后，重新加载显示 `enabled=true`、连接状态为 connected。首次 Provider message 返回 `pass`：累计 TCP 30、App Signing ID 可见 30、hostname 可见 9。
- 发起一条可控的 `https://example.com` HTTPS 请求，HTTP 状态 200；再次发送 Provider message 仍为 `pass`，累计 TCP 52、App ID 可见 52、hostname 可见 19、endpoint 可见 52、UDP 0。期间有其他后台流量，因此前后差额不能全部归因于这一条请求。快照只包含计数/状态，无真实 App ID、hostname、IP、端口或 payload。
- 这证明无 VPN 情况下 Provider 能启动、接收 TCP flow 并完成消息往返，不能证明第三方 VPN 共存或真实 DIRECT 出口。后续需用户开启第三方 VPN 再验；停止和移除配置为恢复路径。

## 第三方 VPN 共存与恢复

- 用户在 StrongVPN 客户端连接 VPN 后，`route -n get 1.1.1.1` 的接口由此前 `en0` 变为 `utun8`。Probe App 重新加载仍为 `enabled=true`、connected；Provider message 仍为 `pass`。请求前累计 TCP 422、App ID 422、hostname 154；`https://example.com` 返回 HTTP 200 后再次发布为 TCP 467、App ID 467、hostname 177、endpoint 467、UDP 0。后台流量并行，差额不代表该请求独占的 flow 数。
- 再次只读检查，测试目标仍由 `utun8` 出去。点击“停止探针”后连接变为 disconnected（配置仍 enabled）；随后点击“移除探针配置”，重新加载显示“未保存 Transparent Proxy 配置”。移除后测试目标仍走 `utun8`，普通 HTTPS 请求仍返回 HTTP 200。未操作第三方 VPN 的路由/DNS，也没有开启 DIRECT 数据面。
- `external-run` 重新编译并请求打开主 External 预览（`compile=PASS`），但本机 UI 自动化无法绑定该预览窗口。用户在“Flow 实验”页点击“读取最新本机报告”后反馈看到 `provider message=pass`、TCP 467、App ID 467、hostname 177；该 GUI 结果标为 **USER_REPORTED PASS**，不冒充自动化直接观察。Probe App 写出的测试快照权限为 `0600`，包含相同的脱敏计数。
- 由于移除配置后磁盘快照还保留测试时的旧 `connected/pass`，随后显式发布一次最终状态。实际快照现为 `configurationCount=0`、`configurationEnabled=false`、`connectionStatus=not_configured`，不再携带旧 Provider 计数；主程序下次读取不会误认为探针仍在运行。

## 门槛判断

FLOW-01F 的 Developer ID 签名、公证、systemextension 激活/系统批准、Transparent Proxy pass-through、Provider message、第三方 VPN 共存及安全停止/移除已有本机证据。这个试验只统计 metadata 是否出现：本次累计 TCP 467 中 App Signing ID 为 467、hostname 为 177（约 38%）。样本受后台流量和应用组合影响，尚未分解缺 hostname 的场景；也没有执行任何 Flow DIRECT、UDP/QUIC、DNS 语义或出口归属验证。进入 FLOW-02 前仍需设计受控的按应用/域名样本，确认 hostname 缺失时的规则处理。

没有关闭 SIP 或 Gatekeeper，也没有应用路由、DNS 或 Transparent Proxy 配置。原第三方 VPN 尚未开启；App ID/hostname 的真实可见性与 VPN 共存均未验证。
