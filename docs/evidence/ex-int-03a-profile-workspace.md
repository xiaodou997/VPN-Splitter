# EX-INT-03A：External 规则方案管理

日期：2026-09-28。基线 `a979165cc192ed9676235cee031e16c0b0fe3555`。关联 EX-INT-03、S4-04、T-U02/U03/U05，参见 [存储/编辑决策](../adr/ADR-EX-INT-03A-profile-workspace.md)。本批是代码与离线证据，不关闭 Helper、Mac 页面或真实分流验收。

## 新增的实际使用路径

`external-run` 的原应用现在实例化实际 `ExternalProfilesModel` 与 `ExternalProfileStore`，页面按钮调用真实保存/载入，不是只有一份未被引用的模型。

- 启动自动载入本机方案与上次选择；不触发网络采集。新建、命名/重命名、复制、选择、保存和删除，上限 16 套。
- 每套至多 64 条 IPv4 地址/CIDR，可批量加入、逐条编辑、启用/停用、上下移动和移除。规则 ID 与次序保留，批量验证失败不部分加入，CIDR 规范结果在保存/加入后显示。
- 已保存启用项才进入原 ExternalModel → 既有网络采集与 PolicyCore 预览。规则、选择、保存/载入、错误及未加入列表的输入变化会清除旧预览；不自动应用。
- 未保存编辑的切换/重新载入/新建和正常退出有保护。复制未保存编辑需单独确认并保留在新副本；不会声称放弃后又默默带走。删除失败保留当前编辑，成功不自动选另一套。
- 多窗口/进程的旧版本保存拒绝；损坏文件不自动重置；不确定保存要求重新载入。文件只含规则文档，不读取凭据或修改恢复标记。

只变更现有 External UI 与新增文档层，未修改原 ExternalModel 检测/取消方法体、核心路由解析/计划、ExternalExecution C/Swift、原 CLI、WG 或 LocalDev。

## 构建入口核对

发现原预览 builder 仍对可能已带签名的副本调用不带 force 的 codesign。与已修复的执行器入口保持一致，仅对本次新 bundle 副本显式重签，随后仍严格校验；两步日志追加到 build.log，失败不输出 PASS 或 open。新增普通用户构建检查，不获取管理员权限。此处是源码核对和工具替身回归，不能据此声称曾在用户 Mac 上复现预览 bundle 的重复签名错误。

## 本轮执行结果

环境为 Linux / Swift 6.2.1；工具对原 Mac 项目路径返回 project_path_not_found。本轮只恢复了验证需要的源码，不能算完整仓库 checkout 或 Apple SDK 编译。完整原 IPv4.swift、ExternalPreviewApp.swift、roadmap.md、预览 builder 的 Git blob 已与远端基线逐一核对；原检测模型方法体保持逐字一致。测试用隔离 Package.swift 不上传或替代仓库 manifest。

| 检查 | 本轮实际结果 |
| --- | --- |
| ExternalProfileTests | 10 项 XCTest：实际地址类型、文档校验、顺序/启用、批量原子性、编辑保护、版本失效与字段边界 |
| ExternalProfileStoreTests | 10 项 XCTest：实际临时文件保存/读回、两个仓库实例版本冲突、损坏/新版本拒绝、符号/硬链接、FIFO、大小/权限、锁竞争与不删除锁、选择/删除持久化 |
| Debug / Release | 同一组 20 项均通过，Swift 6、strict-concurrency=complete、warnings-as-errors；不是 40 项不同测试 |
| test_profiles_app.py | 3 项 unittest 通过：实际完整新文档/store 与原样提取的页面模型，在 -Onone/-O 编译执行；各自包含同一 5 组保存/重开、丢弃/待加入输入、旧保存、删除/选择和非法规则场景，内部场景不重复累计 |
| test_profiles_build.py | 3 项 unittest 通过：真实 builder 编排/复制/日志，Swift/codesign/open 为明确替身；成功严格签名后才允许可选 open，失败不发布/打开，root 构建在工具调用前拒绝 |
| Mac 条件源码 | 三个页面文件 frontend parse 通过；这不是 Apple SDK 类型检查、SwiftUI 渲染或真实弹窗验收 |

页面模型测试的模态对话框在所有 OS 都是明确替身，不会弹出真实确认；Linux 的 Published/ObservableObject 也是替身，Mac 分支使用原生 SwiftUI 的这两个类型。测试 IO 均为新建临时目录，不碰真实用户方案、网络或 root 日志。异步 XCTest 夹具没有实例字段，显式声明测试对象 Sendable 仅用于 SwiftPM 的跨线程测试发现；产品未添加 unchecked Sendable 或降低并发检查。

尚未执行新 Mac 完整包/开窗、退出菜单实际行为、macOS 文件系统异常、真实 codesign；没有重跑原 41 项拓扑、35 项事务、旧 UI/C/签名或整个仓库套件。新 syscall 的替换后失败/崩溃边界存在明确 saveUncertain 实现及编辑状态测试，但未作真实断电或所有 fsync 故障注入验收。

## 继续开发与使用

已有人工恢复的用户输出为目标回原 VPN、audit 候选未见残留；它不是 FIX-08 自动撤销通过。此事实登记在 roadmap，用户网络地址不入库。旧恢复标记保留，本批没有重新 apply/probe/audit 或清理标记。

体验新页面仍为：

```bash
git pull --ff-only && /bin/bash dev.sh external-run
```

不需要 Go、WG 签名、管理员权限或另一份执行器路径。新增离线测试自动由原 external-test 的 SwiftPM 和 tests/external discover 纳入；也可分别运行 ExternalProfileTests/ExternalProfileStoreTests 与 `python3 -m unittest discover -s tests/external -p 'test_profiles*.py' -v`。构建/页面验收可集中进行，不把本机立刻复验当作下一步开发的条件。

## 仍未完成

本批没有实现受限 Helper 注册、双向身份验证、GUI 真实 apply/stop、运行会话回执与恢复状态，不能标记 EX-INT-03 整批完成。没有新增 OpenVPN 导入/连接。下一项仍需把已保存方案经重新审核交给受限 Helper，并接上真实会话；不得用更多预览页替代该执行链。

通过非强制 main 追加提交交付，不发补丁包、不删除用户数据、缓存、锁或历史证据。回滚代码用后续 revert；回滚不删除新规则文档。
