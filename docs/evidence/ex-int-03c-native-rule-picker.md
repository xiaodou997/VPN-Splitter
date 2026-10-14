# EX-INT-03C：规则与 App 选择器原生验证

日期：2026-09-30，macOS 26 arm64。本轮由 Agent 经用户授权的 AppleScript/辅助功能操作实际控制 App。临时规则使用 example.invalid 和本机应用，不触发 Flow 或路由执行；原有单目标方案保留并逐项比较未变。

## 已取得真机证据

- 在规则页新增临时方案，加入 DOMAIN 与 APPLICATION；界面提示 Route Bypass 不会忽略这些规则继续执行。
- 搜索 Chrome，点选唯一结果；保存文件中的 applicationIdentifier 为 com.google.Chrome，无应用路径字段。
- 保存后切到分流会话，Helper 预检与开始按钮均禁用，并明确显示 flow-only 拒绝文案。不是仅靠“未保存”状态禁用。
- 对应用显示名称进行实际键盘编辑并保存，旧 applicationIdentifier 被清空，避免显示名称与签名身份不一致。

## Safari 漏检修复

本机 /Applications/Safari.app 是目录符号链接。原 FileManager 递归 enumerator 未返回它，但独立 Bundle/Security.framework 检查均成功，Signing ID 为 com.apple.Safari。因此原生搜索 Safari 无结果是目录候选发现缺陷。

候选收集现额外检查标准 Applications 根目录的直接子项，仅纳入 .app 符号链接；不跟随任意目录链接、不进入包内部，每个候选仍须通过原 Security.framework 校验，规则仍不保存路径。原生合成目录测试覆盖真实 .app、直接 App 链接、普通目录链接、包内 App 和隐藏项；通过。完整 External Debug/Release 与 19 项合同/原生测试通过，签名 route-trial 构建 au_v21vi 通过。公证/安装后 Safari GUI 复验与临时方案清理另记；未把编译成功当作 UI 成功。

## 系统隐藏链接补充

首轮符号链接修复的 GUI 复验仍未找到 Safari，未记 PASS。进一步原生检查显示该符号链接同时带 isHidden=true，contentsOfDirectory 的 skipsHiddenFiles 仍将其过滤。候选补充逻辑现在仅对根目录直接 .app 符号链接忽略隐藏元数据，但明确排除点开头名称；普通隐藏项/目录链接与包内部仍不遍历。

新增 UF_HIDDEN 链接及点隐藏链接边界夹具，4 项 picker 测试通过；直接编译实际 catalog 在本机扫描，得到 actual_signed_safari_discovered=true（真实 Foundation/Security，无替身）。4d4_p98t 签名原生构建通过，GUI 最终点选/保存仍需安装后确认。

## 最终 GUI 复验与清理

4d4_p98t 公证 `816b717b-1ec3-41bd-9b78-223462c8ca2d` Accepted，staple/validate 和安装后 strict codesign 通过。Agent 在真实 Picker 搜索 Safari，取得唯一结果；点选保存后独立读取本地规则，displayName=Safari、applicationIdentifier=com.apple.Safari，无路径字段。Safari 系统链接发现与绑定 GUI PASS。

通过 GUI 删除本轮新建的合成临时方案（删除前核对 UUID 不属于原方案集合，并保留本机合成结果），再通过方案菜单恢复原选中方案。独立比较原方案数组逐项完全相同，selectedID 恢复；未覆盖 JSON、未回退 revision、未删除锁。目标路径仍 utun8。此阶段未注册 Helper 或写入路由。
