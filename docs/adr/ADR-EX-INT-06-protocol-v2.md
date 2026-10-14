# ADR-EX-INT-06：External Helper 控制协议 v2（schema=2 + .v2 服务名）

日期：2026-10-14。状态：Accepted。关联 EX-INT-03B/03D、ADR-EX-INT-05；证据见 docs/evidence/ex-int-03b-helper-native-diagnostic.md。

## 背景

main 线与 backup 线在 2026-09-30 后各自演进：backup 线为 sustained 会话引入按客户端连续递增的 `sequence`（ADR-EX-INT-05），main 线继续无序号协议并新增 XPC 错误分类与只读探针。真机诊断确认首次只读通信 `unavailable`/`authentication` 的根因是两条线的协议代际不匹配：backup 线 Helper 拒绝无序号 hello 为 `invalidRequest`，main 线客户端把 hello 拒绝统一误报为 `authentication`。签名、root 校验与 XPC 传输均正常。

## 决定

1. 协议升级为 schema=2，不是在 schema=1 上叠加可选字段。解码层强制：schema 必须等于当前版本，`sequence` 必须存在且非 0；服务端额外要求同一连接内 sequence 从 1 开始严格连续，溢出拒绝，不回绕。
2. 不匹配不再误报。端点在解码失败路径先用只读 protocolProbe 提取请求 id 与 schema：能提取且 schema 非当前版本时，应答 `refused/protocolMismatch`；客户端 connect() 的 hello 被拒时按 code 映射，`invalidRequest`/`protocolMismatch` → `.protocolMismatch`，其余 → `.authentication`。
3. 特权服务名升级为 `io.github.xiaodou997.VPNSplitter.ExternalHelper.v2`（launchd plist 同步改名），与 v1 同名服务物理隔离，避免同机两代二进制协议漂移。v1 注册的注销需由旧版客户端或独立一次性工具完成，v2 客户端不尝试管理 v1 服务。
4. main 线的 XPC 错误细分（xpcCodeSigningRejected / xpcInterrupted / xpcInvalid / xpcReplyInvalid / xpcTransport）与只读 Helper 通信探针全部保留，叠加在 v2 协议之上。
5. sustained 会话语义（ADR-EX-INT-05）不变：sequence 在 v2 下由解码全局强制，sustained 只决定会话生命周期与通道寿命豁免。

## 后果

- v1 与 v2 客户端/Helper 互不兼容且报错明确（protocolMismatch），不再有 authentication 误报。
- 升级时必须从同一提交同时重建、签名并安装 App 与 Helper；禁止复用旧 Helper 二进制搭配新 App。
- 签名身份、root/console user 校验、路由写入编译开关与恢复边界均不因此变更。
