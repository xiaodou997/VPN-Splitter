# External Flow Bypass 开发入口

EX-FLOW-01 的目标不是立即替换现有 Route Bypass，而是先验证 macOS Transparent Proxy 在第三方 VPN 已连接时能否稳定提供规则所需的 flow 元数据。当前已有 first-match 规则核心、TCP pass-through provider、unsigned App + systemextension 构建骨架、显式控制器以及主程序只读报告桥；没有流量复制或物理接口 DIRECT 转发。

## 当前安全入口

普通用户执行：

```bash
git pull --ff-only && \
/bin/bash dev.sh external-flow-test && \
/bin/bash dev.sh external-flow-build
```

`external-flow-test` 运行 ExternalFlowCore Debug/Release 与合同测试，不激活 Network Extension。`external-flow-build` 现在生成隔离 Xcode 工程并构建 unsigned 的 Flow Probe App + `.systemextension`；不会签名、安装、注册配置、打开 App 或启动 provider。成功摘要明确包含：

```text
schema=external-flow-build-v2
compile_link=PASS
execution=NOT_RUN
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
signing=UNSIGNED
flow_copying=NOT_IMPLEMENTED
```

## FLOW-01 provider 行为

`ExternalTransparentProbeProvider` 首批只设置 outbound TCP Transparent Proxy 匹配规则并观察进入 `handleNewFlow` 的 flow；UDP/QUIC 不在这次探针范围，避免把 DNS/UDP 干扰混入首个能力判断。它只累计以下计数，不记录或回传真实域名、App ID、IP、端口或报文：

- flow 总数；
- TCP / UDP 类型计数；
- 是否出现 `sourceAppSigningIdentifier`；
- 是否出现 `remoteHostname`；
- TCP remote endpoint 可见性。

`handleNewFlow` 始终返回 `false`。根据 Apple 对 `NETransparentProxyProvider` 的定义，这表示该 flow 继续由系统连接最终目的地；本探针不打开 `NWConnection`、不读取/写入 flow 字节、不宣称 DIRECT。

包含 App/域名规则的真正执行要等 FLOW-01 真机证据：至少确认 Transparent Proxy 与原第三方 VPN 共存，来源 App signing identifier 和 connect-by-name hostname 的可见性符合预期，并明确无法观察时的降级行为。

## 规则核心

`ExternalFlowPolicy` 复用 Rule V2 的顺序，支持 IP-CIDR、DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD 和 APPLICATION 的 first-match。APPLICATION 在执行前必须由 UI 的软件名搜索解析为稳定 signing identifier；未解析直接阻断。

当前所有匹配动作仍只有 DIRECT 意图；未匹配 flow 返回 `systemDefault`，含义是交给系统/原第三方 VPN。FLOW-01 不执行这个 DIRECT 意图。

## FLOW-01C：显式激活/配置控制器

Flow Probe App 现在包含独立控制器，但没有任何自动启动行为。用户必须依次显式执行：

1. “请求激活 System Extension”：仅提交 `OSSystemExtensionRequest.activationRequest`。App 不在 `/Applications` 时直接拒绝。
2. “保存禁用状态的探针配置”：使用 `NETransparentProxyManager` + `NETunnelProviderProtocol`，写入本探针 bundle ID，`isEnabled=false`，不启动 provider。
3. “启动探针”：重新加载已保存配置，显式启用后调用 `startVPNTunnel()`。
4. “停止探针”：只请求停止连接，保留配置和扩展安装状态。
5. “移除探针配置”：停止连接并移除本应用的 Transparent Proxy preference；不自动停用 system extension。

Apple 文档要求 system extension 从 App bundle 的 `Contents/Library/SystemExtensions` 激活，并在激活时校验 App 位置、签名和 entitlement；当前 unsigned 构建因此只能做编译/打包证据，不能用于激活验收。

App/extension entitlement 生成器已切换到 Developer ID system-extension 形式的 `app-proxy-provider-systemextension`。真实 profile 是否授予该 entitlement 仍需签名构建验证。

## 应用规则选择器

External 主界面的 APPLICATION 规则不再要求用户手写 Bundle ID。点击“选择应用…”会只读扫描 `/Applications`、`/System/Applications` 和用户 Applications 目录，候选必须通过代码签名有效性检查并取得 Signing ID。

规则保存两项信息：

- 用户可读显示名；
- 稳定 `applicationIdentifier`（Signing ID）。

不会保存应用文件路径。用户手动修改显示名时旧 Signing ID 会立即清除，避免 UI 指向新名字而执行仍匹配旧 App。未绑定稳定身份的 APP 规则可以保存草稿，但 FlowPolicy 不允许执行。

## FLOW-01D：主程序脱敏报告桥

Flow Probe App 与主 External App 是不同容器。Apple 的 `NETransparentProxyManager.loadAllFromPreferences` 只返回与“调用 App”关联、此前保存的 Transparent Proxy 配置，因此主程序不直接加载或控制 Flow Probe App 的 preferences。

FLOW-01D 使用单向诊断桥：

```text
Transparent Proxy Provider
        ↓ provider message: probe-report-v1
Flow Probe App
        ↓ user-local snapshot.json (0600)
VPN-Splitter 主程序 / Flow 实验
```

Probe App 只有用户点击“刷新并发布脱敏报告”时才执行：加载自己的配置；若连接为 connected 且 connection 能作为 `NETunnelProviderSession`，发送 `probe-report-v1`；解码有界计数；写入 `~/Library/Application Support/io.github.xiaodou997.VPNSplitter.FlowProbeBridge/snapshot.json`。

快照只含：

- 配置数量、是否 enabled、连接状态；
- 报告时间；
- 总/TCP/UDP flow 数；
- 有 App Signing ID / remoteHostname / remote endpoint 的 flow 数。

不含真实 hostname、Signing ID、Bundle ID、IP、端口或 payload。主程序只读该文件，不能通过它启动/停止 provider、保存 preferences 或取得任何 route/flow 执行权限。同一用户下的其他进程理论上可以伪造诊断文件，因此它只用于 UI 能力观察，不能作为安全授权或实际出口证明。

主程序 Flow 页面不会直接访问 `NETransparentProxyManager`；点击“读取最新本机报告”只读取快照，并对超过 5 分钟的结果标记为旧报告。

## 下一阶段

FLOW-02 才研究真正的 DIRECT flow copying：为匹配流建立新的远端连接，要求当前物理接口，并完成 TCP 数据双向复制；随后单独验证 UDP/QUIC、DNS、睡眠/切网、VPN 重连和循环避免。任何 requiredInterface/来源身份/hostname 能力无法稳定验证，都必须保留为不可用，而不是退化成全局 IP 路由。
