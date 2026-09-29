# EX-FLOW-01C：显式探针控制与应用选择器

日期：2026-09-29。基线 `81b8c89`。

## 目标

继续推进第三方 VPN 的用户友好规则：APPLICATION 由“软件名模糊搜索”进入，但实际执行身份必须是稳定 Signing ID；同时把 FLOW-01B 的 unsigned App + systemextension 骨架补成可进行后续签名联调的显式控制 App。

## 实现

### APPLICATION 规则

`ExternalSavedRule` 新增可选 `applicationIdentifier`，与 `target` 显示名分开编码。非 APPLICATION 规则验证时会清空该字段。APP 规则允许未绑定身份的草稿；绑定时 Signing ID 只接受有限 ASCII identifier 格式。

新增 `ExternalApplicationCatalog`，只读枚举标准 Applications 根目录，使用 Security.framework 创建/校验 `SecStaticCode` 并读取 `kSecCodeInfoIdentifier`。结果不向规则层返回路径。选择器支持按显示名、Bundle ID、Signing ID 模糊搜索；选择后写入显示名 + Signing ID。编辑显示名自动清除旧身份。

`ExternalFlowPolicy` 优先使用规则中已保存的 Signing ID；旧的显式 applicationBindings 入口继续保留用于测试/迁移。启用 APP 规则没有稳定身份时继续返回 unresolvedApplication。

### FLOW-01C

新增 `FlowProbeController`：SystemExtensions activation、Transparent Proxy preference 检查、保存禁用配置、显式启动/停止、移除配置。没有 onAppear/task 自动激活。App 不在 /Applications 时拒绝提交 activation request。

生成工程将 App/extension Network Extension entitlement 改为 `app-proxy-provider-systemextension`，并把 Controller 编入 App target。默认 `external-flow-build` 仍 `CODE_SIGNING_ALLOWED=NO`；因此 activation/config 只属于代码路径，不是实际系统通过证据。

## Apple API 核对

- OSSystemExtensionRequest activation request 由容器 App 显式提交，系统会校验 bundle 位置、签名、entitlement 和 identifier。
- NETransparentProxyManager 负责加载/控制 Transparent Proxy 配置。
- NEVPNManager 的 saveToPreferences 要求先加载 preferences；控制器按 load -> 修改 -> save 顺序执行。
- Developer ID 形式的 Network Extension entitlement 使用 systemextension 后缀。

## 测试/未测

新增核心 XCTest 源码覆盖 applicationIdentifier round-trip、非法身份拒绝、FlowPolicy 直接使用持久化 Signing ID。现有实际 profile model harness 新增“绑定 App 后修改显示名必须清除身份”。新增 Python 合同检查 App 扫描只读、不保存路径，以及 FLOW-01C 没有自动 activation。

当前执行环境仍没有用户 Mac/Xcode 运行能力，本批新增测试未在此环境声明 PASS；`NETransparentProxyManager` 新建配置路径和 Swift 6 Apple SDK 类型检查均以本机 `external-flow-build` 为下一事实门槛。没有安装/激活扩展、修改 Network Extension preferences、读取用户网络或改变第三方 VPN。
