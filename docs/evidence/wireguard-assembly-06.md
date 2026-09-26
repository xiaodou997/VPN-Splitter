# WG-INT-06：实际配置与策略设置组装

日期：2026-09-26。基线 main `48eee077e071c6d684fb61934342b995200f66b3`。
任务 S1-04/S1-05 部分；T-WGF01–04；Refs #1。
[ADR-018](../adr/ADR-018-wireguard-plan-assembly.md)、[指南](../wireguard-assembly.md)。

## 已实现

新增 PreparedWireGuardPlan：完整无密钥投影、自动基础设施/Peer 约束、同上下文
underlay、显式 DNS、真实 PolicyCore 编译到现有 ManagedSettingsDraft。
保留 first-match、接口主机位和 Peer/AllowedIPs 顺序；缺字段/不支持/超限整批拒绝。
完整复核包含源、规则、underlay、DNS 选择和上下文。

新增 ManagedWireGuardAssembly：以实际 TunnelConfiguration 为源，冻结快照，
创建运行绑定和必选策略设置回调；每次设置请求重新投影及复核，版本前后检查。
构建探针复制该源文件并显式依赖本地 PolicyCore；原探针保留，新增组装 API 检查。
不调用 Adapter.start/update，不应用 NE 设置，不读取 Keychain，不触碰正式 Provider。

## 本轮执行

环境：Linux x86_64、Swift 6.2.1。Mac 项目入口仍返回 project_path_not_found，
没有通过其他项目绕过。普通容器 Git 下载 DNS 失败；源码由 GitHub 连接器读取，
测试依赖按完整 Git blob 精确重建，未用简化算法或类型替身代替 PolicyCore。

PolicyCore Package.swift 和全部四个生产文件与远端一致：045bf250、35e75365、
8eb64eff、8ed07059、d397ac84；ManagedSettings Package.swift、SettingsInput、
SettingsDraft 分别匹配 25585a40、9a953a7f、2f8d7917。
修改前 build.py 与 8a7ea23e、Probe.swift 与 db5b375a 一致；不改的 bridge_assets.py
与 ffa98f49 一致。新代码只追加规划类型，不改上述原核心实现。

| 检查 | 实际结果 | 范围 |
| --- | --- | --- |
| 新增组装 Swift 测试 Debug，warnings-as-errors | PASS，19 tests | 含端点参数化，使用真实 PolicyCore |
| 同一新增测试 Release，warnings-as-errors | PASS，19 tests | 优化构建 |
| 新增 Python 接线测试 | PASS，8 tests，无跳过 | 真实复制、路径拒绝、现有目录保留及 SwiftPM 清单求值 |
| 原生组装源与 Probe 的独立 Swift parse | PASS | 仅语法，不是 Apple SDK 类型检查 |
| Python AST / 变更检查 | PASS | create_probe 外的原构建函数及类 AST 未变 |

Python 接线测试只隔离并执行实际 create_probe / read_ordinary 函数；没有调用
下载/Go/原生链接阶段，也没有把替身产物当作引擎通过。SwiftPM dump-package
只求值生成清单，不编译 WireGuardKit 或执行 VPN。

复现本轮已执行范围：

```sh
swift test --package-path Packages/ManagedSettings --filter assembly -Xswiftc -warnings-as-errors
swift test --package-path Packages/ManagedSettings --filter assembly -c release -Xswiftc -warnings-as-errors
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -p test_assembly.py -v
```

未重跑旧 ManagedSettings 26 项、PolicyCore 独立套件、AppCore/LocalDev、Go race、
WireGuardSupport 或整套 engine-test。原生产依赖重建完整，旧测试未在本轮计作 PASS。
用户对 48eee07 的原生 PASS 另记，不覆盖本轮修改后的构建。

T-WGF01：Include / Bypass、/0 协议不扩大路由、host bits、first-match、Peer LPM、
相同前缀歧义及范围超出拒绝；端点/接口/DNS/underlay 冲突拒绝。
T-WGF02：地址族/端点/端口/搜索域拒绝，MTU、DNS resolver 与路由分离、所有资源预算。
T-WGF03：完整源、端口、规则、DNS 选择、拓扑或上下文变化拒绝；无秘密字段输入。
T-WGF04：源字节入探针、显式本地依赖、缺文件/符号链接/重入拒绝；无运行调用。

## 未完成与恢复

NOT RUN：本批新原生组装代码的 Apple SDK 类型检查和完整链接、实际 Provider、
凭据交付、可信描述符、签名、握手、分流/双出口、DNS 和撤销。underlay 空输入
不是已观察网络；版本闭包必须由生产控制器维护，工厂本身不是网络监视器。
仍缺正式 Provider/Keychain/会话控制器接线；不将这一段代码当成可连接 VPN。

无新远端依赖、Go 版本、权限、安装、工作区/凭据格式或 UI 变化。原 C/Go/Swift
补丁链与版本锁均未更改。开发签名仍暂停到首次真实联调前。源码回退用后继提交，
不删除用户配置/密钥、历史构建结果、缓存或锁文件；唯一交付入口为 main。
