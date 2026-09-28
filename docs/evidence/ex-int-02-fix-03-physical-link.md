# EX-INT-02-FIX-03：物理 LAN 克隆父路由的到期标记误判

日期：2026-09-28。基线 `0bcfaf744527af70b29812b7840b5c0b17ea5656`。关联 EX-01/02/06、EX-INT-02；External 主线及前台执行限制不变。

## 定位与证据边界

用户这次 inspect 返回 physicalUnknown，并明确输出 network_settings=NOT_APPLIED。按已回读的调用顺序，本次已经越过路由解析，在物理路径资格检查失败；不是目标访问测试，不说明目标本身不能直连。

重新查阅用户此前提供的 vpn-before.txt，物理接口的直连 LAN 父路由带有 UCS 和 Expire !，而同一历史记录的默认路由/网络信息仍指向该物理接口。这是已有历史样本，不是本轮重新采集，不把其中网关、接口或地址硬编码进产品，也不上传原始网络文件。当前这两行错误不能单独证明现场只有这一个原因。

已确认上一批 FIX-02 引入了一处判断过严：解析接受 !，但 physical topology 复用了要求 !isExpired 的通用 usable 属性，因而把上述 LAN 父路由排除。针对同类合成表，把真实旧 topology 调用点恢复后可重现 physicalUnknown。

此前 [FIX-02 报告](ex-int-02-fix-02-route-parser.md) 把 ! 一概解释为不能提供链路证据，需要在这里纠正；历史提交/测试结果保留，不静默重写。

## 为什么不能把 ! 一概等同于路由失效

查阅于 2026-09-28 的一手来源：

- [Apple netstat route.c](https://github.com/apple-oss-distributions/network_cmds/blob/main/netstat.tproj/route.c)：np_rtentry 根据非零 rmx_expire 与当前时间之差显示 !，显示过程本身不判定链路可达。
- [Apple XNU in_arp.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/in_arp.c)：arp_rtrequest 的 RTM_ADD/RTF_CLONING 分支为 AF_LINK 接口父路由设置 link index，并调用 rt_setexpire(rt, MAX(timenow, 1))。本轮 GitHub 回读文件 blob 为 86354c82557184adb2175c5547e7734e6a09369b。

因此到期字段的文本标记不是跨所有路由类型的有效性判据。这个结论来自源码；没有证明用户当前运行的内核与公开源码逐字一致，也没有把 route flags 当成目标流量验证。未复制第三方实现。

## 实际修复

新增内部 isConnectedLANEvidence，只在物理 LAN 资格检查中使用。现有不带 ! 的判断保持原样。带 ! 的例外严格限于：UP + 大写 CLONING、正整数 link#、/1–/30 非主机网段，以及 UCSIdig 这一有限标志集合；不接纳 IP 网关、主机/ARP 邻居、拒绝/黑洞、克隆子项、动态/未知标志或 default。

该属性不能独立提供物理出口：原 topology 仍要求当前物理服务、已启用非隧道接口、精确一致的本机 LAN 网段、本机地址，以及同网段且不是网络/广播/本机/保留地址的路由器。缺少服务、错误接口、错误前缀、多候选或过期快照仍拒绝；不读旧网关、不回退当前 default。

通用 usable 不变，isExpired 继续记录原 !，数字倒计时及快照比较规则不变。不会将带 ! 的 VPN 默认/半默认路由或已有直连目标判为普遍可用，不获得任何覆盖/删除权。注释明确旧属性名记录的是文本标记，不是普遍的路由无效结论。

只改两处纯 Swift 核心源码，增加 XCTest 和本报告。未修改采集 API、解析白名单、CLI、GUI、C 路由驱动、事务/租约/恢复标记、构建/签名脚本、权限、WG 或 OpenVPN。canApply 仍为 false。

## 本轮实际验证

环境：Linux x86_64，Swift 6.2.1。隔离验证清单仅用于本地测试，没有覆盖仓库的 Package.swift。恢复并逐一核对 Git blob 的完整原始输入为 PolicyCore 的 IPv4.swift / Policy.swift / Compiler.swift，ExternalCore 的 Observation / Preview / ParseDiagnostic，以及原 29 项 ExternalTests。未恢复整个工程、Constraints.swift 或原平台专用 target，不声称全仓或产品包构建。

- 新 PhysicalLinkEvidenceTests：12 项 XCTest；原 ExternalTests：29 项。合计同一组 41 项在 Debug 和 Release、Swift 6、strict-concurrency=complete、warnings-as-errors 下均通过，不把两种配置加成 82 项。
- 使用实际地址解析器、规则编译器、路由表解析器及 topology/preview。输入为合成网络，不使用真实系统采集或内核替身；没有真实网络 IO。
- 恢复旧 Preview.swift 的原样调用点，新增正常父路由测试按预期失败为 physicalUnknown；删去新增标志白名单，危险标志回归按预期失败。还原后再次执行全部 41 项，两个配置均通过。
- 覆盖 UC/UCS/UCSI 父路由、仍保留 ! 及通用拒绝、错误接口/前缀、default/ARP/host 拒绝、缺少服务、离线接口、网关约束、多物理候选、过期 VPN 默认路由、scope/已有直连归属、保护范围/快照时效及两种全局 VPN 路由模式。

测试开发中曾用子串替换同时改动两条半默认路由，随后修为完整行替换；未为此改产品规则。最终测试结果如上。没有重跑 ExternalExecution 的 35 项、旧 Python/C/签名套件或执行 Mac 构建/inspect/apply。本批不升级真实分流、Helper 或恢复验收。

## 本机复验

```bash
git pull --ff-only && \
swift test --package-path Packages/ExternalCore --filter PhysicalLinkEvidenceTests -Xswiftc -warnings-as-errors && \
/bin/bash dev.sh external-executor-build
```

用本次输出的**新 Executable 精确路径**再次 inspect 同一个目标；旧复制产物不会被 git pull 更新。本轮不要 apply，不需要 sudo/WG 签名，不删除缓存、锁或恢复标记。不需要再上传历史网络文件，也不要求重复添加/删除路由实验。修复后的 Mac 构建及当前物理出口识别仍须这次反馈，不能以历史网络样本代替。

main 普通追加提交交付；代码回滚用后续 revert。保留旧构建 PASS、用户历史样本和本机所有数据；本轮不执行网络修改、提权、服务安装或真实配置读取。
