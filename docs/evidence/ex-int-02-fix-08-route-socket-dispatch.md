# EX-INT-02-FIX-08：ADD 回包协议过滤导致已写入但未确认

日期：2026-09-28。基线 `6688f6e6849248cfe2ff7c2d3d1a6624a4a6f7fa`。关联 EX-INT-02、EX-03/05/07/08、DIAG-02/03。External 优先，其他后端和权限不变。

## 本次现场证据：确有目标路由残留

用户用此前 probe 通过的精确产物做单目标 apply。诊断为 `stage=add reason=timeout decode_field=0 system_errno=0 reply_errno=0 reply_type=0 mutation_attempts=1`，随后 `state=recoveryRequired owned_receipts_remaining=0 snapshot_comparison=changed`、`failure=routeUncertain`。

用户独立查询在应用前走原 VPN 的半默认路由，应用后及程序退出后均出现目标本身的物理网关主机路由，flags 包含 UP/GATEWAY/HOST/DONE/STATIC/PROTO2。记录为 USER_REPORTED：观察到目标路由添加和选路改变，未得到添加回执、未自动撤销，实际流量未验证。零回执不是零残留；这次不能引用此前另一轮的无残留 audit 作为当前证据。用户完整路径、地址和接口不入库。

优先恢复现场，不再次 apply，不根据 readback 为旧进程重建删除权。操作者重新检查仍是本次确切目标、物理网关、接口及主机/静态/PROTO2 记录，确认期间无其他路由修改后，可用系统 route 的单 host delete 人工撤销该实验路由。若记录变化、已回到 VPN、存在作用域歧义或竞争，不猜删。PROTO2 不是所有权标识，带 gateway 的 delete 也不是原子 compare-and-delete。

人工删除后独立查询目标并用旧精确产物 audit；结果仍需回传。不要 flush、删除锁或直接 rm active。恢复标记保留至程序重新审核全部候选及更具体路由缺席后，再由既有 clear-absent-marker 处理。代码更新不会自动清除本次旧路由或标记；人工撤销不得记作自动回滚通过。本轮没有收到恢复后的反馈。

## 一手源码依据与已复现的缺陷

2026-09-28 查阅下列 Apple 公开源码，未复制第三方实现或引入依赖：

- [XNU rtsock.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c)：route_output 的 dst_sa_family 初始为 0；普通完整长度 IPv4 地址不走短地址复制分支，RTM_ADD 也不走 GET/DELETE 的 report 分支，因此部分 ADD 回送消息按协议 0 分发；GET/DELETE 的 report 会设置地址族。
- [XNU raw_usrreq.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/raw_usrreq.c)：raw_input 对非零 socket 协议进行匹配；AF_INET 订阅不接收协议 0 消息，协议 0 是通配订阅。
- [Apple route.c](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.c)：系统工具使用 socket(PF_ROUTE, SOCK_RAW, 0)。

当前执行器使用 AF_INET 订阅。新增独立协议分发模拟，在原样基线 C 上复现：两个 GET 通过，ADD 实际改变合成路由表，但协议 0 回包被订阅过滤，最后 add/timeout、一次修改尝试、零回执、合成路由残留。此机制与现场一致；没有抓取用户的内核消息或独立核验其运行内核源码，不能宣称排除了全部其他丢包原因。

## 修复范围

原生上下文改为协议 0 订阅，保持 XNU 默认启用的 SO_USELOOPBACK，不延长超时、不重试 ADD、不以 write 成功或 readback 代替匹配回执。请求仍只有原有 IPv4 GET/ADD/DELETE，query-only 的 API 与底层发送禁止写入不变。

通配订阅也接收 IPv6 通知。增加单独分类：只有头、地址位图、所有 sockaddr 长度/对齐、IPv6 目的地址和其他已知类型地址槽边界均可确认的 IPv6 变更通知，才视为不涉及 IPv4 键。它不生成 IPv6 路由、授权或回执。未知类型/地址族、截断、错误帧仍停止；IPv4 同键变更继续撤销回执。与本次 pid/seq 匹配的响应先进入原严格 IPv4 解码，不能伪装成“无关 IPv6”被略过。

没有修改 Swift 事务、采集器、规划器、恢复日志/标记、GUI、构建脚本、签名、默认路由、DNS、协议设置或用户数据。旧租约不复活，旧回执不认领。真实 ADD/DELETE 丢包仍保留 recoveryRequired 的既有边界。

## 实际验证

Linux x86_64 / Clang 17.0.0。隔离的部分源码工作区，完整原 C、头、Darwin 夹具、旧 C harness、Python runner 的 Git blob 均与固定基线逐一一致。不是完整 checkout 或 Apple SDK 环境。

- 原 `test_native_route.py`：1 项 unittest，原有 40 组 C 场景全部通过；测试 socket/分发模型同步，不删原场景。
- 新 `test_native_notifications.py`：3 项 unittest 通过，包括同一组 12 个通知/生命周期场景的 -O0/-O2 执行，以及恢复旧 AF_INET 订阅后的负向复现。12 组、两种优化和内部循环不重复加成测试数量。
- 完整原 C 的独立负向运行同样复现 ADD 已改表但超时。收到合法回包的新代码在合成环境中完成 ADD 回执、GET 复核、DELETE；已写入后真正丢回包仍返回不确定且不盲删。
- 覆盖普通/root query-only 禁止写入、混合 IPv6 通知、伪装成本请求回包的 IPv6、IPv4 同键替换/删除前竞争、错误帧/截断/未知类型、缺失回包。临时变异略过 IPv4 CHANGE 或只凭 family 跳过畸形 IPv6，均被断言捕获。
- 两套完整 C harness 在 AddressSanitizer/UndefinedBehaviorSanitizer 下通过；真实非 Apple 条件分支以 -Wall/-Wextra/-Werror 编译通过；Python 3.9 语法检查通过。

上述网络/内核/ABI/系统调用均为明确替身，不是实际 PF_ROUTE 运行。未运行 Swift 桥接/核心/事务/签名/其他 Python 全套，未执行 Mac 原生构建、probe、apply、人工恢复或 audit。新代码的 Mac 回包与正常撤销仍待验证；未恢复现场前不建议再次写入。

## 本机后续

先完成本次单目标残留的人工审核恢复并回传 route get / audit；不要继续用旧执行器 apply。随后普通用户可更新和运行纯测试/构建：

```bash
git pull --ff-only && \
python3 -m unittest discover -s tests/external_execution -p test_native_notifications.py -v && \
python3 -m unittest discover -s tests/external_execution -p test_native_route.py -v && \
/bin/bash dev.sh external-executor-build
```

这条链只测试/构建，不运行产物或删除恢复记录。新运行必须使用新的 Executable 精确路径；旧复制副本不会被 git pull 更新。恢复状态确认、标记经现有审核流程处理之后，才另行安排新产物的受控 ADD/DELETE 联调；本报告不授权自动或循环重试。

通过 main 非强制追加交付。保留所有旧构建/预检通过和本次真实应用失败证据，不发更新包、不清空缓存、锁或历史记录。
