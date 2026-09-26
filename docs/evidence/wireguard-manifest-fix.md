# WG-BUILD-FIX-01：上游清单 API 版本不一致

日期：2026-09-26。基线 main `b7fc77ae5d7741ce24cc76ab02c938c4e477e533`，tree `509c5cdbf5d65f41c826039f56e740e6feeb8216`。关联 WG-INT-05 / S1-04、Refs #1。[更新与重试](../wireguard-manifest-fix.md)。

## 用户报告与原因

USER_REPORTED：此前环境检查显示 app_environment/engine_environment=PASS，Python 3.12.9、Go 1.27.1；没有将环境通过记为编译通过。本次新的失败片段使用 macOS SDK 27.0，在 WireGuardKit 清单求值阶段报 `.v12` / `.v15` unavailable，并说明它们从 PackageDescription 5.5 引入。该片段来自新的运行目录，不证明此前 Git exit 128 的具体原因或修复措施。

固定的完整上游 Package.swift 的 Git blob 为 `5d15a1b0dd840942a03219034e17c8b5a3d2db38`。它声明 tools 5.3 却使用 5.5 API。我们的构建流程此前漏掉了这个兼容性处理，不是用户工具链未安装。最小修复只提升该清单第一行至 5.5，输出 blob 为 `47618ff08764067d623428d749594167a14032cf`；其余字节完全相同。Swift 语言模式不提升为 6，平台版本和运行行为不变。

## 实现

policy_hook.patch_manifest 验证完整输入及输出哈希；build 在原始 export_source 验证完成后、Adapter 变换和 Go/Swift 编译前，对本次隔离快照应用修复。拒绝符号链接、缺失文件、未知/已修改输入、重复应用及输出锁不一致，不静默回退。原始缓存不修改，新运行重新导出并自动修复，旧失败目录保留。result.json 记录实际修改后清单哈希，仍只在完整构建成功时写出 PASS。

增加完整上游清单测试参考与可审查的单行差异文件。参考清单遵循既有 `third-party/wireguard-apple/COPYING.reference`，不新增第三方运行依赖。原 test_runtime 的 9 个测试函数保留，只给编排替身补齐清单文件及结果哈希断言。

## 本轮执行

环境：x86_64 Linux、Swift 6.2.1、Python 3.13.5、Git 2.47.3。原 build.py、policy_hook.py、runtime_hook.py、bridge_assets.py、test_runtime.py、候选锁和上游清单按 Git blob 校验后用于本轮测试，没有用简化的生产模块代替。容器普通 Git 读取远端因 DNS 不可用失败；源码通过已授权 GitHub connector 读取。

| 检查 | 结果 | 边界 |
| --- | --- | --- |
| 原清单 `swift package dump-package` | 预期失败，实际复现 v12/v15 与 5.5 提示 | 不是 Git/Go 错误 |
| 修复后 `swift package dump-package` | PASS，toolsVersion=5.5.0 | 真实 SwiftPM 清单编译/求值；不是 Apple SDK/协议源码编译 |
| 平台/目标/依赖结果 | PASS，仍为 macOS 12、iOS 15，三个原目标、空 SwiftPM 远端依赖 | 产品自身最低 macOS 26 未变 |
| 新增 test_manifest.py | PASS，14 tests，无跳过 | 哈希、单行不变性、真实 git apply、真实 SwiftPM 及编排/失败路径 |
| Python 语法、git diff --check | PASS | 不等于完整原生编译 |

新测试中的导出/Adapter/Go/Swift 原生编译阶段为显式替身，只验证清单修复顺序、原始文件保留、失败阻断及结果记录；实际清单变换、文件操作、git apply 和 SwiftPM 求值不是替身。未重跑全套 engine-test、旧 WireGuard/Go/Swift/LocalDev/ManagedSettings 测试，不借用此前测试数量。

复现：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -p test_manifest.py -v
```

测试里的真实 SwiftPM 使用完整固定清单，在临时目录运行 dump-package，不下载依赖、不编译或运行协议，也不调用 NE。Swift 不可用时该项明确跳过，本轮环境中没有跳过。

## 未完成、权限与恢复

NOT RUN：本次修复后的 macOS SDK 27 原生完整编译链接、C ABI/真实 TUN、签名/NE、Keychain、握手/实际分流/DNS/停止撤销。清单修复不关闭这些门槛；没有声称只修这一个问题就保证整个引擎编译成功。

无工具安装、全局 PATH/Xcode/Go 更改、运行时网络设置、工作区/凭据格式或协议改动。开发签名继续暂停。源码回退使用正常后继提交，原 .conf、Keychain、工作区、缓存及 build.lock 不删除。直接更新 main，无手工更新包。
