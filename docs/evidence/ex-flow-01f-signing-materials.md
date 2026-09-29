# EX-FLOW-01F Developer ID signing materials on Mac

日期：2026-09-29。源码基线：`main` `4210fe7`。

## 目标与结果

目标是让 Flow Probe App 和内嵌 systemextension 具备可核验的 Developer ID 签名材料；本记录不表示系统激活或 Flow 数据面已通过。

- Apple Developer Program 团队 `V6M88BQG7C` 已签发新的 Developer ID Application 证书，有效期至 2031-09-17。证书公钥与本机 CSR 私钥的 SHA-256 摘要相同；登录钥匙串 `security find-identity -v -p codesigning` 列为有效身份。
- 明确注册两个 App ID：`io.github.xiaodou997.VPNSplitter.FlowProbe` 启用 Network Extensions 与 System Extension；`io.github.xiaodou997.VPNSplitter.FlowProbeExtension` 启用 Network Extensions。
- 两个 Developer ID provisioning profile 分别绑定精确 App ID、团队和本次新证书。解码核对两者均含 `app-proxy-provider-systemextension`；App profile 含 `com.apple.developer.system-extension.install=true`，Extension profile 不含该安装权限。
- 源文件保留在 Git 忽略的本机 `cert/`，目录权限 0700、文件权限 0600。Xcode 的 provisioning profile 目录额外安装了对应 UUID 的副本，供手动签名构建查找。
- `/bin/bash dev.sh external-flow-signing-preflight --team-id V6M88BQG7C` 输出 `developer_id_identities=1`、`app_profiles=1`、`extension_profiles=1`、`signing_inventory=READY`。

## 构建及系统验收边界

首次 Flow Probe DeveloperID 构建进入扩展 `CodeSign` 后等待钥匙串私钥授权，未生成合格产物；首次 Helper 签名也在同一位置超时。钥匙串访问确认私钥配对且 ACL 已列出 `codesign`。本机操作者在交互式终端输入钥匙串密码，为**这把导入的签名私钥**设置 Apple 工具分区授权；没有改 LocalDev 凭据权限，也没有选择“允许所有应用”。

重试结果：

- `external-flow-build --sign`：`compile_link=PASS`，`signing=LOCAL_DEVELOPER_ID_VERIFIED`；构建器分别验证主 App 与内嵌 systemextension 的 exact bundle ID、Team ID、strict signature、Network Extension entitlement 和 App 的 System Extension install entitlement。产物留在 `.local/external/flow.yrgoga_h/Products/DeveloperID/VPN-Splitter-FlowProbe.app`；扩展 SHA-256 为 `ba2f0f5b68e08295817cedce1dbb3f2749121e2fce87a1fafb24c6e50c0418cf`。
- Helper 首次签名重试已完成代码签名，但构建器的 `codesign -R` 自定义规则缺少源码表达式前缀，返回 `invalid requirement specification`。修复构建器后，`external-helper-build --identity ... --team-id ...` 输出 `compile=PASS`、`signing=LOCAL_IDENTITY_VERIFIED`、`route_trial=DISABLED`。产物留在 `.local/external/control.r7xusgsn/VPN-Splitter-ExternalControl.app`。
- `external-helper-test`（ExternalControl Debug/Release 及 Python 合同）通过。另用 `codesign --verify --strict` 独立复核 Flow App、Flow extension、Control App 和 Helper，四项均通过。
- `/Applications` 下未发现本次 Flow/Control App；`systemextensionsctl list` 未列出本项目的 Flow extension。

System Extension activation、Transparent Proxy 配置/启动、provider message、第三方 VPN 共存、真实 flow 元数据和 DIRECT 数据面均为 **NOT RUN**。本轮没有安装或激活扩展，没有修改路由/DNS。`LOCAL_DEVELOPER_ID_VERIFIED` 仅是本地签名结构通过，不代表系统接受、公证或发行通过。
