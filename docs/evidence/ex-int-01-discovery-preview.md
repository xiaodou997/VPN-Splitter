# EX-INT-01：第三方 VPN 只读识别与规则预览

日期：2026-09-27。起点 main `11f6b8a03d9094ce27470c98b3d8c9e6ffa923e0`。任务：EX-INT-01，S4-01 部分，RULE-02、EX-01/02/04/06/07、P-05/06、UX-03、DIAG-02/03。开发排队调整见 [ADR](../adr/ADR-EX-INT-01-external-first.md)，入口见 [操作说明](../external-development.md)。

## 实际新增的代码能力

独立 External 开发预览有实际 macOS 采集入口，不是展示合成网络的界面。按按钮后由 actor 调用 SCDynamicStore、SCNetworkInterface、getifaddrs 和固定数字 netstat 命令，组合当前服务、物理网关/接口、IPv4 路由及 DNS 地址摘要。两次语义路由和服务/接口对照不一致即失败；不把当前 VPN default 或旧保存网关当物理路径。

识别单一 IPv4 隧道上的 `/1` 对和 default 替换；多物理路径、多隧道、不完整/歧义模式、未知路由表拒绝。实际调用既有 PolicyCore first-match 编译器生成默认 VPN 的 DIRECT 例外预览，显示目标、物理网关、接口和已有直连记录的“不认领、不删除”。规则与本机/物理 LAN/已观察 DNS/保留地址重叠或涉及路由冲突时整体拒绝，无部分成功。

新 `external-run` 构建并打开仅本机 ad-hoc 的独立 SwiftUI 应用；`external-build` 仅编译；`external-test` 运行离线回归。无需 Go、开发签名、Network Extension 或 Helper。启动不自动采集，规则编辑、取消、睡眠/唤醒清理预览，观察最多留存 30 秒，无自动磁盘/剪贴板导出。已有 `run` 仍为 LocalDev，本批并未把界面塞入 LocalDev 或 WG Runtime。

**canApply 恒为 false。没有应用/删除路由、修改 DNS、停止原 VPN 或读取其凭据的实现。** 原 VPN 继续负责连接/认证；本批不声称真实第三方 VPN 分流可用，不声称厂商/加密/端点或强制流量策略已识别，不是全 resolver、全 IPv6 或实时网络观察器。独立 Helper 与执行/撤销必须在 EX-INT-02 另行实现。

## 实际执行

Linux x86_64，Swift 6.2.1、Python 3.13.5。Mac Runner 对原项目仍返回 project_path_not_found；没有使用无关项目目录。固定基线部分工作区：新增 ExternalCore 包/全部本批文件齐全；依赖恢复了 PolicyCore 的原样 IPv4.swift、Policy.swift、Compiler.swift 与原 Package.swift，逐个 Git blob 核对一致。没有恢复或运行原 Constraints.swift/旧 PolicyCore 测试，也不宣称全仓库构建。测试没有换用简化的地址类型或规则编译器。

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| ExternalTests Debug | 29 XCTest，0 失败，warnings-as-errors | 合成观察输入，真实新 parser/planner 与既有 IPv4/first-match 代码 |
| ExternalTests Release | 同一 29 项，0 失败 | 优化重跑，不累计成 58 个独立场景 |
| tests/external | 6 Python unittest 通过 | 本地依赖 manifest、只读源合同、UI 失效合同、实际命令分发/拒绝参数、构建参数与非 Mac 拒绝、macOS 源码 parse |
| 实际入口 | `/bin/bash dev.sh external-test` 完整通过 | 指本部分工作区中的上述套件，不是全仓库或 Apple SDK 测试 |
| 基线完整文件 | PolicyCore 的三份使用源与 manifest、dev.sh、AGENTS、roadmap、acceptance 原始 blob 核对 | 原源码/旧 WG/AppCore 没有修改，也未累加其旧测试数量 |

29 项覆盖 `/1`/default、无 VPN、多候选、错误网关/缺链路、DNS/LAN/保留目标、同级/更具体/scoped/cloned/blackhole 路由、已有条目不认领、整批拒绝、实际规则遮蔽/合并、大小/输入格式、过期/时钟倒退、脱敏、旧 netstat 计数列及 classful 前缀规则。复核 Apple netname/domask 后修正不能单按八位组数猜隐式网段的问题。测试 fixture 中曾有字符串替换误删相邻行，已改为按完整行过滤；最终两种构建均通过。

macOS 原生读取/SwiftUI 源执行 `swiftc -frontend -parse -target arm64-apple-macos26.0`，仅语法，不是类型检查、链接或 UI/采集成功。Linux 编译的 executable 是明确的“不支持此平台”分支，不能冒充真实 Mac app。原生采集尚未执行，不把源码中的调用或合成结果称为实际系统观测。

## 未执行与后续

本批 Mac SDK 构建/开窗、真实网络读取结果、第三方 VPN 实际兼容性、退出/睡眠等原生 UI 行为均 NOT RUN；受限路由执行/授权/所有权/持久化恢复/撤销仍未实现。没有读取用户网络、密钥、签名、旧快照或真实配置，没有安装工具或改变系统网络。输出网络内容不上传仓库；新测试仅含合成地址。

当前队列和验收追踪已改为 External 主线、OpenVPN 导入提前、WG 暂存；本批没有添加 OpenVPN 支持。WG-INT-10 的用户原生构建成功与 S0 真实路径样本独立保留，无需重跑或签名才能推进本任务。

按原目录 `git pull --ff-only` 后运行 `dev.sh external-test` 和 `dev.sh external-run`。第一次 Mac 运行重点核对是否正确显示物理网关与原 VPN 路由线索；不会自动添加规则。下一主线是 EX-INT-02 的有限执行/撤销，而非继续扩展只读 UI。回滚用后续 revert，保留本机数据、旧结果、缓存和锁；交付 main，不发更新包。
