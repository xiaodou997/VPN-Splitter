# EX-FLOW-02：TCP DIRECT relay 真机验证（第一轮）

日期：2026-10-14。代码：main `b2c5c05` + 本文件同批的 flow_project 版本修复。ADR：docs/adr/ADR-EX-FLOW-02-tcp-direct-relay.md。环境：macOS 26、arm64、StrongVPN（OpenVPN TCP，utun4）在线。

## 结论

- **数据面真机通过（LAN 目标）**：匹配 IP-CIDR 规则的 TCP flow 被 provider 接管，经 `NWConnection` 绑定 en0 建立替代连接并双向复制，curl 拿到真实 HTTP 200，relay 正常完成、计数归零、停止后无残留。
- **互联网 DIRECT 当前被 StrongVPN kill switch 拦截，fail-closed 行为正确**：匹配 DIRECT 的互联网 flow 打开替代连接失败后按 ADR 关闭该连接（curl exit 35/52），未静默回退 VPN、未泄漏。
- **循环检查通过**：provider 自建连接未被自身透明代理回捕（单次 curl 恰好 1 个 relayStarted，无倍增）。
- **未匹配 flow 不受影响**：出口仍为 VPN（216.131.73.244）。
- **发现并修复一个真实 bug**：`OSSystemExtensionRequest .replace` 要求 CFBundleVersion 递增；生成器此前写死 `1`，导致激活「成功」但旧扩展（2026-09-29）一直运行（`rulesLoaded=0`）。修复为构建时间戳版本号，合同测试锁定。

## 环境限制声明

- 本机 `spctl` 报告 `override=security disabled`（用户既有设置），因此 Gatekeeper 评估不构成默认环境验收；公证链路另行以 notarytool/stapler 证据为准。
- `systemextensionsctl developer on` 因 SIP 拒绝；未关闭 SIP/Gatekeeper，符合边界。
- 互联网出口直连是否可行取决于第三方 VPN 的 kill switch 设置；本轮未改动用户 VPN 配置。

## 时间线与数据

1. 签名构建 `20261014.1846`（Developer ID，扩展 sha256 `d142c5ea…`），notarytool 提交 `f99eb36e-53a6-440e-8a93-0658ef11f0e8` 状态 Accepted；staple/validate 通过；新扩展落盘 `/Library/SystemExtensions/8FC1B38A-…/`（旧目录 3115061D 为 09-29 版本）。
2. 规则通道全链路真跑：主 App「导出 DIRECT 规则到 Flow 桥」→ `rules.json`（0600 原子写）→ Probe App「重载规则并更新探针配置」→ `已写入 3 条` → 重启探针 → `rulesLoaded=3, rulesRejected=0`。
3. DOMAIN 样本 `ipinfo.io`：hostname 可见（本批 42/70 可见率约 60%），规则命中 → relayStarted → 替代连接失败（StrongVPN kill switch 阻断 en0 互联网出口；对照：bind en0 公网 exit 7，bind en0 网关正常）→ **fail-closed**（curl exit 35），relayFailed=1。
4. IP-CIDR 样本 `81.69.116.102`：同样 fail-closed（curl exit 52），relayFailed=2 累计。
5. LAN 样本 `192.168.2.1/32`（路由器 HTTP）：relayStarted=1 → **HTTP 200 经 relay 双向复制返回** → relayCompleted=1、relayActive=0、failed=0。
6. 未匹配对照 `ifconfig.me`：HTTP 200，出口 216.131.73.244（VPN）。
7. 停止探针后：`ipinfo.io` 恢复 VPN 出口，路由器直连正常；无路由/DNS/残留副作用（本机制只读写 flow，从不改系统网络）。

## 下一步

- 若用户愿意临时关闭 StrongVPN kill switch 复测互联网样本，可验证完整互联网 DIRECT 出口；否则互联网 DIRECT 在该 VPN 下按设计不可用（fail-closed 是正确行为）。
- APPLICATION 规则真机样本、UDP/QUIC、睡眠/切网、VPN 重连仍未验证。
