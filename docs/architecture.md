# v0.1 技术架构

状态：Design Draft 1.0；2026-09-23。产品基线见 [ADR-001](adr/ADR-001-v0.1-baseline.md)。

## 1. 架构分层

```text
VPN-Splitter.app（非 root）
  SwiftUI / 菜单栏 / 配置与凭据管理 / 用户授权 / 诊断
                      |
                   PolicyCore
   校验、能力检查、CIDR 集合运算、DNS 意图、解释与计划
                      |
         +------------+-------------+
         |                          |
   ManagedSession              ExternalSession
         |                          |
 NETunnelProviderManager     NetworkDiscovery
         |                          |
 PacketTunnel.systemextension   受认证 XPC
   ManagedRuntime                   |
   + WireGuardAdapter       RouteHelper（仅必要权限）
   + OpenVPNAdapter          验证、有限路由写入、租约、恢复
         |
 NEPacketTunnelNetworkSettings / 协议后端
```

控制面处理用户意图和协调；数据面由已选协议核心处理包。不重写 WireGuard/OpenVPN 加密，不让主界面进程处理全部 VPN 数据包，不用 shell 拉起另一个独立 utun 充当 Managed 的正式实现。

## 2. 模块与依赖方向

| 模块 | 职责 | 不应依赖 |
| --- | --- | --- |
| PolicyCore | 类型化规则、能力、CIDR 编译、解释、版本化计划 | SwiftUI、NetworkExtension、root API、具体协议核心 |
| Configuration | 配置导入、白名单、版本迁移、秘密引用 | 任意脚本执行、网络下载 |
| NetworkDiscovery | 物理服务、接口、路由、DNS 和 epoch 快照 | 固定接口名、仅凭进程名判断兼容 |
| ManagedRuntime | 扩展内生命周期、重新编译、DNS 映射刷新、网络设置 | 外部 Helper、全局 shell 路由 |
| WireGuardAdapter | WireGuardKit/Go 桥、协议配置与统计 | UI 规则字符串 |
| OpenVPNAdapter | C++ Core 桥、认证事件、pushed 配置 | 直接越过 PolicyPlan 改系统配置 |
| ExternalRuntime | 检测、计划、租约续期和兼容性状态 | 第三方凭据/私有进程接口 |
| RouteHelper | 结构化路由操作、身份验证、日志与恢复 | 任意命令、任意路径读写、协议私钥 |
| Diagnostics | 统一错误与证据模型、脱敏导出 | 默认浏览历史采集、默认上传 |

PolicyCore 同时链接到 App 和执行端。App 生成预览，执行端依据实际网络和能力重新校验；预览不构成授权，也不能使过期计划绕过检查。

首发用 Swift Package 管理自有纯逻辑。WireGuard 的 Go 构建、OpenVPN 的 C++ 构建属于依赖构建边界，不将其类型泄露给公共规则模型。Windows 未来可以复用数据合同与测试向量，不为未知平台提前引入 Rust FFI。

## 3. 目标工程与签名边界

建议一个 Xcode 工程、一个主 App、一个 Packet Tunnel System Extension（内部择一启动 WG 或 OV）、一个按需启用的 RouteHelper LaunchDaemon。单扩展双后端需 S3 验证链接体积、符号和运行时共存；若须拆扩展，用 ADR 记录，不改变单会话规则。

目标目录，S1 创建最小可运行工程后才能称为已存在：

```text
apps/macos/VPN-Splitter.xcodeproj
apps/macos/App/
apps/macos/PacketTunnel/
apps/macos/RouteHelper/
Packages/PolicyCore/
Packages/Configuration/
Packages/NetworkDiscovery/
Packages/Diagnostics/
Adapters/WireGuard/
Adapters/OpenVPN/
Tests/Fixtures/
Tests/Integration/
scripts/
docs/
```

构建目标：arm64、Deployment Target 26.0、支持该目标的 Xcode/SDK 和 Swift 6 工具链。精确 Xcode build、Swift、Go、CMake 和依赖 revision 在 S1/S3 的构建清单固定；不宣称现在已验证某个最新版本。

Managed 通过 Network Extension/System Extension 授权，不依赖 External Helper。首次使用 External 才注册 Helper。签名、Keychain 与打包细节见[安全与发行](security-distribution.md)。

## 4. 数据合同

核心值类型：

- Profile：来源类型、协议安全配置引用、用户策略、DNS 意图、版本。
- BackendCapabilities：方向、地址族、DNS 模式、domainMode、REJECT、已验证系统条件、未知信息。
- NetworkSnapshot：epoch、时间、物理服务标识/接口、网关、隧道候选、路由、resolver、证据可信度。
- PolicyPlan：会话、generation、epoch、目标有效区域、DNS、基础设施要求、警告、输入摘要。
- ApplyReceipt：实际执行对象、后端响应、计划摘要、验证证据、可安全撤销的信息。
- DiagnosticEvent：时间、会话、组件、规则 ID、错误码、脱敏属性。

这些是待实现的接口合同，不是上游已有 API。PolicyCore 的纯函数边界是 compile(profile, capabilities, snapshot, dnsMappings) -> Plan 或 BlockingDiagnostics；具有相同规范化输入时应输出等价且稳定的计划。

执行端操作为 prepare、apply、verify、reconcile、stop。所有异步请求必须带 sessionId、generation 和 epoch；旧结果不能覆盖新状态。

## 5. WireGuard 路径

```text
.conf -> 导入校验 -> Keychain / 安全元数据
                     |
             ProtocolConfiguration
     peer / AllowedIPs / Endpoint / 密钥 / MTU
                     |
                WireGuardAdapter
                     +-- 协议后端配置
                     +-- 网络设置适配点 <- PolicyPlan
```

上游设置生成器同时根据 allowedIPs 生成协议参数和 includedRoutes，并在配置 DNS 后设置空域匹配。不能直接把其默认结果当本地分流方案。[源码](https://github.com/WireGuard/wireguard-apple/blob/master/Sources/WireGuardKit/PacketTunnelSettingsGenerator.swift)

S1 优先寻找可维护的 settings transform/injection 边界；若公开接口不足，维护固定 revision 的小补丁，独立记录变更和上游升级测试。禁止复制整个官方 App 后不断堆改 UI。

适配必须保留隧道地址、peer 选择、Endpoint 重解析、MTU 与必要接口路由。分流规则更新不得修改密钥/AllowedIPs。多 peer 不通过选择归属测试就不开放连接；未覆盖网段拒绝路由，不自动给 peer 加 0/0。

连接顺序：解析并验证安全配置 -> 解决 Endpoint 引导路径 -> 准备隧道与基础网络 -> 编译数据路由/DNS -> 应用 -> 验证握手和受控目标 -> 对外报告运行。具体调用顺序由 WireGuardKit 生命周期约束在 S1 固定；不能因为 UI 计划需要顺序就跳过库的网络设置回调。

## 6. OpenVPN 路径

```text
.ovpn -> 安全导入/兼容性报告
                   |
              OpenVPN 3 Core
          认证、协议、网络配置回调
                   |
       ServerNetworkProposal（不直接应用）
                   |
            PolicyCore 审核合并
                   |
        NEPacketTunnelNetworkSettings
```

采用小范围 ObjC++/C 接口封装 C++ Core。桥接对象拥有协议线程、取消令牌和回调生命周期，回调转入串行状态执行器；停止后不得回调已释放 Swift 对象。

S3 必须证明 tun-builder/外部 TUN 接口可与 NEPacketTunnelProvider 的包通道集成，不创建第二个不受管理的隧道，不依赖私有 KVC 获取描述符等未审查做法。零拷贝或 FD 捷径不是首发前提，数据面选择以受支持接口、正确性和测量为依据。

保留服务器提案的地址/路由/DNS 来源。redirect-gateway、默认 IPv6 等只作为提案，由本地策略决定接受或替换。不要不加区分地 route-nopull 后丢失 DNS，也不要把 server push 默认设置成不可见高优先级规则。

认证失败保留准确但脱敏的原因；动态挑战不自动变成无限密码重试。默认不启用压缩和不安全的校验降级；选项支持性在真实配置矩阵记录。OpenVPN CLI 能连通仅是诊断线索，不是 NE 集成验收。

## 7. Network Extension 路由策略

Managed 使用 NEPacketTunnelNetworkSettings 设置地址、路由、DNS、MTU。`includeAllNetworks` 在本分流设计中保持 false，不能打开后再假定普通 excludedRoutes 生效。[Apple 说明](https://developer.apple.com/videos/play/wwdc2025/234/)

`enforceRoutes=true` 是 S1 的优先验证候选，用于改善 included/excluded 的执行一致性；必须对普通连接、绑定接口连接、系统必要例外、本地网络和睡眠恢复测试。S1 以 ADR 记录实际采用值和覆盖范围，不允许测试失败后静默关闭它仍宣称同样保证。

系统必要流量例外、基础设施路由、既有连接和应用特定网络行为单列，不使用“全流量强制”文案。扩展设置调用成功只是应用回执，后续还需验证。

## 8. DNS 运行位置

DNSPlan 与 RoutePlan 同属 generation，但分别解释。Managed 的名称映射刷新和有效期管理运行在扩展的 ManagedRuntime 内；不依赖窗口存在。App 退出按合同请求停止，App 崩溃则不能假定扩展已停止，应在重开后重新读实际状态。

External 名称映射由 App 执行，Helper 只接受有界路由计划并独立验证，使用有限会话租约；App 崩溃不应留下永久无人管理的动态路由。

不新增 v0.1 DNS Proxy/透明代理 target。系统 resolver 无法观测的字段标 unknown，不能把推断结果写成实际查询路径。细节见[规则规范](policy-dns-spec.md)。

## 9. External 检测与兼容判定

输入优先使用公开系统观察接口，如 SystemConfiguration、接口信息、路由快照和网络路径事件；netstat/scutil 文本可用于 Spike 证据，但生产解析不得依赖某台机器的本地化输出。

物理路径应从网络服务、地址、网关和可达性联合确认。NWPathMonitor 的当前路径/当前 default 不必然是物理路径；VPN 启用前后快照有帮助，但 App 冷启动也必须处理没有前快照的情况。

能力状态不用品牌白名单代替证据：

| 状态 | 含义 | 行为 |
| --- | --- | --- |
| Unknown | 缺基线、多候选、网关或执行机制不确定 | 仅诊断 |
| RouteCandidate | 存在可解释的路由型全局模式 | 允许用户确认的有限验证 |
| BypassVerified | 当前 epoch 的受控 DIRECT 测试和原 VPN 测试通过 | 仅授予已测试例外能力 |
| ConflictOrEnforced | 观察到路由争用/流量仍被强制/已知企业限制 | 撤销安全自有修改并停止 |
| Unsupported | 无法满足所需方向或地址族 | 不应用 |

无法从常规权限读取第三方 includeAllNetworks/enforceRoutes、过滤器或 MDM 全部状态。因此“未发现”不等于“不存在”；Negative 判断必须谨慎，实际出口测试不可省略。

S0 只手动验证一个受控地址。S4 的生产 Helper 优先验证结构化系统路由接口，禁止通用命令执行；该路由修改后端仍属非官方保证的兼容路径，系统更新需重测。

## 10. 事务、所有权与租约

External 应用过程：读取当前 epoch -> 校验全量计划 -> 写入 pending 日志 -> 执行有限差异 -> 逐项确认结果 -> 写 committed 回执 -> 探测实际路径。每个阶段失败都要有测试。

日志对象包含目的前缀、地址族、网关、接口及索引、flags、创建前状态、操作 ID、会话、epoch、generation、租约期限和回执。不包含私钥、密码或用户流量。

原有相同路由只能借用，不计 owned；EEXIST 不得转成覆盖。撤销前重新读取完整指纹，只删除可安全关联到自己成功添加操作的对象。

系统路由没有应用级 owner 标签；跨进程删除再重建相同对象的竞争也不一定可识别。日志与指纹不是全局原子所有权证明。发生断档、归属歧义或第三方已修改时，进入 RecoveryRequired，保留对象并说明人工处理范围，不盲删、不恢复整个旧路由表。

初始租约设计：App 每 30 秒续期，90 秒无有效续期则撤销可安全撤销的自有路由；这些是待 S4 验证的工程参数。睡眠期间不要求计时器准时运行；唤醒后先重新检查 epoch/租约再协调，不用旧网关重放。Helper 重启先恢复日志，再接受新计划。

网络变化将 epoch 失效。有限去抖与退避后重新发现、编译和应用；相同冲突重复出现则熔断至只读，不与第三方不断争用。

## 11. 状态机

```text
Idle -> Preparing -> AwaitingAuthorization -> Connecting
                                      -> Applying -> Verifying -> Active
Active -> NetworkChanged -> Reconciling -> Verifying
Active -> Degraded（已声明的部分能力失效）
任意活动态 -> Stopping -> Idle
应用/撤销失败且有歧义 -> RecoveryRequired
认证/能力等阻断 -> Failed
```

External 跳过本应用的协议 Connecting，仅等待原客户端已连接。Active 仍携带覆盖范围，不代表所有 IPv6/域名已保证。

UI 从实际执行端合成状态。App 重新启动时读取 manager、扩展回执、Helper 日志与当前网络，不能信任磁盘中的 connected 标志。

编辑策略通过 prepare/apply receipt 完成。Network Extension 设置调用与外部路由写入不是对整个系统的原子事务；不承诺无任何瞬时窗口。需要强阻断的用户不适用本版本。

## 12. 诊断与可测试边界

规则编译、CIDR 集合、规范化、冲突、epoch/generation、租约状态机均使用确定性输入和假时钟单测。系统接口、DNS 查询和协议事件封装成可注入依赖。

实际连通性测试需受控 VPN 目标和公网目标，结合服务端观察或限定抓包确认。route get 是系统路由线索，不是实际出口证明；连接成功也不能证明分流正确。

统一诊断应同时展示 expected、configured、observed 三类信息及时间。更多要求见[测试计划](test-plan.md)。
