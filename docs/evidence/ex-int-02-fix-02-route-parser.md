# EX-INT-02-FIX-02：路由表格式兼容与脱敏定位

日期：2026-09-28。基线 `71d447230253c4e145d4a321256367e45b10a50b`。关联 EX-INT-02、EX-01/02/05、DIAG-02/03。沿用 External 优先和[前台执行限制](../external-execution.md)；不改变路由权限、租约或 Helper 范围。

## 用户反馈与证据边界

用户用此前构建通过的 `VPNExternalLease inspect` 检查一个 IPv4 目标，程序返回 `malformedRoutes`。本次没有原始 netstat 表，不能确认是哪行或哪个字段触发，也不能从该错误推出目标不可直连、原 VPN 不兼容或路由已修改。已回读的入口在采集成功之后才检查目标；inspect 不创建写入驱动/事务。

此前原生构建 PASS 仍有效，记录见[用户构建结果](ex-int-02-user-native-build.md)。此次运行失败是后续解析层证据，不作废编译结果。用户地址、完整目录和原始网络数据不入库。

## 已确认的代码缺口与修复

Apple 的公开 [netstat `route.c`](https://github.com/apple-oss-distributions/network_cmds/blob/main/netstat.tproj/route.c) 中，`np_rtentry` 对不再为正的路由到期时间输出字面 `!`，不是数字；本次于 2026-09-28 查阅。旧解析器仅接受数字，因此可用合成表稳定复现同一个 `malformedRoutes`。这是**已证实的解析缺口，不是已证实的本次用户触发原因**；没有复制上游实现。

解析器现在接受 Expire 列的缺省、ASCII 数字或单个 `!`。`!` 行完整保留，新增 `isExpired`，`usable` 为 false；不能把它当可用物理出口/隧道路由/已有可用直连，亦不因过期取得删除权。数字倒计时继续不参与语义快照对照，进入/离开过期状态参与对照。没有跳过未知行，没有扩大目的地址/掩码/网关/flags 白名单，没有新增默认路径或 DNS 回退。

新增 `ExternalRouteParseDiagnostic` 与 `parseDiagnosing`。旧 `parse` 保留原 ExternalError API；两个原生采集位置调用同一诊断解析器并传递错误。CLI 和只读 UI 显示固定错误类别、原始输出行号（空行计数）、字段类别和列数，不保留/打印原始行、地址、网关、接口、主机名或 token 哈希。失败不返回部分表。

示例格式（仅合成示意）：

```text
route_parse_schema=external-route-parse-v1 code=malformedRoutes line=6 field=expiry columns=5
```

CLI 仍返回原错误码文字；失败时的 `network_settings=NOT_APPLIED` 仅加给 inspect，不把这个声明套在可能已经写入的 apply/audit 路径。只读 UI 仍不能应用。采集命令、管理员/TTY/APPLY 检查、写入/删除驱动、恢复标记和签名脚本不变。

## 实际执行

Linux x86_64 / Swift 6.2.1 / Python 3.13.5。Mac Runner 对原项目仍返回 `project_path_not_found`。固定基线部分源码工作区：修改前的 Observation、collector、UI、CLI、旧入口测试及所需 IPv4.swift 均核对完整 Git blob；不是全仓 checkout，不声称全包编译。

| 检查 | 实际结果与范围 |
| --- | --- |
| 新 `test_route_parser.py` | 8 项 unittest 通过；真实 IPv4.swift、Observation/诊断类型在 `-Onone` / `-O`、Swift 6 strict-concurrency=complete、warnings-as-errors 下编译并执行；网络表为合成输入 |
| 原入口测试中的共享采集/parse 合同 | 1 项通过；唯一字符串断言同步为 parseDiagnosing，仍核对真实采集和禁止写入的边界 |
| CLI 错误呈现 | 包含在新 8 项内；提取实际 catch 方法体执行，只有无关 ExternalLeaseFailure enum 是替身；inspect 输出未应用，apply/audit 不伪报未应用 |
| 负向复现 | 原样旧 Observation 对合成 `Expire !` 拒绝为 malformedRoutes；不代表采到了用户现场表 |
| 变异复查 | 撤回 `!` 格式接受或移除过期不可用条件，新增场景均捕获失败 |
| 原生条件源码 | 修改的 Swift macOS frontend parse 通过；不是 Apple SDK 类型检查、链接或实际采集 |

覆盖过期邻居/默认/半默认/网段保留、flags/scope 保留、倒计时不扰动与过期状态变化、旧计数列、CRLF 行号、未知字段/编码/控制符/行数/大小拒绝、原错误 API 和诊断脱敏。优化构建与内部断言不重复累计成新测试数量。未重跑旧 29 项 ExternalCore、35 项 ExternalExecution、C 路由/签名套件或全仓回归。

## 本机复验

```bash
git pull --ff-only && \
python3 -m unittest discover -s tests/external_execution -p test_route_parser.py -v && \
/bin/bash dev.sh external-executor-build
```

使用这次输出的**新 Executable 精确路径**再执行 `inspect <同一个目标IPv4>`；旧 `executor.y8ru6ydc` 是不可变旧副本，不会被 git pull 更新。不需要 sudo、WG 签名、清缓存/锁或删除任何恢复记录。若仍拒绝，只回传新的 `route_parse_schema=...` 行及错误码即可先定位，不要求上传整个路由表。

修复后 Mac 编译、真实 netstat 采集、目标兼容性和 inspect 成功均尚待复验。真实分流、撤销、GUI Helper 与恢复验收不升级；本次不执行 apply，不读取凭据，不改网络，不安装服务。最终仍需 External 真实 DIRECT/VPN 双路径证据，不能用解析通过替代。
