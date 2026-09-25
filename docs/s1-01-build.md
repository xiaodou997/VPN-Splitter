# S1-01：最小 App + Packet Tunnel System Extension

日期：2026-09-25。代码已提供；Xcode 编译、真实签名、加载及发行公证尚待 Mac 验证。后续使用 main，不再要求切换 S0/S1 分支。**合并不是验收通过。**

## 1. 本阶段验证什么

两个 target：`VPN-Splitter` App 与 `PacketTunnel` system extension；本地静态链接 PolicyCore。无 WireGuard/OpenVPN 依赖、没有路由 Helper、没有共享 Keychain/App Group 或自定义 XPC listener。

验证链路：构建 -> 检查签名/描述文件 -> 用户安装 -> 用户批准激活 -> 用户保存本测试配置 -> 明确请求 Provider -> 日志 `S1_PROVIDER_REACHED` -> 有意返回 `VPNSplitter.S1 / 1001` -> 移除测试配置、停用本扩展。

Provider 不调用 setTunnelNetworkSettings、不读写 packetFlow、不发网络请求、不返回连接成功。启动错误不是 Kill Switch，也不是可用 VPN。操作系统可能在启动过程产生临时接口或系统事件，不宣称系统完全没有变化。单独出现连接失败、激活成功、HTTP 可访问均不能代替 Provider 日志证据。

## 2. 工具链与无签名编译

需要 arm64 Mac、macOS 26+、完整 Xcode（macOS SDK 26+），已接受 Xcode 许可及完成首次安装。只装 Command Line Tools 不够。具体 Xcode/SDK/Swift build 由本机记录，不预设“最新”。无需 Homebrew/XcodeGen；工程已经提交，`generate-project.py` 只用于维护一致性。

在没有未保存代码修改的原仓库内更新 main：

```sh
git fetch origin
git switch main
git pull --ff-only origin main
/bin/bash tools/s1/build.sh preflight
/bin/bash tools/s1/build.sh unsigned
```

每条成功后再执行下一条。有修改/冲突时先保留本地工作，不 reset/clean。preflight 会记录工具链并尝试 `xcodebuild -list`；unsigned 首次进行真实 App/扩展类型检查和构建，**产物不可安装或激活**。两步都不修改系统网络、不调用 sudo、不安装 App。

结果在权限 700 的 `.local/s1/<mode>.XXXXXX`，日志含本地路径/签名信息，未经脱敏。只反馈 `share-summary.txt` 和必要的错误行；不上传整个目录。`exit_code=0` 在这里只表示本步完成，不是签名、扩展加载或 VPN 已通过。`toolchain.private.txt` 中版本号可以人工摘录，去掉路径。

## 3. 开发签名

需要可为两个 bundle ID 授权 Network Extensions 的 Apple Developer 团队、有效 Apple Development 签名身份及配置描述文件。App 还需要 System Extension 安装能力。系统弹窗、账号/协议未就绪、权限不足均保持 BLOCKED，不关闭 SIP/Gatekeeper 或绕过 MDM。

```sh
cp apps/macos/Config/Signing.local.xcconfig.example apps/macos/Config/Signing.local.xcconfig
open apps/macos/VPN-Splitter.xcodeproj
```

仅在本机编辑 `VPN_DEVELOPMENT_TEAM`；可在注册 App ID 前改 `VPN_APP_BUNDLE_ID`，扩展 ID 自动加 `.PacketTunnel`。检查两个 target 的 Signing & Capabilities，选择同一团队。Debug/Release 使用 Automatic + Apple Development；必要的账号登录和描述文件获取在 Xcode 内由用户完成。构建脚本不会自动创建账号资源或使用 `-allowProvisioningUpdates`。

准备好后：

```sh
/bin/bash tools/s1/build.sh development
```

构建后自动运行 `verify-bundle.py`，检查 App/扩展布局、arm64、签名类型/同团队、Hardened Runtime、NE entitlements、两个嵌入描述文件的 ID/过期时间/授权。这是本地结构检查，不替代系统加载或 Apple 公证。脚本验证失败先查具体固定 reason，不要把失败改成 PASS。

## 4. 安装、激活与受控启动

此节是真机系统状态操作，**只在本地控制台和授权测试环境执行**。先结束其他 VPN/手工实验；App 不会替你停掉别人的 VPN，也不能检测所有第三方强制机制。

从构建输出的精确路径，用 Finder 复制 `VPN-Splitter.app` 到 `/Applications`。已有同名 App 时先核实版本和本测试配置状态，不能盲目覆盖。应用会拒绝从 DerivedData、Downloads 或其他位置激活。Xcode scheme 默认 Build/Run 不自动复制到 Applications，也不申请授权；本阶段请从 Applications 打开。

在另一个本地终端查看专用日志：

```sh
/usr/bin/log stream --style compact --level info --predicate 'subsystem == "io.github.xiaodou997.VPNSplitter.S1"'
```

在 App 按顺序操作：激活扩展 -> 系统设置批准 -> 保存测试配置 -> 勾选其他 VPN 已断开和本地授权 -> 测试 Provider 启动。`S1_EXTENSION_PROCESS_STARTED` 只表示进程进入；还要出现与 App 的 attempt UUID 对应的 `S1_PROVIDER_REACHED ... network_settings=NOT_APPLIED`，才证明 NE 调用了 Provider。

App 保持“协议未实现”的文案；预期启动拒绝，而不是正常连通。系统可能包装错误域，因此不要只匹配界面错误码来判通过。日志未出现时按 NOT_RUN/BLOCKED/FAIL 记录真实观察。

收尾：停止本测试会话 -> 刷新确认 disconnected/invalid -> 移除本测试配置 -> 停用本扩展。只操作 provider ID 与所有权标记一致的唯一配置；同 ID 出现多份/外来配置会拒绝。扩展卸载可能需要重启；重启前不算完全移除。不全局 reset system extensions，不删其他 VPN 配置。

## 5. Developer ID 发行路径（不是把 Debug 当发行包）

项目有独立 `DeveloperID` configuration，使用 `packet-tunnel-provider-systemextension`；Debug/Release 的开发签名使用 `packet-tunnel-provider`。两个 target 都需要对应授权。Apple DTS 对 Xcode 26 及更早的 Organizer 导出问题有专门说明；Xcode 27 的行为已更新。本工程以显式配置直接构建，不能混用 development 与 distribution profiles。[Apple 说明](https://developer.apple.com/forums/thread/737894)

在本机准备 Developer ID Application 身份及 **App、扩展各一份 Developer ID profile**，在忽略的 Signing.local.xcconfig 填入两个 profile specifier。然后：

```sh
/bin/bash tools/s1/build.sh developer-id
```

验证脚本不会自动公证，`notarization=NOT_CHECKED`。本阶段不提供已签名发行包或 DMG。需要检查 Developer ID 实际加载时，先按 Apple 官方流程公证此产物并 staple，然后再次验证并安装，不能用禁用 Gatekeeper 代替公证。

手动公证示意（路径和 keychain profile 由本机确认）：

```sh
# APP 与 ZIP 是本机经审核的构建产物/新输出路径；不要覆盖已有文件。
# 此操作把签名代码发送给 Apple，须用户明确同意并实际执行。
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
# 仅当结果为 Accepted 后执行：
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"
```

私钥、Apple ID 密码、app-specific password、API key、profiles 不上传聊天或仓库。不要把 raw profile/Keychain 输出贴进公开 Issue。认证配置与 Store Credentials 操作在本机按官方文档完成。

## 6. 回报模板

```text
schema=s1-machine-result-v1
commit=填写实际 git rev-parse --short HEAD
macos_build=填写
xcode_build=填写
sdk_version=填写
swift_version=填写
policycore_debug=NOT_RUN
policycore_release=NOT_RUN
unsigned_build=NOT_RUN
development_signing=NOT_RUN
extension_activation=NOT_RUN
provider_reached=NOT_RUN
expected_backend_not_implemented=NOT_RUN
own_profile_removal=NOT_RUN
extension_deactivation=NOT_RUN
developer_id_signing=NOT_RUN
notarization=NOT_RUN
```

不要求一次全部完成。先 preflight/unsigned，把失败的精确步骤与少量错误行反馈即可。PolicyCore 使用原来的 Debug/Release SwiftPM 命令，可独立执行；不与 Xcode TestAction 的空 Testables 混淆。

## 7. 资料与未决事项

[Apple Provider 调试](https://developer.apple.com/forums/thread/725805)；[打包、生命周期与 entitlements](https://developer.apple.com/forums/thread/800887)；[公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。本实现未复制第三方代码。

System Extension 与 App 不运行在同一用户上下文；后续不能假设 App Group 目录或用户 Keychain 自动共享。S1-03 在引入凭据前必须确定 System keychain/经认证 IPC 边界，本次不实现密钥存储。WireGuard 接入、实际网络设置、DNS、Helper 与完整签名发行仍是后续任务。
