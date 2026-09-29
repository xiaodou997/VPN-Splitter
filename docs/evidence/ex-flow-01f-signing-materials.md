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

Flow Probe DeveloperID 构建已实际启动，编译进入扩展 `CodeSign` 阶段；macOS 私钥访问授权未完成，后台 `codesign` 持续等待，构建被停止并返回失败。**签名构建尚未 PASS**。此前 Helper 的本地 Developer ID 尝试在同一私钥访问环节超时；默认 ad-hoc Helper 构建证据保留。

钥匙串访问显示新证书下有 `Imported Private Key`，访问控制列表已有 `codesign`；没有修改 LocalDev 凭据权限或放宽为“允许所有应用”。下一步需由本机操作者在交互式终端为此签名私钥完成 Apple 工具分区授权并输入钥匙串密码，随后重跑 Flow/Helper 签名构建与二次验签。

System Extension activation、Transparent Proxy 配置/启动、provider message、第三方 VPN 共存、真实 flow 元数据和 DIRECT 数据面均为 **NOT RUN**。本轮没有安装或激活扩展，没有修改路由/DNS。
