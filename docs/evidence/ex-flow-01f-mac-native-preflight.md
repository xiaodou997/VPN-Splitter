# EX-FLOW-01F / EX-INT-03D Mac native preflight

日期：2026-09-29。起点：`b7254f3`。

## 本机检查与源码修复

- macOS arm64、Xcode/macOS SDK、Swift 的 `dev.sh doctor` 检查为 PASS。
- `external-flow-test` 首次发现旧 round-trip 夹具未设置 `providerMessageStatus=pass`；修正后 Debug/Release 与 Python 合同测试通过。
- `external-flow-build` 首次暴露 Swift 扩展入口文件名和 Swift 6 `self`/`await` 编译错误；修正后 unsigned App + systemextension `compile_link=PASS`。
- `external-helper-test` 首次暴露旧单页 UI 与 Rule V2 的测试夹具不匹配；修正后 Debug/Release 与 Python 合同测试通过。
- `external-helper-build` 首次暴露 SwiftUI 自定义值插值在 warnings-as-errors 下的错误；修正后 `compile=PASS`，`route_trial=DISABLED`。
- `external-test` 与 `external-build` 均通过。

## 签名与系统验收边界

- Apple Developer Program 会员状态已在本机账号页观察为有效；团队为 `V6M88BQG7C`。
- 既有 Developer ID Application 公开证书已导入，但本机无匹配私钥，`security find-identity` 与签名库存均未列出可用 Developer ID identity。
- 新 CSR 及私钥位于 Git 忽略的 `cert/`；私钥权限 0600，目录 0700；CSR 自签名校验通过。Apple 证书签发仍待网页提交。
- 当前签名库存仍为 `INCOMPLETE`：Developer ID identity 0、Flow App profile 0、Flow Extension profile 0。
- 签名构建、System Extension 激活、Transparent Proxy provider round-trip、第三方 VPN 共存与真实流量验证：**NOT RUN**。

本轮构建和测试没有安装/激活 Helper 或 Flow systemextension，没有应用路由或 DNS。公开证书和私钥只保存在本机；未加入版本库。
