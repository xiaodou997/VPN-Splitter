# EX-INT-03B：错误身份客户端预检

日期：2026-09-30。关联 SEC-02/03、T-E06。只读测试工具 `tools/external/helper-identity-probe.swift` 使用实际 ExternalControl 身份常量及 wire 编码，只发送一次 hello，没有规则、prepare/apply 或系统服务注册操作。即使意外接纳也不发送后续请求，打印 UNEXPECTED_ACCEPTANCE 并非零退出。

本机 Swift 6 warnings-as-errors 编译通过。构建两个独立本机产物：正确控制 App ID 的 ad-hoc 签名、正确 Developer ID Team 但错误签名 ID。两者 strict 签名完整性通过，静态 App 身份要求校验均拒绝。私钥未导出。

初版工具在 NSXPC 错误回调触发 Swift executor 断言；为跨队列回调显式标记 Sendable 后重建。当前 Helper 未注册，两产物均执行到 connection_invalidated 正常结束，只证明工具能处理服务缺失，**不能作为原生身份拒绝 PASS**。工具输出明确要求系统日志与有效客户端对照，超时也只记 inconclusive。

下一步在用户重新注册/批准现有禁用路由写入的 Helper 后：先由真实 App 验证 hello/recoveryAudit 成功，运行两个 hello-only 反例并检查系统签名拒绝日志，再以真实 App 核查正常回包。不降低服务端签名、console UID 或客户端 root UID 检查。此阶段不需要开启 VPN，不改路由/DNS。用户要求暂不进行 GitHub 同步，本地提交保留。

## 真机错误身份拒绝

用户重新注册并以现有只读控制 App 核查返回 noRecovery（USER_REPORTED，有效客户端前置对照）。2026-09-30 10:04 Asia/Shanghai 依次执行上述两个反例，均为 connection_interrupted；每次对应的 Helper 系统日志明确输出 `Dropping check-in message due to code signing requirement`。签名元数据复核：ad-hoc 为正确 App ID、无 Team；wrong-id 为 Apple Developer ID、正确 Team、独立 IdentityNegative ID。两次只发送 hello，不发送规则或执行动作。

该样本的 ad-hoc 与同 Team 错 ID 拒绝有原生系统证据，不依赖通用断连推断。Helper 仍 running、runs=1、从未退出；测试后有效客户端复验已请求用户执行，结果待回报。没有测试其他团队证书、控制台用户切换或危险 entitlement 反例，不能扩大为所有认证情形通过。

## 后置对照发现空闲会话问题

用户随后通过原 App 再次核查，返回 `Helper 拒绝：authentication`，因此后置有效客户端对照尚未通过，不能把整组验收判为完成。源码确认服务 tick 在空闲 30 秒后移除客户端，而 UI 成功 audit 后仍保留 NSXPC 通道及 instance，后续请求可能复用失效会话。请求用户退出重开，建立新连接后复验，以区分该情形与身份认证错误。

修复仅在接收 `.idle` 成功结果后关闭已完成的只读通道；下一次用户动作重新 hello，不放宽 30 秒超时、签名、UID 或重放限制。增加连续两次 audit 必须建立两次连接/四次请求的模型回归，完整 external-helper-test 通过。之前构建的 route-trial 候选仅编译，未安装/运行；先完成只读问题闭环。此修复不代表所有会话状态的长时间等待已验收。

## 新连接后置对照与修复候选

用户退出重开后再次报告 noRecovery（USER_REPORTED PASS）。结合两个明确签名拒绝日志及测试前有效客户端对照，本次 ad-hoc / 同 Team 错 ID 的负向测试与有效新连接对照通过。旧连接 authentication 与空闲过期机制一致；补充真实服务状态机回归重现 31 秒后旧 peer 被拒绝、新 peer hello/audit 成功，无 prepare/start。

完整 helper-test 再次通过（含新增服务/模型回归）。默认禁用路由写入的签名候选 `control.28uw4x1h` 编译通过，保留当前 Helper 原二进制；公证 `97211073-699d-42dd-9413-fbd4852e702f` Accepted，staple/validate 和 strict codesign 通过。尚未安装，待更新控制 App 后验证跨 30 秒重复核查。旧 route-trial 候选不用于本轮安装。

## 跨空闲期限 GUI 复验

用户安装 `control.28uw4x1h` 后，独立核对安装版 App/Helper/签名资源与候选一致，strict codesign 和 stapler validate 通过。用户在同一次运行中两次点击只读核查、按要求间隔超过 30 秒，报告两次均为 noRecovery（USER_REPORTED PASS）。因此本样本的重复空闲核查修复通过；不扩大为活动路由、恢复标记清除或其他状态长期等待验收。
