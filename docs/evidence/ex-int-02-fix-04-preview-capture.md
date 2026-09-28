# EX-INT-02-FIX-04：External 预览任务捕获声明修复

日期：2026-09-28。基线 `5bb71cb5f0af50d02bd6cfae4db447a3702dd17a`。关联 EX-INT-02、EX-INT-01 预览编译及 REL-02；External 优先顺序不变。

## 用户反馈与定位

用户运行 `swift test --package-path Packages/ExternalCore --filter PhysicalLinkEvidenceTests -Xswiftc -warnings-as-errors`，构建同包的 ExternalPreview 可执行 target 时失败。日志明确指向 ExternalPreviewApp.swift 的外层检测 Task 隐式强捕获 self、内层 expiry Task 弱捕获 self，诊断为 ImplicitStrongCapture。此命令启用了 warnings-as-errors；不通过降低诊断级别绕过。

这次没有进入测试执行，不能记成 PhysicalLinkEvidenceTests 的断言失败，也不能据此判断 FIX-03 的物理链路修复无效。原命令使用 &&，前一步失败后 external-executor-build 不会执行。旧执行器与其历史原生构建 PASS 保留，新的物理出口 inspect 仍待验证。日志的 SDK 版本不是当前系统运行版本证据。

## 实际改动

只把外层 `operation = Task { @MainActor in` 改为 `operation = Task { @MainActor [self] in`，并增加一行说明注释。编译器在用户日志中给出的修复建议正是显式声明外层捕获；Swift 的[捕获列表语义](https://docs.swift.org/swift-book/ReferenceManual/Expressions.html)也区分隐式强引用、显式 `[self]` 和 `[weak self]`。

保留内层 `[weak self]`、MainActor 隔离、捕获结束的 defer 清理、取消及 token 检查、读取后错误处理和 30 秒快照失效。没有把长期过期任务改成强引用，没有修改读取器、路由解析/物理拓扑、写入/撤销、租约、恢复标记、签名、权限或依赖，也没有把 GUI canApply 改为 true。

## 本轮验证

Linux x86_64、Swift 6.2.1。仅恢复完整 UI 源码及新增测试的隔离工作区，原 UI 文件 Git blob 已与基线 `fa3f4a9306196f72e2e2bf22582433b04058cc5c` 核对一致；不是全仓库或完整产品包构建。

新增 `tests/external/test_preview_capture.py`，3 项 unittest 全部通过：捕获声明合同、实际 ExternalModel 的 -Onone 编译执行、同一模型的 -O 编译执行。两种模式均使用 Swift 6、strict-concurrency=complete、warnings-as-errors。该文件由现有 external-test 的 tests/external discover 纳入；也可独立运行。

模型从当前 macOS 源文件完整提取，方法体没有复制或改写成另一套逻辑。采集器、规划器和观察数据为明确替身；Linux 的 Published/ObservableObject 为最小替身，macOS 分支使用真实 SwiftUI。不是实际 SwiftUI 页面、真实系统采集或路由验收。

每种构建执行同一组 6 个内部生命周期场景：读取期间模型仍被持有、完成后弱过期任务不阻止释放；取消后的迟到读取不回填；旧读取/defer 不清除新任务；快照过期清理；编辑失效预览；读取失败释放 busy 状态。内部场景和两种优化模式不额外累加为独立 unittest 数量。

本地 Swift 6.2.1 对旧最小捕获写法也未发出用户工具链的 ImplicitStrongCapture，故不声称在本机编译器复现了该诊断。直接捕获合同可检测撤回 `[self]`；实际模型的严格编译/生命周期检查与用户 Mac 诊断分别记录。完整 Mac 源码 frontend parse 和 Python 3.9 语法检查通过；parse 不等于 Apple SDK 类型检查。

未执行 Mac 原生包构建、真实 GUI、系统网络读取或 apply；没有重跑 41 项核心、35 项执行事务及原 C/签名/解析套件。没有改测试过滤、关闭 warnings-as-errors、降级工具链或安装依赖。

## 本机复验

```bash
git pull --ff-only && \
python3 -m unittest discover -s tests/external -p test_preview_capture.py -v && \
swift test --package-path Packages/ExternalCore --filter PhysicalLinkEvidenceTests -Xswiftc -warnings-as-errors && \
/bin/bash dev.sh external-executor-build
```

通过后使用新输出的 Executable 精确路径再次 inspect 同一个本机目标。当前不执行 apply、不要求 sudo/WG 签名，不清空缓存/锁或恢复记录。复验若再次出现错误，仅需首处 error 及附近内容；无需完整网络表、证书或真实配置。

main 非强制追加提交，保留既有用户产物和历史证据，不发补丁包。本次修复编译阻断，不宣布物理出口识别、实际分流或恢复已经通过。
