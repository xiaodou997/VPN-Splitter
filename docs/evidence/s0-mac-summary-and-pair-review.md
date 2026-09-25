# S0：用户回报的采集摘要与配对复核工具

记录日期：2026-09-25（记录日期，不推断设备采集日期）。  
任务：S0-01/02；S0-03 准备。  
结论：采集 smoke **USER_REPORTED_PASS**；实际分流 **NOT RUN**。  
关联：PR #2 / Issue #1；不关闭 S0 阶段。

## 用户提供的事实

用户按上一轮操作反馈了两份 `s0-summary-v1`，after 在消息前面、before 在后面。记录按 phase 解读，不按粘贴顺序推断时间：

| 字段 | before | after |
| --- | --- | --- |
| capture_failed_commands | 0 | 0 |
| ipv4_full_tunnel_hint | NONE_OBSERVED | SPLIT_DEFAULT_PAIR |
| network_mutations | NONE | NONE |
| traffic_probes | NOT_RUN | NOT_RUN |
| raw_files | PRIVATE_NOT_REDACTED | PRIVATE_NOT_REDACTED |
| snapshot_consistency | SEQUENTIAL_NON_ATOMIC | SEQUENTIAL_NON_ATOMIC |
| compatibility | UNKNOWN | UNKNOWN |
| actual_egress | NOT_TESTED | NOT_TESTED |

这支持“用户运行的采集没有报告命令失败，连接后识别到成对 /1 路由迹象”的有限结论。用户未提供当前原始路由、精确系统 build、实际脚本版本、采集时间或出口流量证据；不独立认证其环境/状态，也不将旧快照中的地址沿用为当前物理网关。原采集脚本包含 Darwin/arm64/macOS 26+ 前置检查，但摘要没有这些原始字段，不能冒称已完成工具链/系统版本矩阵。

无需再次上传原始 before/after，也没有请求密钥/账号。该报告仅记录用户已经提供的不含地址摘要。

## 这一步不能说明什么

NONE_OBSERVED 不证明没有其他 VPN；SPLIT_DEFAULT_PAIR 不证明不存在 enforceRoutes、过滤器、Kill Switch 或其他强制机制。零采集失败不证明 DNS 可达、DIRECT 可行、实际公网源地址变化、IPv6 覆盖或撤销成功。

S0-01 仍需本地真实目标与期望出口清单；S0-02 增加了用户回报的采集执行证据，但物理路径归因/目标核验仍待完成。S0-03 单目标例外与撤销尚未运行。S0-04 的 Managed 等价认证与完整 VM+VPN+gost 替代性尚未证明。S1–S5 未因此通过。

## 本次实现

`tools/s0/review-pair.sh`、`pair-paths.awk` 直接读取已经采集的私有快照，检查物理默认路径连续性、接口/hardware ports、IPv4 隧道歧义及 DNS/代理文本差异。无新网络采集、无主动连接、无特权和网络修改。只有一对快照时自动选择，多对时要求明确本机目录末尾名称；不按时间猜测、不删旧数据。

新增 `share-summary.txt` 只输出固定枚举，地址与接口候选仅写私有 TSV。`CANDIDATE_REQUIRES_LIVE_PREFLIGHT` 不代表允许写路由；兼容性仍 UNKNOWN、实际出口仍 NOT_TESTED。具体限制与 S0-03 条件见 [操作说明](../../tools/s0/PAIR-REVIEW.md)。

## 实际执行的测试

执行环境：Linux x86_64；Bash 5.2.37、mawk 1.3.4、Python 3.13.5。无第三方 Python 依赖。只运行以下新增工具相关检查：

```sh
/bin/bash -n tools/s0/review-pair.sh
python3 -m unittest discover -s tests/s0 -p 'test_pair_review.py' -v
```

结果：语法检查通过；新增 30/30 个合成离线测试通过。测试过程不读取用户原始网络文件、不采集宿主机网络状态、不写路由/DNS、不产生网络探测。修正测试脚本的仓库路径定位后完成上述最终通过记录。

原有 27 项工具测试**本轮未重跑**，不能把数字相加宣称本轮 57/57。63 个产品验收测试也没有因此增加通过数。新增脚本使用 Bash 3.2/POSIX awk 兼容语法，但 macOS 原生执行仍待用户验证；用户已回报通过的是上一版 collect-network.sh，不是本次新增工具。

## 后续与停止条件

运行配对复核不要求 VPN 再次切换。先分享它的无地址摘要；本机保留候选数据和受控目标。候选不唯一、接口/地址变化或快照异常时先解释原因，不强制添加路由。

S0-03 需当前真实目标、授权、本机恢复入口、现场路径检查与独立写入/撤销方案；只有 D 实际直连、V 仍可经 VPN 访问且安全撤销均有证据后，才能记录该兼容样本实验通过。没有联网测试就继续 NOT RUN，不按文档或工具代码数量推进阶段。
