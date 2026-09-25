# LD-01：独立 LocalDev 与策略草稿闭环

日期：2026-09-25。范围：LD-01；S1-02 规则复用、S4-04 界面前置的部分交付。关联需求 T-U02–U05、T-P01–P03；本轮测试编号 T-LD01–T-LD05。决策见 [ADR-007](../adr/ADR-007-localdev-before-signing.md)。

## 证据级别

本轮执行环境为 x86_64 Linux、Swift 6.2.1；连接到用户 Mac 的 Runner 不在线。下表中的 PASS 只对应真实执行的离线检查。**没有执行 macOS SDK 类型检查、Xcode 构建、签名或 GUI 测试，也没有任何真实隧道 / 路由 / DNS 操作。**

用户先前提供的 `tools/s1/build.sh preflight` 与 `unsigned` 结果均为 `exit_code=0`，标记 USER_REPORTED。它们验证的是旧 S1 工程，不是本次新增的 LocalDev，不能拿来补足本轮 Mac 测试。

## 已执行

| 项目 | 结果 | 覆盖及限制 |
| --- | --- | --- |
| AppCore Debug，warnings-as-errors | PASS，28 tests | 真实 PolicyCore 编译适配、草稿和模拟状态机 |
| AppCore Release，warnings-as-errors | PASS，28 tests | 同一测试集，优化构建 |
| Python LocalDev 合同检查 | PASS，12 tests | 独立 target、scheme、依赖路径、签名设置、网络边界和界面失效合同；不是 GUI 测试 |
| SwiftUI 源码语法解析 | PASS | `swiftc -frontend -parse`；不是 macOS SDK 类型检查 |
| Xcode 工程 plist 检查 | PASS | `plutil -lint`；不是 xcodebuild |
| Bash 语法检查 | PASS | `bash -n tools/localdev/build.sh`；没有 Mac 构建效果 |
| Linux 上的构建入口平台拒绝 | PASS（预期 exit 2） | 在创建构建目录 / 调用 Xcode 前拒绝非目标平台 |

命令：

```sh
swift test --package-path Packages/AppCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/AppCore -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/localdev -v
swiftc -frontend -parse apps/macos/LocalDev/LocalDevApp.swift
plutil -lint -- apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj/project.pbxproj
bash -n tools/localdev/build.sh
# 仅本轮 Linux 环境：预期退出码 2，不是成功构建。
/bin/bash tools/localdev/build.sh build
```

测试使用合成规则及临时目录，不包含用户 VPN 配置。AppCore 依赖的 PolicyCore 源码与基线提交 `62a9d95db3d89732571a4b148874d591ccf8f650` 的 Git blob 一致；本轮没有改 PolicyCore 算法。本轮未重跑其独立的完整 79 项测试，也未重跑原 S0 / S1 测试；不能把历史结果记成本次执行。

## 测试追踪

T-LD01：LocalDev 唯一 application target；不嵌入扩展；本地 ad-hoc 构建配置及失败拒绝打开。离线合同 PASS，Mac 构建 / 签名 / 打开 NOT RUN。

T-LD02：工作区往返保存、权限、版本 / 大小 / 重复 ID / 单行限制、符号链接拒绝、坏文件保留；保存失败保持磁盘与已接受的内存草稿。Linux 单测 PASS，Mac 文件系统行为及 GUI 重启持久化 NOT RUN。

T-LD03：first-match、遮蔽、移动后的命中改变、主机归一化、禁用草稿、未支持类型 / REJECT / External Include 拒绝、诊断错误不回显输入。真实 IPv4PolicyCompiler 单测 PASS；没有 DNS、基础设施、peer、真实出口证明。

T-LD04：取消、编辑、切换、删除及重新编译使旧 token / 预览失效；迟到、重复回调被拒绝；失败可重试；同一或未知选择不打断当前尝试。纯状态机 PASS；GUI 延迟任务交互 NOT RUN。模拟成功不能关闭 T-W / T-O / T-E 的任何真实连接测试。

T-LD05：目标隔离、源文件引用、脚本边界、无网络模块 / 通用进程调用、诊断失效逻辑的离线合同 PASS。静态合同不是行为安全证明，人工清单仍需执行。

## 尚未执行 / 尚未实现

NOT RUN：macOS 26+ / arm64 Xcode 构建、实际 ad-hoc 签名、窗口布局和完整人工清单。验证入口与步骤见 [LocalDev 操作](../localdev.md)。

NOT IMPLEMENTED：`.conf` / `.ovpn` 导入、Keychain、完整配置编辑、基础设施 / peer 校验 UI、DNS-derived 域名能力、真正网络诊断、生产后端注入、实际 VPN。现有约束编译器保留，但本轮规则预览没有调用它。

PAUSED：开发签名资料准备及正式扩展加载。真实 Managed 联调前恢复；Developer ID / 公证 / DMG 留到发行阶段。S0–S5 门槛不因上述离线 PASS 或源码合入而关闭。

## 权限、失败与撤回

无 root、系统授权弹窗、扩展激活或网络设置请求；仅写 LocalDev 自己的用户草稿目录和仓库 `.local/localdev` 构建结果。保存失败不接受编辑；加载失败只读，人工保护恢复；原始错误内容不进入诊断。普通规则 / 名称仍可能是私有信息，不能当作已脱敏日志上传。

停止使用可直接退出 LocalDev；没有要撤销的系统网络修改。源码撤回应使用新增提交保留历史，不 force reset；用户数据和构建目录不自动删除。该开发版没有凭据迁移，也不承诺多实例并发写入。
