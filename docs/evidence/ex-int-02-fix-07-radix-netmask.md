# EX-INT-02-FIX-07：原生路由回包中的 radix 掩码解码

日期：2026-09-28。基线 `8a8ecbfacaf658d626be92af69f6ebb31636a446`。关联 EX-INT-02、EX-03/05/07/08、DIAG-02/03。External 优先；沿用[前台执行限制](../external-execution.md)。

## 本次用户证据与定位

用户以新构建产物运行只读 probe，返回：

```text
route_io_schema=external-route-io-v1 stage=targetGET reason=decode decode_field=7 system_errno=0 reply_errno=0 reply_type=4 mutation_attempts=0
native_route_probe=FAILED; network_settings=NOT_APPLIED
```

这是目标 RTM_GET 回包被本工具解码器拒绝，不是物理出口识别、系统返回非零 errno 或 ADD 阶段失败。按基线代码，field 7 唯一对应 RTAX_NETMASK 的 family 不是 0/AF_INET。此处已有明确拒绝条件，无需重复 apply 或上传原始回包来定位这个条件；具体 family 字节未输出，不能声称现场已抓到 0xff。

mutation_attempts=0 是这次 query-only 上下文未尝试 ADD/DELETE，不反推此前旧版本 apply 的全过程。前一轮用户独立查询仍走 VPN，audit_candidates=1、present_or_ambiguous=0；保留为审计时未观察到候选残留的 USER_REPORTED 证据，不升级为真实添加/撤销通过。旧恢复标记仍保留，本修复不删除它。用户目标、网关、接口及完整路径不入库。

## 一手依据与实际修正

本轮查阅 Apple 公开源码（2026-09-28；未复制实现、未新增依赖）：

- [XNU radix.c 的 rn_addmask](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/radix.c)：规范化 mask 时把被跳过的前缀字节填为全 1，并裁去尾部零字节；family 位置可能是 0xff，并非普通 sockaddr 地址族。
- [XNU rtsock.c 的 RTM_GET report](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/rtsock.c)：将 rt_mask 放进 RTAX_NETMASK 回包。
- [Apple route.c 的 print_getmsg](https://github.com/apple-oss-distributions/network_cmds/blob/main/route.tproj/route.c)：显示前以 destination 的 family 解释 mask，不以 mask 自身的 family 值判定地址类型。

decode 现在将 RTAX_NETMASK 与目的/网关地址分开处理。掩码仍限定为 IPv4 sockaddr 布局上限，按 sa_len 有界复制并零扩展，掩码位的含义由已经独立验证的 IPv4 目的地址确定；不读取对齐填充或后续 IFP 数据。只修正对这个掩码槽位的错误 family 限制，不把 0xff 添加到目的、网关或接口的地址族白名单。

消息头、长度、对齐边界、目的/网关 family、接口索引、连续掩码、规范网段、host /32 约束及 pid/seq/type/键匹配保持检查。短 /0 掩码不会变成 /32；有 host 标志且无掩码仍按既有规则解释。诊断编号不重排，旧 field 7 留作保留编号；历史 FIX-06 的 field 7 说明对应旧版本。

未改发送请求、查询/写入权限、前置路径约束、回执与停止逻辑、事务日志、恢复标记、GUI、Swift、签名、依赖或 WG/OpenVPN。probe 仍只读，不产生可用于以后写入的授权。

## 实际执行的验证

Linux x86_64 / Clang 17.0.0 / Python 3.13.5。部分源码验证工作区，完整 C 源、头文件、旧 C harness、Darwin 声明替身和 Python runner 的五个基线 Git blob 均逐一核对一致。不是全仓 checkout 或 Apple SDK 环境。

- 现有 `test_native_route.py` 的 1 项 unittest 通过：内部保留旧 31 组，新增 9 组，共 40 组 C 场景；参数循环不另累计。
- 新回包编码器独立构造 compact/full 掩码，不调用生产 request/append/prefix_mask 生成新格式。覆盖全部 /0–/32、两条 /1、opaque family、非零对齐填充、缺省 host 掩码、目的/网关/IFP 非法 family、超长/截断、非连续/非规范地址、query-only 前置查询、模拟 ADD/GET/DELETE、同键替换撤销回执及失败前零写入。
- 同一完整 harness 在 Clang -O2 及 AddressSanitizer + UndefinedBehaviorSanitizer 下均通过。真实非 Apple 条件分支在 -Wall -Wextra -Werror 下编译通过；测试 runner 的 Python 3.9 语法检查通过。
- 原样基线 C + 合成 compact/0xff 回包复现与用户相同的 targetGET/decode/field 7、errno=0、reply_type=4、mutation_attempts=0。用新测试运行旧代码会失败；放宽目的地址族或移除掩码连续性检查的临时变异也被新测试拒绝。变异只在临时副本中，最终产品保留正确检查。

所有网络、内核/ABI 和系统调用均为明确替身，未在本机开路由 socket 或修改网络。未重跑 Swift 桥接/核心/事务、其他 Python 全套，未执行 Mac 原生构建、现场 probe/apply/audit 或真实流量验证。新增代码在 Mac 的查询通过仍待用户复验，不把合成测试升级为真实分流成功。

## 本机下一步

```bash
git pull --ff-only && \
python3 -m unittest discover -s tests/external_execution -p test_native_route.py -v && \
/bin/bash dev.sh external-executor-build
```

使用本次构建输出的新 Executable 精确路径，对同一目标再执行 probe；明确重新赋值，不沿用旧 PROBE_EXEC/EXEC。无须 sudo、恢复 WG 签名、清缓存或锁；不再 apply，不执行 clear-absent-marker。新 probe 不读取旧标记，标记不会阻碍这一步。只需回传 route_io_schema 与 probe 结果，无须重做刚通过的路由/audit 检查。

本批仅修改 C 解码器与 C 测试夹具、新增本证据；通过 main 非强制追加交付。保留此前编译/inspect 通过和 apply 失败事实。修复源代码不等于恢复已验收，也不改变崩溃/路由竞争的既有限制。
