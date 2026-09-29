# External Flow Bypass 开发入口

EX-FLOW-01 的目标不是立即替换现有 Route Bypass，而是先验证 macOS Transparent Proxy 在第三方 VPN 已连接时能否稳定提供规则所需的 flow 元数据。当前代码包含 first-match 规则核心与一个 pass-through provider 探针；没有流量复制、没有物理接口 DIRECT 转发，也没有可安装的系统扩展 bundle。

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

## 下一阶段

FLOW-02 才研究真正的 DIRECT flow copying：为匹配流建立新的远端连接，要求当前物理接口，并完成 TCP 数据双向复制；随后单独验证 UDP/QUIC、DNS、睡眠/切网、VPN 重连和循环避免。任何 requiredInterface/来源身份/hostname 能力无法稳定验证，都必须保留为不可用，而不是退化成全局 IP 路由。
