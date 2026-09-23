# 安全、权限、签名与发行方案

状态：Design Draft 1.0；2026-09-23。适用 SEC、DIST、EX、FAIL 要求。

## 1. 安全定位

v0.1 是分流连接工具，不是系统级防泄漏产品。它不应绕过企业强制策略，不破解第三方客户端，不承诺在 root 已被攻陷、系统已被恶意修改或其他管理员同时改网络时仍提供完整保证。

需要防范的主要输入：恶意 VPN 配置、DNS 返回的异常地址、非授权本地进程调用 Helper、错误/陈旧异步结果、意外崩溃、日志泄露和供应链变化。

## 2. 资产和信任边界

| 边界/资产 | 主要风险 | 强制措施 |
| --- | --- | --- |
| .conf/.ovpn 导入 | 脚本、路径遍历、资源耗尽 | 白名单、大小/项数限制、安全文件选择、不执行 |
| Keychain 秘密 | 日志/导出/跨进程泄露 | 按配置引用、最小访问组、不在普通 JSON 存原值 |
| App -> 扩展/Helper | 伪装调用方、越权改系统 | 系统身份信息、代码要求、版本、授权和参数复核 |
| DNS -> 路由 | 重绑定、无限路由、基础设施劫持 | epoch、有效期、数量限制、目标地址校验和冲突阻断 |
| 路由事务 | 崩溃、网关变化、误删第三方对象 | 持久化日志、指纹复核、有限租约、歧义不删 |
| 发布流水线 | 私钥泄露、未审核依赖进入签名环境 | 最小权限、固定依赖、隔离真实测试和签名凭据 |

本方案不会读取原 VPN 的钥匙串条目、内存、浏览器登录状态或私有认证数据库。

## 3. 配置和秘密管理

导入先在低权限进程解析并生成结构化报告。配置文件尺寸初始限制 2 MiB，单个引用材料 2 MiB，总引用材料 8 MiB；这些是工程保护上限，真实样本需要更大时以测试支持的变更调整，不能无限制读取。

脚本、插件和具有执行效果的选项阻断激活。未知关键参数不得当作注释跳过。用户可以明确确认移除不支持项并保存新副本；保留变更记录，但不将包含秘密的原文永久复制到日志。

外部引用由用户逐项授权选择，规范化路径后验证范围；防止 ../、符号链接绕过和“导入时安全、使用时替换”的竞争。必要文件复制到受控存储并校验，不能允许 Helper 读取任意路径。

私钥、密码、PSK、可复用令牌放在 Keychain。普通元数据只保存本地引用。用户名、Endpoint、企业域和证书身份也视为敏感元数据，默认不公开。S1 必须验证当前签名/沙箱/执行用户下 App 与 System Extension 的最小 Keychain 共享方式；用户钥匙串可读不表示系统扩展天然可读。

默认不做开机无人登录自动连接；钥匙串锁定或未授权时进入可解释的等待/失败状态，不降级为明文文件。不要求在聊天或仓库中提供有效秘密；连通性测试在用户 Mac 使用本机有效配置。

秘密通过最短必要生命周期进入协议核心。避免字符串拼接日志和进程参数传递；Swift/Go/C++ 跨语言内存无法仅靠一个清零函数证明所有副本都消失，不作绝对内存清除承诺。

## 4. Helper 最小 API

只提供版本化结构化动作，名称为设计合同：

```text
getCapabilities()
inspectNetwork()
prepareLease(sessionId, generation, epoch, routes)
commitLease(preparedToken)
renewLease(sessionId, generation)
releaseLease(sessionId)
recoverOwnedState()
```

不提供 runCommand、shell、writeFile、任意 deleteRoute 或任意 resolver 写入。路由删除只能由 Helper 从自己的可信事务日志推导。

每个 XPC 连接都要基于系统提供的调用方身份验证指定 App 的 Team ID、bundle ID 和代码签名要求；不能仅相信请求中的 PID、路径、用户名或“我是主程序”字段。验证双方协议版本；未知方法、过大消息、重放 generation、过期 epoch 全部拒绝。

注册服务的用户授权不等于允许任何程序以后任意改路由。Helper 独立校验当前物理路径、前缀、网关、接口、数量、会话所有者和合法能力。一个活动 External 会话对应一个可追踪授权上下文；其他本地用户不继承该会话修改权。

采用 SMAppService 管理按需 LaunchDaemon，实际注册/启停和批准流程在 S4 真机验证。[Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)

Helper 不含 VPN 私钥，不用临时 sudo 密码，不改变其他 VPN 的配置，不通过 PF 规则提供隐藏阻断。

## 5. 日志、隐私和诊断导出

常规日志只记录组件、状态、错误码、会话/规则匿名标识和操作数量，默认不开启逐查询浏览历史或包内容记录。详细网络诊断由用户触发。

所有日志出口共用脱敏层，覆盖配置原文、错误对象、FFI 回调、DNS、Keychain 引用、Endpoint、用户路径和认证响应。秘密使用合成测试值做自动泄露扫描。

导出包先生成预览：隐去私钥/密码/令牌；企业域、IP、用户名、接口地址使用包内一致但不可跨包关联的替代标识。需要保留真实地址才能诊断时，由用户单独选择，提醒不要提交公共 Issue。默认不保留全量抓包。

操作日志只用于本地恢复，权限限制到实际执行端。日志轮换和资源上限在 S4 固定；磁盘满、日志损坏、部分写入应进入安全停止或 RecoveryRequired，而不是无记录继续写路由。

## 6. Target、entitlement 与签名矩阵

首发发行路线为 Developer ID + Packet Tunnel System Extension。Apple 对直接发行的 NE provider 要求 System Extension 打包及对应 entitlement；App 和扩展均需检查相关 NE entitlement。[Apple 官方说明](https://developer.apple.com/forums/thread/737894)

| Target | 设计职责 | 签名/权限验证要点 |
| --- | --- | --- |
| VPN-Splitter.app | UI、配置、授权、管理扩展 | 同团队签名；NE entitlement；安装系统扩展能力；必要的 Keychain/App Group |
| PacketTunnel.systemextension | WG/OV 协议与网络设置 | 对应 provider entitlement；独立 bundle ID/profile；与 App 匹配的最小共享权限 |
| RouteHelper | External 有限路由管理 | 指定代码要求；SMAppService 注册；不授予无关 NE/凭据能力 |

Developer ID 发行需要检查 `com.apple.developer.networking.networkextension` 中对应的 `packet-tunnel-provider-systemextension` 值；主 App 的系统扩展安装能力为 `com.apple.developer.system-extension.install`。开发签名与发行签名不能未经检查共用一份 entitlement 假定都有效。

沙箱、网络访问、App Group、Keychain group 的最终组合由 S1 的真实系统扩展样例验证，按最小权限记录，不为了省事打开通配访问。Hardened Runtime 与依赖运行时需求也须检查；不能默认关闭 library validation 或其他保护。

Apple 的发行说明在 2026-06-22 更新，提到 Xcode 27.0 beta 1 对此前 NE 导出问题的修复报告。这不是本项目已验证的构建结果。根据实际固定的 Xcode 版本验证导出路径，不能把 Xcode 26 的旧绕行步骤当作所有版本都必须执行。[同一官方记录](https://developer.apple.com/forums/thread/737894)

## 7. 构建与 CI 分层

普通 PR：文档/格式/秘密扫描、PolicyCore 和导入单测、依赖版本检查；可以做无签名编译，但结果不等于扩展可加载。

受信任 macOS arm64 环境：签名启动、协议真机和路由测试；不能让外部 PR 的代码直接接触真实 VPN、签名证书或本机网络管理权限。修改默认路由的测试不在共享办公机器或未隔离的普通 CI 自动执行。

发行环境：从审核后的 commit/tag 构建，依赖固定 revision，生成版本/工具链/许可证清单，签名、公证与打包。签名私钥、账号令牌和 provisioning 管理材料不提交仓库；日志不输出凭据。

项目目录和脚本尚未实现。S1 创建实际可执行脚本后才在 README 写构建命令；本方案不虚构已可运行的 build/test 命令。

## 8. 发行流水线合同

Release 必须完成：依赖/许可审查 -> 测试 -> archive -> 验证并签署嵌套代码 -> 验证 App/profile/entitlement -> 公证 -> staple -> 制作 DMG -> 在干净用户环境安装启动测试。

使用当时 Apple 支持的 notarization 工具链，固定并记录命令、身份类型和结果；生产包必须关闭调试用途权限。公证成功不代表 VPN 路由测试成功。[Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

发布记录至少包含 commit、App build、macOS 精确构建、Xcode/SDK/Swift/Go/C++ 版本、依赖 revision、签名/公证状态、测试摘要、校验和、已知限制和撤销/卸载流程。

正式包不得依赖关闭 SIP、系统扩展开发模式、关闭签名检查或 root 手动运行主 App。开发临时设置不能进入最终验收环境。

## 9. 许可证与供应链

自有代码使用仓库 MIT LICENSE。这不重新许可第三方代码。

WireGuardKit 为优先候选；逐文件及依赖核查，不能因为 WireGuard Apple 某个源码头部写 MIT 就推断所有 WireGuard 相关项目都是 MIT。

OpenVPN 3 当前 LICENSE.md 提供 AGPL-3.0 或 MPL-2.0 选择。计划优先审查 MPL-2.0 路径，记录覆盖文件、修改、源码提供方式和通知，并核查静态链接/桥接及其所有传递依赖。不能简单标成“项目 MIT，所以整个包 MIT”。[上游许可证](https://github.com/OpenVPN/openvpn3/blob/master/LICENSE.md)；[Mozilla 官方 FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/)。

GPL/AGPL 或其他许可项目可研究设计；复制代码、测试、资源或把依赖并入发行物之前须记录准确许可及兼容结论。参考项目并不自动成为依赖。此处为发行审核流程，不替代正式许可文本或有需要时的法律审查。

每项实际依赖必须登记：上游、commit/tag、许可证、链接/复制方式、补丁、校验、传递依赖、维护与安全更新办法、签名影响、审核结论。候选依赖未固定前不得进入生产构建。

## 10. 停止、升级与卸载

关闭窗口不停止会话；显式退出默认请求停止，并等待可安全撤销的自有修改处理完成。External 停止仅移除本应用例外，不断开原 VPN。

App 崩溃时 Managed 扩展可能仍运行；重启后显示真实状态并允许停止。External App 消失由 Helper 租约清理，Helper 崩溃重启根据日志和当前 epoch 保守恢复。

升级前检查会话与组件版本。App/扩展/Helper 不兼容时拒绝新策略，不把旧数据按新格式强解码。配置迁移使用安全备份，秘密不写明文备份。

卸载助手顺序：停止本会话 -> 确认自有路由恢复或显示未解决项 -> 移除本 App 管理的 VPN 配置 -> 请求停用系统扩展 -> 注销 Helper -> 按用户选择删除配置和 Keychain 条目 -> 提供剩余状态报告。

拖到废纸篓不等于后台组件和网络修改立即消失；文档必须提供受支持卸载入口。不能让用户用 route flush 或恢复整张旧网络快照解决问题。
