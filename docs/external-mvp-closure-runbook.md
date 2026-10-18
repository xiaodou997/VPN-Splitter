# External MVP 关闭 + WG 真机闭环运行手册

日期：2026-10-18。性质：现场操作手册；每次实验后把结论与证据路径补进 docs/evidence/ 并更新 roadmap。本文不含任何秘密；真实凭据留本机。

标记说明：🔐=需管理员密码；👤=只能用户亲手做（睡眠/切网/churn/系统批准）；🤖=可脚本/代理代劳。

## 0. 共同前置（每次真机会话前核对）

- 代码：本机 main 与远端一致（`git pull --ff-only`，构建前比对 sha256）。
- 第三方 VPN（StrongVPN）在线；已知其 kill switch 使互联网 DIRECT 在 Flow 层 fail-closed——这是设计行为，不是缺陷。
- 控制 App 构建（改代码后必做）：
  ```bash
  /bin/bash dev.sh external-helper-build --route-trial --sustained \
    --identity "Developer ID Application: SHIYU FENG (V6M88BQG7C)" --team-id V6M88BQG7C
  ```
- 部署：拷贝产物到 `/Applications/VPN-Splitter-ExternalControl.app`；🔐 Settings 页「注销 Helper」→「注册 Helper」；「测试 Helper 通信（只读）」须通过。
- 规则方案：常规在规则页保存；边界测试可直接写 profiles.json 后「重新载入」。
- 会话开始：预检 → 勾选「我已核对提案」→ 开始，**必须用单条 AppleScript 连贯执行**（15 秒确认窗；辅助往返超时=`notApplied` 安全关闭，已被顺带验证）。
- 观察基线命令：`route -n get <目标IP>`（期望物理 en0）、`curl ifconfig.me`（目标出口=宽带）、`curl ident.me`（对照=VPN）；不钉 IP。
- 终止判定三件套：Helper 日志 `lease_terminal state=… owned=0 cleanup=none`；GUI 剩余回执 0；恢复页「核查恢复状态」= noRecovery。

## 1. 实验 A：churn 压测 sustained（ADR-EX-INT-11 豁免有效性）

目标：制造 en0 克隆邻居行生灭，验证会话跨过 churn 存活，或终止时 route_shapes/epoch 差集精确对得上豁免形态。

1. 🤖 起采样：`python3 tools/external/sample-neighbor-churn.py --interface en0 --output .local/en0-churn-runA.jsonl --seconds 3600 --interval 5`（只读，0600，不落原始地址）。
2. 🤖 起 sustained 会话（单域名方案如 `DOMAIN ifconfig.me`）；每 60 秒记录 iface/target/control 三值（照 run2–run4 格式）。
3. 👤 会话活跃期间制造 LAN churn：对其他 LAN 设备批量 ping/ARP 触发邻居行生灭；禁用/启用 Wi-Fi 更强但会闪断。**可能影响局域网连通性。**
4. 判定：churn 期间会话存活、路由无漂移为最佳；若终止，GUI route_shapes 的 `epoch_added/epoch_removed`（上限 4 条+溢出计数）须与采样器 churn_shapes 对得上；fail-closed + 零残留算方向正确但豁免未证。
5. 证据：采样 jsonl、Helper 统一日志、三值记录 → docs/evidence/ex-int-11-churn-stress.md。

## 2. 实验 B：睡眠中途样本（route sustained）

目标：合盖睡眠前后会话行为 + 解开 run4 BLOCKED（route_shapes 读不出之谜）。

1. 前置：GUI 幻影小窗修复已随本次构建部署（窗口应可自愈）；`pmset -g log | grep -E "Sleep|Wake"` 时间轴备用。
2. 🤖 起 sustained + 60 秒采样循环。
3. 👤 **合盖睡眠 N（≥5）分钟再唤醒**。注意：睡眠大概率打断 StrongVPN（历史上 OpenVPN inactivity/misc.c:785），会顺带产生"真实网络变化"样本。
4. 判定：睡前撤销或 networkChanged 保守终止 + owned=0 + cleanup=none + 唤醒后 noRecovery；唤醒后窗口尺寸应恢复 1080×720（验证幻影小窗修复）；若再现退化，记录 AX 树状态并回修。
5. 证据 → docs/evidence/ex-int-sleep-midstream.md。

## 3. 实验 C：切网中途样本 + route-trial 多目标

目标：活动租约内切换物理网络的正确撤销；60 秒窗多目标全链路。

1. 🤖 基线采样 + `tools/external/watch-network-transition.py --target-file … --interface en0 --output .local/transition.jsonl --seconds 80`（只读、单调时钟对齐）。
2. 🤖 起 sustained；👤 **切到热点/另一 Wi-Fi（活动租约内，会短暂断网）**；观察 Helper 是否 networkChanged 撤销、事务终态与物理路径变化在同一时钟；👤 切回。
3. route-trial 多目标：方案放 2+ 条规则；60 秒窗内验证全部目标双出口（curl 各目标对照）、到期全部撤销。60 秒窗内切网 = 中途撤销样本：验证 DELETE 正确、noRecovery。
4. 判定：切网 fail-closed 零残留；多目标提案/应用/撤销全对；时间对齐无"聊天往返"歧义。
5. 证据 → docs/evidence/ex-int-switch-midstream.md。

## 4. 实验 D：Flow 睡眠/切网中途样本

目标：relay 活跃期间睡眠/切网，验证 fail-closed 无泄漏、探针可恢复。

1. 前置：签名+公证的 Flow Probe App 装 /Applications、扩展已激活、规则桥文件就位、探针启动；LAN STUN 替身 `python3 tools/dev/stun_server.py 9999 <本机LAN IP>`。CFBundleVersion 必须递增（.replace 静默保留旧扩展的教训）。
2. 🤖 TCP 长连接 + `python3 tools/dev/stun_check.py <LAN IP> 9999` UDP 往返保持活跃。
3. 👤 合盖睡眠再唤醒 / 切网（同实验 B/C 窗口，可合并成一次会话）。
4. 判定：relay 计数 Completed/Failed/Cancelled 无异常泄漏、无残留 relayActive、唤醒后 NWPathMonitor 接口唯一（relayRefusedInterface 计数合理）、未匹配 flow 不受影响、探针手动重启可恢复。
5. 证据 → docs/evidence/ex-flow-sleep-switch.md。

## 5. 实验 E：分钟级稳定性补样本（可选）

run4 117 分钟已是当前最长；roadmap 只剩"churn 发生时被豁免的加长样本"（并入实验 A）。如要 2 小时样本：同 run4 协议；样本因 ISP/VPN 侧原因中断时如实记录外部原因，不计软件缺陷。

## 6. 实验 F：EX-FLOW-04 hostname 分桶受控实验

前置：ADR-EX-FLOW-04 schema v2 与计数点**先实现**（EX-FLOW-04A，离线）并 `dev.sh external-flow-test` 通过；签名+公证重建 Flow Probe（CFBundleVersion 递增）。

1. 固定应用 × 固定目标矩阵（curl/URLSession、Chrome/Electron、python/node、IP 字面量、自带 DoH 应用），无规则纯探针跑固定窗口。
2. 「刷新并发布脱敏报告」：本地 snapshot 看分桶，发布物只有粗类直方图。
3. 对照 FLOW-01F 基线（38%；curl 密集窗 60%；重启后 89% 小样本）。
4. 判定：各类来源可见率分布表落地，验证"缺失=少命中不误命中"安全等价，形成 Flow 层 DOMAIN 规则定位结论。
5. 证据 → docs/evidence/ex-flow-04-bucketing.md。

## 7. WG 真机最小闭环（签名=本机开发签名，非发行）

用户已确认发行签名（Developer ID/公证/DMG）暂缓；但系统扩展真机激活仍需要 **Apple Development 开发签名 + development provisioning profile**——这是本地开发身份，不是发行。

已完成（离线）：go1.27.1 本地 SDK（`PATH="$HOME/sdk/go1.27.1/bin:$PATH"` 前缀即可过 preflight，不动系统 Go）；`apps/macos/Config/Signing.local.xcconfig` 填好 `VPN_DEVELOPMENT_TEAM = V6M88BQG7C`（gitignored，留本机）。team 选择依据：B65GG63L78 的证书虽在本机 Keychain，但其 Apple ID 未登录 Xcode（`No Account for Team`），V6M88BQG7C 的账号已登录 Xcode 可用。development profile 已通过一次性 `-allowProvisioningUpdates` 构建拉取到本机；`provider-build --sign` 复验 PASS（`codesign --verify --strict` 通过，TeamIdentifier=V6M88BQG7C）。注意：对生成工程直接跑 xcodebuild 时必须用绝对路径（相对路径会触发 SPM 模块解析失败）。

待用户操作（按序）：

1. 👤 Finder 从 `.local/wireguard-engine/provider.52jf5e4t/Products/Release/VPN-Splitter.app` 拷贝到 /Applications；系统设置手动批准系统扩展（🔐 管理员）。
2. 合成配置保存/交付（首轮单 peer、IPv4 数字端点、Include、无 DNS 字段，ADR-WG-INT-10 边界）；验证取消与超时路径。
3. 👤 现场授权启动真实隧道：观察握手、指定目标 VPN 与直连双路径对照（照 S0 双出口证据格式）。
4. 停止隧道，独立观察系统恢复（路由/DNS 回物理）；证据 → docs/evidence/wg-int-11-real-closure.md。

## 8. 汇总：关闭判定

External MVP 关闭 = 实验 A–D 证据齐 + 幻影小窗修复真机确认 + roadmap「External 下一主线」剩余项清零或经 ADR 调整范围。WG 真机闭环 = 第 7 节 1–6 全过且证据归档。两项都完成前，不宣称 v0.1 可用、不触发发行流程（S5 仍整体暂停）。
