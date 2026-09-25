# S0 配对用户反馈与单目标准备工具

记录日期：2026-09-25。任务 S0-02 / S0-03 准备。PR #2；原分支基线 `256fdce`。

## 1. 用户回报（不是本环境重新采集）

用户已在会话中提供 `s0-pair-review-v1`，记录为 **USER_REPORTED_PASS：配对工具 smoke**。关键字段：

```text
input_pair=VALID_CAPTURE_FILES
recorded_platform=IDENTICAL_RECORDED_VALUES
same_machine=USER_MUST_CONFIRM
snapshot_freshness=NOT_ASSERTED
physical_default_before=UNIQUE
physical_default_continuity=MATCH
vpn_ipv4_default_pair=SINGLE_PAIR
other_ipv4_tunnel_routes=NONE_OBSERVED
default_lookup_before=MATCH
default_lookup_after=MATCH
physical_interface_activity=ACTIVE_BOTH
physical_hardware_mapping=LISTED_BOTH
physical_ipv4_addresses=UNCHANGED
dns_snapshot=CHANGED_TEXT
proxy_snapshot=IDENTICAL_TEXT
network_extensions_after=PRESENT_REVIEW_LOCALLY
pair_readiness=CANDIDATE_REQUIRES_LIVE_PREFLIGHT
network_mutations=NONE
traffic_probes=NOT_RUN
live_state=NOT_CHECKED
gateway_reachability=NOT_TESTED
enforcement=UNDETERMINED
compatibility=UNKNOWN
actual_egress=NOT_TESTED
```

未独立验证确切 macOS build、时刻、同机身份、代码 revision 或原始文件；不引用历史地址当当前网关。文本级 DNS 变化和扩展存在不构成强制机制归因。物理路径连续性只对存档成立。

## 2. 新交付

`tools/s0/preflight-target.sh`：本地交互输入两个获准 IPv4 目标，显式确认后只读采集当前路径；独立检查唯一物理默认路由、同网关同隧道的 /1、首尾路径候选、接口/hardware ports、on-link 网关、D/V 查询、D 已有 host route 与已知基础设施。D 禁止一组保守特殊网段；不是完整 IANA 注册表，也不是安全/授权证明。VPN Endpoint 与远控目标仍需用户明确核对。

输出仍为固定枚举 share-summary 与私有原始材料。通过仅表示 `MANUAL_EXPERIMENT_CANDIDATE`，不表示发包成功或允许绕过强制机制。没有任何 sudo、路由/DNS 写入、自动恢复或主动网络探测。

`tools/s0/SINGLE-TARGET.md`：独立的人工规程，包括授权/恢复、真实出口证据、修改前最终检查、一次 add、一次经归属核验的 delete、撤销后检查与反馈模板。该文包含明确管理员写操作，但准备脚本不会执行它。不能把 runbook 文件当可执行脚本。

## 3. 本轮实际执行

在 Linux x86_64 上执行：

```sh
/bin/bash -n tools/s0/preflight-target.sh
python3 -m unittest discover -s tests/s0 -p 'test_preflight_target.py' -v
```

结果：语法检查通过；**33/33 个 unittest 通过**（其中若干使用多个子输入）。范围是合成的解析/判定、非法地址、缺失/混合隧道、路径变化、网关、冲突、敏感标识不进入摘要、help 与无写操作检查。

原 27 项与追加 30 项本轮未重跑，不合并宣称 90/90。依赖的 `collect-network.sh` 未修改；本轮未在 Mac 执行完整交互采集/文件输出路径，未测试 sudo/add/delete/curl，也未运行 Xcode/Network Extension/GitHub Actions。工具与规程不存在即可运行产品的含义。

## 4. 剩余门槛

S0-02 有新增用户配对证据，S0-03 仍 **NOT RUN**：需要当前现场目标和许可、实际 D/V 出口、撤销与残留证据。S0-01 场景覆盖及 S0-04 认证替代性也未自动完成。PR 保持 Draft，本记录不改变产品范围、许可或阶段验收。

下一步不要求重交旧快照：保持 VPN 连接，运行 preflight-target.sh，按本地规程完成经授权的实验；缺权限、目标或恢复把相应项记 BLOCKED，而不是猜测目标或改用第三方站点。
