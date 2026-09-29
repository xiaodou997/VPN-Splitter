# EX-FLOW-01E：Developer ID 签名候选与 provider round-trip 诊断

日期：2026-09-29。基线 `2efe79f`。

## 目标

把 FLOW-01D 从“unsigned 构建 + providerReport 有/无”推进到可进行真实 macOS System Extension 联调的候选：显式 Developer ID/profile 构建、构建后二次验签，以及可区分 provider-message 失败阶段的脱敏诊断。

## 签名实现

`external-flow-build` 升级为 schema v3。默认仍 Release unsigned。只有显式 `--sign` 时才切换 DeveloperID configuration，并强制同时提供 identity、10 位 Team ID、主 App profile 名和 Extension profile 名。

生成 Xcode 工程的 DeveloperID target settings 分别绑定：

- `FLOW_APP_PROFILE_SPECIFIER`；
- `FLOW_EXTENSION_PROFILE_SPECIFIER`；
- `FLOW_DEVELOPMENT_TEAM`；
- `FLOW_DEVELOPER_ID_IDENTITY`。

构建成功后不只相信 xcodebuild：再用 codesign 检查 App/extension 的 exact identifier、TeamIdentifier、strict signature 和实际签名 entitlement。App 必须有 System Extension install entitlement；两者的 Network Extension entitlement 必须包含 `app-proxy-provider-systemextension`。任何一项不符都返回构建失败。

签名模式仍没有复制到 /Applications、open、OSSystemExtensionManager、startVPNTunnel 或 preferences 写入。产物只标 `LOCAL_DEVELOPER_ID_VERIFIED`、`system_acceptance=NOT_RUN`。

新增 `external-flow-signing-preflight`，只读枚举本机 Developer ID Application identity 和已安装 provisioning profile；profile 只有同时匹配 bundle ID、可选 Team ID 与 systemextension entitlement 才显示为候选，不输出 profile 文件路径/UUID/证书内容，也不修改钥匙串/Xcode。

## round-trip 状态

FLOW snapshot 新增有界 `providerMessageStatus`：

- `pass`
- `not_connected`
- `unsupported_session`
- `no_response`
- `send_failed`
- `invalid_response`

只有 `pass` 时 snapshot 才允许包含 providerReport；`pass` 无 report 或非 pass 携带 report 都被 wire 校验拒绝。主程序 Flow 页直接显示该状态。

## 验证

本批新增 Python 合同测试覆盖签名参数必须成组出现、Team ID 格式、构建器仍不存在安装/激活命令，以及只读 signing preflight 的 identity/profile 筛选纯函数。隔离容器中对 preflight identity/profile 纯函数做了最小复现，2 项通过；这不是完整仓库测试结果。

Apple SDK、Xcode Developer ID build、profile 接受、codesign entitlement 读取和 System Extension 激活均需要用户 Mac，因此保持 NOT RUN。Apple 文档确认 Developer ID Network Extension system extension 使用 `app-proxy-provider-systemextension`，容器 App 需要 System Extension install entitlement；真正 activation 还会校验 App 位于合适 Applications 目录、签名/entitlement/identifier 等条件。

## 下一事实门槛

1. Mac 运行 `external-flow-test` 与 unsigned `external-flow-build`，先关闭 Swift/Xcode 编译问题；
2. `external-flow-signing-preflight --team-id ...` 检查 identity/profile；
3. signed build 达到 `LOCAL_DEVELOPER_ID_VERIFIED`；
4. 手动把该签名 App 放入 /Applications 后，由 App 自身显式请求 activation；
5. 保存/启动 probe、产生少量 TCP 流、发布 snapshot；
6. 主程序读取 `providerMessageStatus=pass` 与 metadata 计数；
7. 只有这些通过才进入 FLOW-02 DIRECT copying。
