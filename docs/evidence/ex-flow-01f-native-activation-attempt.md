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
- `external-flow-test` Debug/Release 与合同测试通过。公证凭据尚未建立，公证提交/票据/系统再激活仍为 **NOT RUN**。

没有关闭 SIP 或 Gatekeeper，也没有应用路由、DNS 或 Transparent Proxy 配置。原第三方 VPN 尚未开启；App ID/hostname 的真实可见性与 VPN 共存均未验证。
