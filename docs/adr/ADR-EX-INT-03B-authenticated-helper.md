# ADR-EX-INT-03B：External 认证 Helper 与有限会话

日期：2026-09-29。状态：实现候选；不是系统授权、真实分流或恢复验收。关联 S4-02/03/04、EX-03/05/07/08、SEC-02/03。延续 External 优先与 03A 规则存储，不扩大 v0.1 范围。

## 决策

新增独立本地包 ExternalControl，容纳版本化 Data 协议、连接会话控制、签名身份规则和原生 App 客户端。ExternalCore 的纯规则库仍只依赖 PolicyCore；只有其页面 target 引用 ExternalControl。ExternalExecution 增加真正的 VPNExternalHelper target，通过 ExternalHelperLease 复用现有网络采集、计划、C 路由驱动与事务，不调用 CLI 或 sudo。

普通 ExternalPreview 的 ad-hoc 身份不能成为特权客户端。独立控制 App ID 为 `io.github.xiaodou997.VPNSplitter.ExternalControl`，Helper ID 为 `io.github.xiaodou997.VPNSplitter.ExternalHelper`，固定 Mach 服务 `.ExternalHelper.v1`。双方团队来自自己的已验证签名，不由消息、环境变量或 PID 指定。要求 Apple 签名锚、精确 ID/Team、Hardened Runtime 自检，拒绝调试及放宽代码装载的 entitlement。监听器及连接使用系统代码要求；App 握手后核对远端 root UID，Helper 只接纳当前控制台登录 UID。UUID 是关联标识，不是身份认证。

使用 SMAppService.daemon 管理内嵌 LaunchDaemon。plist 在 Contents/Library/LaunchDaemons，BundleProgram 指向本 bundle 的 Contents/Library/LaunchServices/VPNExternalHelper；不安装通用命令服务、不接收路径或可执行文件参数。注册只在独立签名控制 App 位于 /Applications 且用户点击确认后请求，管理员系统批准与每次规则应用确认分离。

## 会话合同

仅 hello / prepare / apply / status / stop / quiesce 六种结构化动作。请求最大 16 KiB，规则最大 64 项，原规划器进一步限制 8 个 /24–/32 编译结果、2048 地址。Helper 只接收规则与版本，物理网关/接口由 Helper 当前采集；App 在 prepare 与 apply 前各自重新载入并核对完整已保存方案。

全服务最多一个预留/活动会话、8 个连接。prepare 不打开写入驱动，给同一连接/实例/方案/版本发一次性票据，15 秒有效。apply 在调用原生事务之前消费票据；失败不自动重试。服务自有定时器检查 10 秒心跳、当前控制台用户与取消，活动授权期限为 60 秒，不续期。同步原生调用和调度可能延迟停止，因此这些不是内核硬到期保证。

连接失效立即置不可逆取消位，既有事务在其检查点停止；GUI 的配置变更、睡眠和退出撤销同一连接。状态来自实际事务，不把 XPC 成功、零回执或断开本身当成恢复。旧响应不得回填新代次。客户端超时 25 秒后关闭连接，不携带 NSXPCConnection 跨 actor，不重发写入。

Helper 启动只核查固定 root 私有目录及 active 标记是否存在/安全；存在或不明则锁定 recoveryRequired，不读取旧记录并重建删除权。沿用原 CLI 的同一 journal/锁；准备或注册不清除标记。没有会话的 stop 也不能消掉旧恢复状态。注销先查询干净状态，再以 quiesce 阻止新 prepare 与注销竞争。注销失败不会自动重新开放服务。

## 开发与启用分开

`external-helper-build` 默认构建 ad-hoc 不可授权的完整 App/Helper；显式身份签名仍默认只读。只有同时给出本机身份/团队和 `--route-trial` 才编译写入能力，运行还必须通过系统批准、双向身份和本次提案确认。编译开关不是验收凭据，不表示 FIX-08 已在现场自动撤销通过。原 external-run 保留，无证书也能使用已通过的规则管理。

真实身份拒绝/接受、SMAppService 批准/撤销、Mac SDK 编译、ADD/DELETE、App/Helper 崩溃、切网、卸载均待分层联调。失联后的跨连接状态认领/恢复交互、崩溃记录处理未完成；不能声称完整 EX-INT-03 或 S4 已验收。

## 一手参考（2026-09-29 核查，未复制实现）

- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple 内嵌 Helper 与 BundleProgram](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [NSXPCListener 代码签名要求](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))
- [Apple Security CSCommon.h](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/CSCommon.h)：公开 kSecCodeSignatureRuntime 值 0x10000，用于自签名信息检查；不是读取用户私钥。
