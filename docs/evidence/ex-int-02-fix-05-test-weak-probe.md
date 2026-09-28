# EX-INT-02-FIX-05：生命周期测试弱引用探针兼容修复

日期：2026-09-28。基线 `c6052bd5ff870d9b266f98abcb92e3810dfaaa19`。关联 EX-INT-02、FIX-04 测试；不改变 External 的功能或权限范围。

## 用户反馈与修复

用户的 `test_preview_capture.py` 两项编译执行测试在生成的 ModelHarness.swift 编译阶段失败，诊断为 `VariableNeverMutated::WeakMutability`：局部 `weak var observedModel` 未显式修改。第三项捕获声明检查通过。失败来自上一批新增测试夹具，不是产品源码中的新错误，也不是生命周期断言失败。由于使用 `&&`，之后的 PhysicalLinkEvidenceTests 和 executor-build 没有执行；FIX-03 当前物理路径验收仍待完成。

将测试观察变量替换为显式弱捕获、仅返回 Bool 的常量闭包：

```swift
let modelIsAlive: @MainActor () -> Bool = { [weak observedModel = model] in
    observedModel != nil
}
```

捕获初始对象，而非随后被清空的可变 model；闭包不给调用者返回强引用。仍在移除测试自身强引用后检查“在途检测任务持有对象”，完成后检查“过期任务不阻止对象释放”。不改成普通强引用，不手动清空弱引用伪造释放，不关闭 warnings-as-errors，也不依赖较新编译器的 weak let 语法。捕获列表语义依据 [Swift 语言参考](https://docs.swift.org/swift-book/ReferenceManual/Expressions.html#Capture-Lists)。

在原捕获声明测试中补充探针形式与两处断言的检查，供未产生此新诊断的编译器保留回归约束。测试数仍为三项，没有删掉或跳过两项生命周期测试。

## 本轮实际验证

Linux x86_64，Swift 6.2.1、Python 3.13.5。恢复的完整测试文件和完整 ExternalPreviewApp.swift 分别与基线 Git blob `47dd127ef0b851599a068a1a248ba0c0a58828fd`、`1017d226ea525206c93ed26ce4113dbdbe39d908` 核对一致。验证工作区只包含相关完整源文件，不是完整仓库或 Apple SDK 环境。

- 原三项 unittest 修改后全部通过。实际 ExternalModel 从产品源码原样提取，在 `-Onone` / `-O`、Swift 6、strict-concurrency=complete、warnings-as-errors 下编译执行；每种模式运行原六组生命周期场景，不重复累计。
- 系统采集、规划器及观察类型是明确替身；Linux 上 Published/ObservableObject 也是替身。没有真实 UI 或网络读取。
- 临时变异复核：把探针改为强捕获、把模型过期任务改为强持有，均能通过编译，但被原释放断言超时捕获；改为直接捕获随后清空的可变 model，则被严格并发编译拒绝。变异只在临时测试副本运行，产品源码未修改；还原后再次运行三项全部通过。
- Python 3.9 语法兼容检查通过。本地工具链未用于证明已复现用户的新 WeakMutability 诊断，不能把这些结果写成用户 Mac 原生通过。

未重跑 PhysicalLinkEvidenceTests、完整 ExternalCore/ExternalExecution、C/签名套件或执行器构建；未执行 inspect/apply。旧原生构建成功与现场 physicalUnknown 分别保留。仅修改测试文件及本证据，不修改产品、编译严格程度、网络、权限、签名、依赖、恢复标记或用户数据。

## 本机复验

```bash
git pull --ff-only && \
python3 -m unittest discover -s tests/external -p test_preview_capture.py -v && \
swift test --package-path Packages/ExternalCore --filter PhysicalLinkEvidenceTests -Xswiftc -warnings-as-errors && \
/bin/bash dev.sh external-executor-build
```

本次重试后两步是为了继续此前被测试夹具阻断的 FIX-03 原生复验，不是测试文件修改本身要求重建产品。通过后使用本次输出的新 Executable 精确路径 inspect 同一个目标；不沿用旧复制产物。不需要 sudo、降级 Xcode、清缓存/锁或恢复 WG 签名，当前不执行 apply。通过 main 普通追加提交交付，无补丁包。
