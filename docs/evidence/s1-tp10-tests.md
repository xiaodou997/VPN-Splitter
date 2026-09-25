# S1-02 / T-P10：基础设施与 peer 范围的纯逻辑证据

日期：2026-09-25。状态：T-P10 的已声明 IPv4 纯逻辑合同通过；S1-02 整体仍 IN PROGRESS，尚待 Mac 原生执行与运行时接入。
依据：[ADR-006](../adr/ADR-006-policycore-infrastructure-and-peer-validation.md)、[规则规范](../policy-dns-spec.md)。

## 实际执行

环境：Linux x86_64，Swift 6.2.1（swift-6.2.1-RELEASE），SwiftPM/XCTest。源码无第三方依赖，无 NetworkExtension、进程执行、网络或文件读写。

先恢复上一轮交付并重跑 Debug：42/42 通过。随后加入 Constraints.swift、诊断字段和 ConstraintTests.swift，完整执行：

```sh
swift test --package-path Packages/PolicyCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/PolicyCore -c release -Xswiftc -warnings-as-errors
```

| 验证 | 结果 |
| --- | --- |
| Debug | 79/79 XCTest，0 failures |
| Release | 79/79 XCTest，0 failures |
| 新增用例 | 37 个 ConstraintTests，包含多组子输入 |
| 原有属性测试 | 每个构建 64 组策略、37,615 次地址对照 |
| 新约束对照 | 每个构建 32 组有限网段场景、8,192 次地址检查，独立计算需求与最长前缀选择 |

79 是不同 XCTest 方法数，不把两个构建相加为 158 个不同测试；也不与 S0 Python 测试或 63 个产品验收项相加。没有运行 GitHub Actions 或 macOS。

## T-P10 追踪

| 合同 | 实际覆盖 |
| --- | --- |
| Endpoint | 默认 VPN 可产生可见 DIRECT 例外；显式 host/子网/0 路由冲突拒绝 |
| VPN DNS | 默认 DIRECT 下可生成必需 VPN 意图；显式 DIRECT 冲突拒绝；DNS 也必须被 peer 覆盖 |
| LAN/本机/网关/系统范围 | 具名例外、同动作交叠全部保留来源、LAN 与企业网段冲突阻断、相反基础设施阻断 |
| first-match | 后续被遮蔽或禁用的冲突规则不生效；仅未匹配默认区域能加例外；用户原意图不变 |
| AllowedIPs | 精确/部分/空覆盖、仅缺一个地址、多个 peer 联合覆盖、默认 VPN 全域检查、DIRECT 洞、被遮蔽 VPN 规则 |
| peer 选择 | 最长前缀而非用户顺序；相同前缀跨 peer 拒绝；同 peer 重复项可归并；输入原样保留 |
| 输入/预算 | nil peer 拒绝、后端不匹配、非法/重复 ID、主机类必须 /32、限额、新增例外导致路由超限 |
| 版本/解释 | session/backend/generation/epoch 精确检查、未来版本拒绝、极值、相邻合并与 DIRECT 洞、默认例外来源 |
| 隐私 | 错误只含静态原因及不透明 ID；不回显地址，测试仅合成数据 |

`E_PEER_UNREACHABLE_RANGE` 在这里是配置集合覆盖错误，不是网络探测结果。协议数据没有被改写，也没有扩大 AllowedIPs。

## 剩余门槛

基础设施发现与输入完整性、NE Endpoint 外层传输、DNS 实际查询路径、peer 握手及服务器回程、多 peer 真机路由、Swift/macOS 原生执行、签名与扩展加载均 NOT RUN。

T-P08 仅有 context 纯函数检查，不代表真实异步取消完成；T-P04–06/P11/P12 与完整 Profile、DNS/IDNA/TTL 不在此次范围。S0 收尾、原工作流等价性和三路径最终验收不变。

本次 GitHub 重试最初的 create_tree 已返回成功；是否形成远端提交与 PR 以实际 GitHub 结果为准，不把 tree 对象创建当作分支已更新。上一轮工具拦截原因不可从无细节提示确定，不宣称已修复平台安全机制。
