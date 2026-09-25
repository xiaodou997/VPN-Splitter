# ADR-014：WireGuard 固定源码的隔离编译与强制策略入口

日期：2026-09-25。状态：Accepted（WG-INT-02 编译候选；不批准真实执行或发行）。任务 S1-04 / S1-06 部分；T-WGB01–05；Refs #1。承接 ADR-013，不改变签名和真实网络验收门槛。

## 决策

把“协议源码能构建并链接”与“可以安全接管网络”分开验证。新增 `tools/wireguard/build.sh`，只在 macOS 26+ / arm64 上构建 Go c-archive 和 Swift 链接探针，检查最终产物包含实际桥接符号，不运行产物、不创建 Adapter 实例、不安装 App，也不改动现有 LocalDev 或 PacketTunnel 工程。

使用独立的 `third-party/wireguard-go/build-lock.json` 编译候选锁，而不是把上一批 `reference.json` 直接当发行依赖锁。WireGuard Apple 保留已审查 revision `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`；Go 核心改用官方 revision `ecfc5a8d54462e18e13c72173e2623d16d8e25a0`。官方 [Apple log](https://git.zx2c4.com/wireguard-apple/log/) 仍对应 2023 基线；[Go commit](https://git.zx2c4.com/wireguard-go/commit/?id=ecfc5a8d54462e18e13c72173e2623d16d8e25a0) 是 2026-05-22 的后续修正。不能据“较新”推定安全审查已经通过。

核心使用该 revision 自身的 go.mod/go.sum。把固定 Apple api-apple.go 复制为核心模块内的独立 main 子包，直接 `go build -mod=readonly -buildmode=c-archive`。不执行旧 Apple Makefile、不复制或修改 GOROOT、不把 2023 年 runtime 补丁盲套到现代 Go。睡眠计时语义、版本报告和桥接兼容性仍需后续运行验证；当前通过源码 revision 和产物哈希记录来源，不以 wgVersion 作为验收。

工具链候选限 Go 1.26.8 / 1.27.1（[官方发布记录](https://go.dev/doc/devel/release)）。使用用户已安装的工具链，设 `GOTOOLCHAIN=local`，不自动下载工具链、不安装软件。[Go 工具链选择](https://go.dev/doc/toolchain) 与 [模块验证](https://go.dev/ref/mod#go-mod-verify) 是构建行为依据；模块校验不等于漏洞扫描。

## 明确的网络和文件范围

默认 preflight 只读检查。`build --fetch` 才允许从两个固定公开仓库和 Go 官方模块代理/校验服务下载；没有 --fetch 时只使用缓存，源码不足即拒绝。Git 不使用用户凭据助手或替换对象，TLS 与 Go 校验不关闭。源码先核对 revision/tree，再逐文件核对 Git blob，拒绝链接、越界归档、文件集合变化及依赖锁变动。

每次构建写到独立 `.local/wireguard-engine/build.*`，串行锁不删除。没有强制覆盖、reset/clean、清空用户配置或修改全局 Go/Xcode 配置。失败保留本次日志和目录，不把前次成功产物当作本次成功。不防御同一用户恶意进程在检查后篡改文件；不是供应链安全的完整证明。

## 小范围策略补丁

`policy_hook.py` 严格校验原 Adapter 的 Git blob，再执行明确次数的上下文替换，结果还必须匹配固定的 patched blob。可审查补丁存放在 `third-party/wireguard-apple/patches/0001-required-policy-settings.patch`；版权和 MIT 声明保留。

Adapter 初始化增加**没有默认值**的 networkSettingsProvider。start、update、resume 三处系统设置生成都调用它；错误封装为 policyNetworkSettings，不回退到 AllowedIPs 生成的系统路由。协议 UAPI、AllowedIPs 和密钥路径不在本补丁中改写。

探针把该入口与 ManagedSettingsApple 对象工厂一起类型检查，但函数从不被调用。它故意不是生产 settings binding：真实控制器仍须按每次调用的协议配置核对最新 session / generation / networkEpoch、Peer 身份及路由输入，不可把探针捕获的静态 draft/current 直接拿去运行。

## 未关闭的门槛

上游设置超时后继续、wgSetConfig / Device.Up 返回值、部分失败资源清理、logger/handle 并发、utun 归属、凭据交付、DNS 重解析和真实撤销仍未修复。本批只修“必须经过策略入口”，不把全部接入风险标为解决。完整传递依赖许可证清单和可达漏洞检查也尚未通过；顶层 MIT 副本不能替代这些检查。禁止将编译候选作为可发行或可连接后端。

本批不把核心接入 LocalDev、正式 Provider 或任何安装流程。原 Provider 继续拒绝连接；开发签名暂不恢复。待 native build 结果与运行前安全边界明确后，再进行受控签名联调。撤回采用后继提交，不删除用户数据和凭据。
