# EX-INT-03B：认证 Helper 与应用内有限会话接线

日期：2026-09-29。基线 `b51b4855b6c9d9e0b931ec52028abfb9d62fd475`。关联 S4-02/03/04、EX-03/05/07/08、SEC-02/03、T-E06/E08/E10、T-U02/U05。设计见 [03B ADR](../adr/ADR-EX-INT-03B-authenticated-helper.md)，入口见 [操作说明](../external-helper.md)。

## 用户反馈与既有边界

用户对上一批 EX-INT-03A 表示“验证通过”，登记为 USER_REPORTED；没有逐项操作、完整日志或新测试数，不能扩展为全量测试、身份授权或路由验收。此前单目标残留由用户人工恢复、audit 未见候选残留的证据保留；FIX-08 新版自动确认/撤销未被本次反馈覆盖。旧 WG 错误日志不是本轮新增失败，不据此重开 WG 工作。

## 本轮实际实现

新增完整 ExternalControl 本地 Swift 包：有界版本化协议、连接/实例/方案/版本绑定、一次性预检票据、服务全局单活动会话、独立时限、原生身份要求及 App 客户端。新增 VPNExternalHelper 可执行 target，实际监听 XPC，并把经确认的规则交给原采集器/ExternalLeasePlan/NativeExternalRouteDriver/ExternalLeaseTransaction。不是启动 CLI 的 shell 包装，没有通用命令/路径/任意删除接口。

已有页面实例化 ExternalHelperModel/Client，已保存方案在 prepare 与 apply 前重新读回完整版本，接入原生注册状态、申请/注销、Helper 预检、明确确认、应用/停止和原生诊断。设置应用失败或失联不会显示为恢复成功。03A 检测模型方法体保持逐字一致，原规则文档格式、LocalDev、WireGuard、凭据权限、C 路由驱动、旧 CLI 与恢复记录代码均不改动。

双方实际调用 SecCode 身份自检、Foundation 的代码签名要求及内核 UID；不信任消息自报身份。团队来自自身签名，精确 App/Helper ID 独立于 ad-hoc 预览。Helper 要求当前控制台用户；签名/系统批准、规则确认和编译时 route-trial 三层分开，普通构建不能写网络。签名安全检查、系统注册和路由效果本轮都未在 Apple SDK/真机运行。

prepare 15 秒、10 秒心跳失效、活动 60 秒不续期；服务计时不依赖 UI 轮询。连接取消对原生事务立即可见，清理结果仍须等待实际驱动。最多 8 条编译路由沿用旧限制。Helper 启动发现旧 active 标记或目录异常即锁定恢复状态；注册/预检不清除标记。正常注销先 quiesce，拒绝与新 prepare 竞争。回调代次、重复回调、取消后迟到回复、请求 ID 重放和跨连接票据均有处理。

新增 external-helper-build 同时构建独立控制 App 和内嵌 Helper，默认 ad-hoc/写入关闭；明确身份签名后仍默认只读。显式 route-trial 仅编译有限写入能力，不自动运行。构建输出签名后哈希，不安装服务、不写路由、不打开 App；原 external-run 继续可用。旧两处 manifest 测试只更新本地包/target 期望，不删除既有安全断言。

## 本轮实际验证

Linux x86_64 / Swift 6.2.1。对用户 Mac 路径的工具调用返回 project_path_not_found，未取得 Mac 执行能力。工作区是固定基线的相关源码子集，不是整个仓库；新 ExternalControl 包则使用其完整实际 Package.swift/Sources/Tests 构建。已有 UI、dev.sh、两个旧测试和整份 roadmap 的原始 Git blob 均核对一致；测试用 API 替身只在测试生成目录，不进入生产 target。

| 检查 | 实际执行结果及边界 |
| --- | --- |
| ExternalControlTests | 同一组 24 项 XCTest 在 Debug/Release 通过；实际协议/会话/身份规则，原生 lease、时钟、控制台身份为明确替身；两种构建不重复加成 48 项 |
| tests/external_helper | 13 项 unittest 全部通过：2 客户端、2 页面模型、6 构建编排、3 安全/manifest/语法合同 |
| 客户端执行 | 实际完整客户端方法在 -Onone/-O 严格并发、warnings-as-errors 下执行；每种运行同一 8 场景。NSXPC/Security/SMAppService 为所有平台都显式使用的替身，不是实际身份认证 |
| 页面模型执行 | 实际页面模型与实际客户端、协议组合；每种优化同一 6 场景。磁盘方案、对话框、UI/系统服务为明确替身，不打开窗口或读取用户方案 |
| 构建执行 | 实际 builder main、临时文件/打包/日志/哈希，编译器/lipo/codesign 为替身。签名/校验失败、root/非法参数不发布成功；不执行产物 |
| 原有针对性回归 | 原 tests/external 的 2 项 UI 失效/旧入口分发检查通过；不是完整旧套件 |
| 新入口 | 实际 dev.sh external-helper-test 完整退出 0；新分发额外在临时脚本替身下检查参数转发/多余参数拒绝；bash -n 通过 |
| Mac 条件源码 | 新 Helper、客户端、页面以及接线文件 frontend parse 通过；不是 Apple SDK 类型检查或链接 |

24 项覆盖普通模式禁止写入、同连接一次性确认、跨连接/旧版本拒绝、独立时限、断连/用户变化、零回执不伪装恢复、恢复锁定、注销竞争等。复查修正了“已有旧恢复标记、没有活动会话时 stop 错返干净结束”的问题，原恢复测试增加断言，最终两种构建重新通过。开发中的中间失败不当作最终证据。

未执行真实签名、SMAppService 注册/批准/注销、原生 XPC、Helper 与路由事务端到端、Mac C/Swift 完整编译、GUI 渲染或网络操作。未重跑旧 41 项拓扑/35 项事务、C 通知及签名/导入全套；不把历史数量累计成全仓通过。未安装软件、读取密钥、修改恢复标记或用户网络。

## 交付与剩余项

main 非强制追加交付；源码/测试/构建入口/ADR/roadmap 一起同步，不发更新包。默认测试及构建可集中进行，不要求用户立刻重复 sudo/apply/audit。旧产物和历史证据保留。

本批已具有正式身份接口和实际运行调用，但不是“安全交付在真机已通过”。待完成新的原生构建、双向身份拒绝/接受、系统服务批准与受控添加/停止/撤销验收；失联后的跨连接状态恢复、GUI 恢复流程和更完整崩溃/升级处理仍未完成。默认写入关闭不是这些工作的替代。OpenVPN 尚无新增实现；WG 签名继续暂缓。
