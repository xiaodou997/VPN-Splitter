# WireGuardKitC：BSD 类型依赖缺失修复

日期：2026-09-26。关联 WG-BUILD-FIX-02 / S1-04，Refs #1。

用户的新日志已通过清单求值，进入 WireGuardKitC 显式模块构建；
`u_int32_t`、`u_char`、`u_int16_t` 的声明不可见是同一个头文件依赖缺失问题。
固定上游的 `WireGuardKitC.h` 只包含 `key.h` 和 `x25519.h`，却使用由
公开系统头文件 `sys/types.h` 声明的 BSD 类型。模块单独编译时不能依赖
其他 Swift 文件先导入 Darwin。参见 [Clang Modules / Missing includes](https://clang.llvm.org/docs/Modules.html#modularizing-a-platform)。

本次修复只在该头文件的本次构建副本中补充：

```c
#include <sys/types.h>
```

不重新定义类型、不改结构体、不导入 SDK 私有 `_DarwinFoundation1` / `_types`
路径、不关闭显式模块、不降级 Xcode/SDK，也不修改协议或网络设置。
新 helper 先核对输入、输出及锁文件，拒绝符号链接、未知源码和重复应用。
构建调用在 Go/Swift 编译前执行；原始源码缓存、历史失败目录和用户数据不变。
`result.json` 在完整构建成功后记录已校验的 `patched_c_header_blob`。

## 更新并重试

在仓库根目录执行：

```sh
git switch main &&
git pull --ff-only &&
git rev-parse --short HEAD &&
/bin/bash dev.sh engine --fetch
```

无需手改 `.local`、删除缓存/锁、安装工具或准备签名。Git 冲突时停止并保留
本地修改，不 reset/clean/force。构建仍不运行探针、建立隧道、访问 Keychain
或应用系统路由/DNS。`compile_link=PASS` 才代表本次完整编译链接通过；
头文件修复不保证后续所有模块都已通过，也不意味着可连接 VPN。

新错误请提供新运行目录中第一处 `error:` 附近的片段，不上传原始配置、
密钥或整个日志目录。本轮验证范围见 [证据](evidence/wireguard-c-header-fix.md)。
