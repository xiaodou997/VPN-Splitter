# S1-02：PolicyCore 首个纯逻辑实现与实际测试

日期：2026-09-25。类型：助手开发环境内实际执行；不含 Mac 网络测试。任务 **S1-02 IN PROGRESS**，不是整个任务或 S1 阶段关闭。源码和构建说明：[Packages/PolicyCore](../../Packages/PolicyCore/README.md)。

此页记录上一轮的历史结果。后续 T-P10 实现与 79 项完整回归见 [新证据](s1-tp10-tests.md)，下方 NOT IMPLEMENTED 是当时状态。

## 环境与提交范围

补丁基线为 main `05f6e828d59983d44854ea863751b21128d80ea9`。GitHub 写入调用被工具拦截，本轮没有创建远端分支、提交或 PR；交付为本地源码包、补丁和实际测试日志。S0 工具 PR #2 保持独立、未合并；此分支仅复用其相同 `.gitignore` blob 来防止切换分支后误提交本地数据，不复制私有快照或测试目标。

实际运行：Linux x86_64；`Swift version 6.2.1 (swift-6.2.1-RELEASE)`；target `x86_64-unknown-linux-gnu`；SwiftPM/XCTest；无第三方包依赖。Manifest 最低 tools 6.0、language mode 6、macOS 26.0。不能从 manifest 推断 Swift 6.0 或 macOS 已实测。

## 实际命令及结果

从仓库根目录执行以下命令（开发中首次在包目录使用等价命令，最终按下列命令重跑）：

```sh
swift test --package-path Packages/PolicyCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/PolicyCore -c release -Xswiftc -warnings-as-errors
```

| 构建 | 实际结果 | 范围 |
| --- | --- | --- |
| Debug | 42/42 XCTest，0 failures | 编译及所有纯逻辑用例 |
| Release | 42/42 XCTest，0 failures | 同一套用例的优化构建回归 |
| 固定种子等价性 | 每个构建均为 64 组策略、37,615 次地址对照 | 原规则解释、来源分区和最终路由动作一致 |

42 为唯一 XCTest 用例数，不把两个构建累计说成 84 个不同用例；也不与 S0 的 Python 工具测试或 63 个产品验收项相加。Swift Testing 自动输出的 0 tests 不是这组 XCTest 的统计。

随机策略每组 40 条，混合全空间与重叠网段、禁用规则、两种默认动作。检查每个输入/输出 CIDR 边界形成的区间端点和额外随机地址；输入解释器按掩码逐条扫描，编译器用区间减法，两者不共用匹配算法。固定种子 1–64 可重放失败；不是穷举所有可能策略，也不是系统最长前缀选路的实测。

## 覆盖与验收映射

| 需求/产品测试 | 本轮覆盖 | 未覆盖 |
| --- | --- | --- |
| RULE-01 / T-P01 | 规范 IPv4、主机位归一、非法缩写/八进制/Unicode、全部前缀、/0、/32、解码绕过拒绝 | 域名 IDNA、IPv6 解析 |
| RULE-02 / T-P02–03 | 顺序、遮蔽/部分遮蔽、同动作合并、原始归属、完整无重叠分区、独立解释器对照 | NE included/excluded 与真实出口 |
| P-06、RULE-04 / T-P07 | REJECT、IPv6、域名待实现、未知类型、External Include、强保证拒绝；禁用草稿不执行 | 运行时 capability 探测 |
| RULE-05、REL-02 / T-P08 | session/backend/generation/epoch 相等性；过期、未来版本与计数极值 | 真实异步回调、取消、网络发现 |
| P-06 / T-P09 | 1,000 输入阈值、降低阈值、2,048 路由硬阈值、碎片化阻断、不截断 | DNS 映射上限、加入基础设施后的安装上限 |
| T-P10 | **NOT IMPLEMENTED / NOT RUN** | Endpoint/DNS/LAN/AllowedIPs 约束；必须下一切片补齐 |
| T-P04–06、P11–12 | 不标 PASS | DNS 共享地址冲突/TTL/IDNA、完整 Profile schema 迁移 |

额外测试验证错误不回显敏感选择器/显示名、重复 ID（包括禁用项）、空上下文、纯计划限制提示及编译结果确定性。Codable 仅用于地址/CIDR 的字符串形式，不宣称完整配置已经可导入导出。

## 安全、恢复和边界

没有网络读取或写入、sudo、shell 执行、DNS 查询、配置/凭据读取、扩展安装或真实 VPN 连接。本轮无需撤销任何网络更改。测试全部合成；没有把用户地址、域名、机器名或原始日志写入仓库。

能力 presets 是计划合同，不代表任何安装环境获得兼容认证；`.external` 并不是 S0 检测结果。返回 IPv4PolicyPlan 明确缺失 DNS/基础设施/运行时验证，不能直接下发。S0 的已有用户实测结论和未补证据保持原状态。

## 下一项

在 macOS 26 arm64 执行同一包的 Debug/Release 测试，记录工具链；补齐 S1-02 的 InfrastructureRequirement/peer 范围检查和 T-P10。之后由 S1-01/03–06 建立签名最小工程并验证 WireGuard，不用本轮测试替代签名、DNS、重连或真实出口验收。
