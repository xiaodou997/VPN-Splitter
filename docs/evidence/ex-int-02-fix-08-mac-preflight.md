# EX-INT-02-FIX-08：Mac 原生受控复验前置检查

日期：2026-09-29。起点 `main` `65dd139`。关联 EX-INT-02、FIX-08、EX-03/05/07/08。仅记录再次写路由前的本机证据，不升级为 Route Bypass 自动撤销通过。

## 已执行

- `/bin/bash dev.sh external-execution-test`：ExternalExecution Swift 与 Python/C 合同、路由通知模拟测试整体通过；输出中 Python 为 26 tests / 0 failures，修复前 AF_INET 订阅的“已添加但 ADD 回包超时”负向复现成立。模拟内核不等于真机 PF_ROUTE。
- `/bin/bash dev.sh external-executor-build`：macOS arm64 `compile=PASS`、`execution=NOT_RUN`、`network_settings=NOT_APPLIED`。新产物为 `.local/external/executor.os7jlx3e/VPNExternalLease`，SHA-256 `a47d6326d647b79a804048e6b1c079f38fcf992c9ab2ce55b7a533aa549f3785`；独立复算一致，`codesign --verify --strict` 通过。
- 回读当前 C 路由适配层，PF_ROUTE socket 使用协议 0 订阅，保留 loopback；这只是源码检查，不代替 ADD/DELETE 实测。
- 用户在本机终端对新产物运行管理员只读 `audit`，报告 `audit_candidates=1 present_or_ambiguous=0 route_writes=NONE`，记为 **USER_REPORTED**。用户确认在 Mac 前且 StrongVPN 不是唯一远程控制通道，拟沿用上次已人工恢复的单目标。目标地址没有进入仓库或聊天。
- 用户随后报告新产物的 `clear-absent-marker` 已成功清理旧标记，并将上次目标只存入 `.local/external/fix08-target.txt`；此项清理结果为 **USER_REPORTED**。本地检查目标文件为当前用户所有、非符号链接、权限不向组或其他用户开放，且仅含一个合法 IPv4 地址。
- 对本机目标先独立只读查询，接口为 `utun8`。新产物 `inspect` 返回单条 `wouldAdd`、`network_settings=NOT_APPLIED`；`probe` 返回 `native_route_probe=PASS`，诊断 `stage=gatewayGET reason=none reply_type=4 mutation_attempts=0`。完整原始输出只保留在被 Git 忽略的 `.local/external/fix08-inspect.log` 与 `fix08-probe.log`，不上传目标、网关、接口等原始网络资料。

## 下一关

旧标记已由用户报告清理，目标只读 `inspect`、`probe` 已在本机通过。下一步才是经现场授权的 60 秒单 `/32` `apply`、ADD ACK/readback、正常停止 DELETE ACK、独立前后路由和真实双路径流量。任何残留或歧义均停止，不从旧 marker 恢复删除权，不 flush 路由。

当前真实 ADD/DELETE、自动撤销、流量出口、Helper GUI/身份授权仍 **NOT RUN**。本轮迄今没有修改路由、DNS 或第三方 VPN 配置。
