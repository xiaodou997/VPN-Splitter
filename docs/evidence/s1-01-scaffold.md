# S1-01 工程与 main 整合证据

日期：2026-09-25。状态：工程代码已提供；Xcode 构建、真实签名/加载与公证均 NOT RUN。对应 S1-01、S1-06 的准备部分，不关闭 T-U01/T-U06 或完整 S1。

## 仓库整合

用户明确要求以 main 真机操作。PR #3 保留历史合并为 684cde09ffbdf17aa18dd31f5e1f8882ac57cbf2；S0 分支先用双亲提交 7dca4a3ad4251b7c55448aa4a37a13ad7b6f5aa2 同步 main、合并 AGENTS 的两侧约定，再通过 PR #2 合并为 528d628a25732a3536a614040826346bc9186b33。没有 squash、force push 或丢弃 S0/PolicyCore 源码和证据。

当前 GitHub 连接可合并/创建提交，但没有删除远端分支的动作；本轮没有声称已删除。提供 tools/cleanup-merged-branches.sh：默认仅检查，显式 --delete-merged 才对两个已知名称执行带 exact-head lease 的删除，并验证是 origin/main 祖先；新提交或歧义即停，不删除本地数据。该脚本仅做语法检查和审查，未执行远端删除。

## 实际运行

环境：Linux x86_64、Swift 6.2.1、Python 3.13.5；无法访问 macOS SDK。备用本地 Runner 返回离线，未在用户电脑执行命令。

| 检查 | 实际结果 |
| --- | --- |
| PolicyCore Debug | 79 XCTest，0 failures；warnings-as-errors |
| PolicyCore Release | 79 XCTest，0 failures；warnings-as-errors |
| tests/s1/test_scaffold.py | 25 个离线 unittest 通过 |
| project.pbxproj | Swift 工具链 plutil -lint 通过；不是 xcodebuild -list |
| SwiftUI App / Provider 源文件 | swiftc -frontend -parse 通过；不是 macOS SDK 类型检查 |
| Bash 构建与分支清理脚本 | bash -n 通过；未运行实际构建/签名/删除 |
| plist/entitlements/scheme | plistlib/ElementTree 解析与结构合同通过 |

79 在两种构建中重复执行，不是 158 个不同用例。25 个 Python 用例测试工程引用、生成器一致性、渠道 entitlement、profile 过期/ID/团队校验、非 Mac 拒绝以及静态无数据面合同，不是系统安全审计或真机功能用例。S0 三批 Python 测试本轮未重跑。

## 明确未验证

原生 Xcode 工程加载/链接、Swift 6 的 Apple SDK 隔离注解、自动签名账号配置、描述文件真实授权、Developer ID 手动构建、公证/Gatekeeper、扩展批准/替换/移除、测试配置的保存/删除、Provider 启动与1001错误传递都待真机。脚本/源文件存在不等于这些流程通过。

无有效 .conf/.ovpn 或凭据输入，无系统路由/DNS 写入、NE 协议连接或真实测试流量。本阶段没有引入 WireGuard/OpenVPN 和生产 Helper，也没有虚构可用发行包。

下一步使用 main 执行 tools/s1/build.sh preflight / unsigned；精确工具链和失败行由用户反馈。已通过的 S0 实验无需重做，完整版本/收尾/业务替代证据仍保留原缺口。
