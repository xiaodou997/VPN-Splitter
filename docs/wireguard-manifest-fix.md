# WireGuard 原生构建：PackageDescription 5.3 / 5.5 修复

日期：2026-09-26。这是 WG-INT-05 构建候选的缺陷修复，不是新增 VPN 能力。用户的新日志已经进入 SwiftPM 解析阶段；与此前 Git 128 属于不同的失败步骤，未据此判断此前 Git 失败的原因。

## 原因与修复

固定的上游 `Package.swift` 声明 `// swift-tools-version:5.3`，同时使用 `.macOS(.v12)` 和 `.iOS(.v15)`。这两个常量需要 PackageDescription 5.5。即便本机 Xcode/Swift 更新，SwiftPM 仍按清单声明选择 API 版本；日志中的 `-swift-version 5` 也不是要求用户安装旧 Swift。

本次只把隔离构建快照的第一行改为 `// swift-tools-version:5.5`。没有切到 Swift 6 语言模式，没有修改依赖的平台最低版本、目标、桥接链接设置或协议代码，也没有改变 VPN-Splitter 的 macOS 26 最低要求。不需要降级 SDK 27、重装 Xcode/Go、准备开发签名或关闭安全校验。

构建流程先验证完整上游文件，再应用精确输入/输出 Git blob 约束的变换。缓存中的原始源码及历史失败目录不改动；每次重新导出后自动应用。结果文件增加实际 `patched_manifest_blob`，可审查差异见 `third-party/wireguard-apple/patches/0005-manifest-tools-version.patch`。用户不需要手工应用该文件。

## 更新与重试

在本地 VPN-Splitter 仓库根目录执行：

```sh
git switch main &&
git pull --ff-only &&
git rev-parse --short HEAD &&
/bin/bash dev.sh engine --fetch
```

不编辑 `.local/.../wireguard-apple/Package.swift`，不删除缓存、build.lock 或失败日志。Git 冲突时停止并保留工作，不 reset/clean/force。原构建流程继续使用缓存并创建新的运行目录；`--fetch` 只允许固定公开源码和依赖下载，不会启动 VPN 或访问用户配置/Keychain。

最终仍须看到 `compile_link=PASS` 才表示完整原生编译链接成功。清单修复成功不代表后续 Go/Swift/Apple SDK 编译、Provider、握手或分流已经通过。出现新错误时提供新运行目录对应的首个错误片段，不上传全量日志或真实配置。

## 验证

本次真实 SwiftPM 清单求值已复现原错误，并确认修复后 `dump-package` 成功；14 项针对性回归通过。运行环境是 Linux Swift 6.2.1，完整 Mac 构建和原生执行仍待重试。没有把原生构建阶段的替身测试当作实际引擎编译。详见 [本次证据](evidence/wireguard-manifest-fix.md)。

API 版本含义参见 [SwiftPM PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)；上游清单固定在 [WireGuard revision 2fec12a](https://github.com/WireGuard/wireguard-apple/blob/2fec12a6e1f6e3460b6ee483aa00ad29cddadab1/Package.swift)。
