# EX-INT-03B：Helper 控制 App 的时间戳与公证前置

日期：2026-09-29。基线 `main` `b383113`。关联 EX-INT-03B/03D、SEC-02/03、REL-02。此证据只覆盖不具备写路由能力的签名候选；不表示 SMAppService、App↔Helper 身份或路由会话真机通过。

## 修复与构建

旧 Developer ID 构建可通过本地 strict codesign，但主 App 和内嵌 Helper 都以 `--timestamp=none` 签名，`spctl` 显示 `Unnotarized Developer ID`。构建器现对显式真实身份使用 Apple 安全时间戳，并在输出 PASS 前分别检查两者的 `Timestamp=`；默认 ad-hoc 只构建仍使用 `--timestamp=none`。新增缺少时间戳时不发布 PASS 的合同测试。

- `/bin/bash dev.sh external-helper-test`：ExternalControl Debug/Release 与 14 项 Python/原生合同测试通过；不会注册服务或修改网络。
- 显式 Developer ID 构建：`compile=PASS`、`signing=LOCAL_IDENTITY_VERIFIED`、`route_trial=DISABLED`、`helper_installation=NOT_REQUESTED`、`network_settings=NOT_APPLIED`。本机主 App 和 Helper 均有预期的 Team ID、独立 bundle ID 与 Apple 安全时间戳，整体 strict codesign 通过。
- 产物仅在 `.local/external/control.4eujasbf/VPN-Splitter-ExternalControl.app`。只保存在 Git 忽略的 `cert/external-control-notary.zip`（权限 0600）的归档 SHA-256 为 `13a18f4d00c07072a6d27f311a56f569268f3acc8a04900e25fb74ef7e744433`。

## Apple 公证与边界

`notarytool` 提交 ID `827673f8-5bbc-4693-8a2c-cd540d3068b9` 返回 `Accepted`。`stapler staple` / `validate` 通过；`spctl --assess` 显示 `source=Notarized Developer ID`，同时本机报告 `override=security disabled`，不能把它单独当作默认 Gatekeeper 环境验收。没有关闭 SIP 或 Gatekeeper。

App 专用密码只在本机钥匙串，私钥和公证包留在本机被忽略目录；仓库没有证书私钥、profile 或密码。已将该公证候选复制到 `/Applications/VPN-Splitter-ExternalControl.app`，在该路径再次验证 stapler 票据、strict codesign 与 `source=Notarized Developer ID` 通过（本机 `spctl` 仍带上述 override）。控制 App 进程已启动；本机 UI 自动化未能绑定其窗口。`launchctl print` 在 system 与当前用户域均未找到 `ExternalHelper.v1`，且没有 Helper 进程；尚未注册 Helper、触发系统批准或连接 XPC。下一步是现场明确授权下的系统服务/双向身份验证，仍先保持 `route_trial=DISABLED`；真实写路由能力另行验收。
