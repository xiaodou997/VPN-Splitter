# EX-INT-03B：系统批准与首次 XPC 诊断

日期：2026-09-30。基线 main `0bbfb36`。关联 EX-INT-03B/03D、T-E06、T-U01。当前候选仍为 `route_trial=DISABLED`。

## 真机证据

用户在已公证的 External Control 中依次报告 `notFound`、注册后的 `requiresApproval`、系统批准后的 `enabled`（USER_REPORTED）。独立 `launchctl print system/io.github.xiaodou997.VPNSplitter.ExternalHelper.v1` 确认系统已注册服务，首次恢复核查后服务进入 running，启动次数 1，没有退出。日志显示双方设置了预期的代码签名要求、Helper 接受了控制 App 的连接。这些事实不等于应用协议往返已完成。

用户点击“核查恢复状态（只读）”后报告 `操作未完成：unavailable`。尚无成功的 hello/recoveryAudit UI 结果；不标记真实双向认证、恢复核查或 Helper 分流通过。没有请求 prepare/apply，没有改变路由或 DNS。

## 诊断变更与验证

客户端把原有通用 unavailable 拆为 serviceNotEnabled、channelMissing、requestInFlight、proxyUnavailable，分别定位服务状态、通道、并发请求与协议代理转换。签名要求、root UID 检查、超时和失败关闭行为不变，不自动重试。

- `external-helper-test`：ExternalControl Debug/Release、14 项 Python/原生合同测试通过。
- 新增诊断场景后 `tests/external_helper/test_client.py` Debug/优化构建通过，覆盖上述四类失败及不发送/不重复发送请求。这里的系统接口为替身，不是实际签名验收。
- 2026-10-01 继续收窄真实 XPC 失败面：客户端不再把 Foundation 的代理错误统一折叠为 disconnected，而是区分 code-signing requirement 拒绝、interrupted、invalid、reply invalid 与其他 transport；中断/失效 handler 也保留各自类别。没有自动重试、没有放宽签名要求、没有新增任何路由/DNS 写入。对应原生客户端替身回归新增五类错误场景；Mac 真机只读复验仍待执行。
- 同日新增独立“测试 Helper 通信（只读）”入口：只执行已签名客户端 connect/hello/root 对端校验与 status 往返，随后立即关闭通道；不读取恢复 marker、不 prepare/apply、不创建路由事务。这样可把 XPC/身份问题与 Recovery 逻辑分开验收。UI 模型替身回归新增 probe 场景；真实系统结果仍待本机复验。
- 本机忽略目录中的匿名 NSXPC 实验完成 hello→第二次请求；身份与服务注册使用本地替身，不连接特权服务，不能作为 Helper 验收。
- Developer ID 原生构建通过，路由试验禁用。候选 `.local/external/control.c1wj8svq/VPN-Splitter-ExternalControl.app` 为避免同时更换服务端，已复制当前安装版的原 Helper 二进制，并重新签名主 App、严格校验通过。
- 新候选公证最初因既有 profile 无法读取而阻断；用户在本机重新保存凭据后，提交 `e68185c3-0fbb-4893-96a1-87983c0366a2` 返回 Accepted，staple/validate 通过。归档 SHA-256：`978f531283bb2b8b97a92f0a70c7fd0d497b4be3637fdafbec646f19b5b6821b`。
- 普通权限覆盖安装被系统拒绝，随后交由用户在终端管理员更新。独立检查确认 `/Applications` 下控制 App、Helper、签名资源与候选完全一致，strict codesign 和公证票据验证通过；Helper 二进制仍与更新前相同。新控制 App 已启动，待用户反馈只读复验。

当前根因未定位。此提交提供诊断能力，不宣称修复首次 unavailable；下一步取得明确错误类别，再针对性修复。旧版本签名/公证成功证据保留。
