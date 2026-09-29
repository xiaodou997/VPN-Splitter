# EX-INT-03B：系统批准与首次 XPC 诊断

日期：2026-09-30。基线 main `0bbfb36`。关联 EX-INT-03B/03D、T-E06、T-U01。当前候选仍为 `route_trial=DISABLED`。

## 真机证据

用户在已公证的 External Control 中依次报告 `notFound`、注册后的 `requiresApproval`、系统批准后的 `enabled`（USER_REPORTED）。独立 `launchctl print system/io.github.xiaodou997.VPNSplitter.ExternalHelper.v1` 确认系统已注册服务，首次恢复核查后服务进入 running，启动次数 1，没有退出。日志显示双方设置了预期的代码签名要求、Helper 接受了控制 App 的连接。这些事实不等于应用协议往返已完成。

用户点击“核查恢复状态（只读）”后报告 `操作未完成：unavailable`。尚无成功的 hello/recoveryAudit UI 结果；不标记真实双向认证、恢复核查或 Helper 分流通过。没有请求 prepare/apply，没有改变路由或 DNS。

## 诊断变更与验证

客户端把原有通用 unavailable 拆为 serviceNotEnabled、channelMissing、requestInFlight、proxyUnavailable，分别定位服务状态、通道、并发请求与协议代理转换。签名要求、root UID 检查、超时和失败关闭行为不变，不自动重试。

- `external-helper-test`：ExternalControl Debug/Release、14 项 Python/原生合同测试通过。
- 新增诊断场景后 `tests/external_helper/test_client.py` Debug/优化构建通过，覆盖上述四类失败及不发送/不重复发送请求。这里的系统接口为替身，不是实际签名验收。
- 本机忽略目录中的匿名 NSXPC 实验完成 hello→第二次请求；身份与服务注册使用本地替身，不连接特权服务，不能作为 Helper 验收。
- Developer ID 原生构建通过，路由试验禁用。候选 `.local/external/control.c1wj8svq/VPN-Splitter-ExternalControl.app` 为避免同时更换服务端，已复制当前安装版的原 Helper 二进制，并重新签名主 App、严格校验通过。
- 新候选公证 BLOCKED：默认钥匙串和显式 login.keychain-db 均未找到既有公证凭据 profile。未替换已安装 App，未注销服务；待用户本机恢复凭据后继续公证及只读复验。

当前根因未定位。此提交提供诊断能力，不宣称修复首次 unavailable；下一步取得明确错误类别，再针对性修复。旧版本签名/公证成功证据保留。
