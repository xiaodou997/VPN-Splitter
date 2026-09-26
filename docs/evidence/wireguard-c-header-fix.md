# WG-BUILD-FIX-02：WireGuardKitC 显式类型依赖

日期：2026-09-26。基线 `f039af8da6b08e17a60487cc7b80095be07c7175`；
任务 WG-BUILD-FIX-02 / S1-04，Refs #1。[重试说明](../wireguard-c-header-fix.md)。

## 用户报告与原因

USER_REPORTED：新的运行已进入 Swift build / WireGuardKitC 显式 PCM 编译，
使用 macOS SDK 27.0，因 `u_int32_t`、`u_char`、`u_int16_t` 的声明不可见失败。
这不是此前的 PackageDescription 版本错误，也不是签名或 Go 安装错误。
未据这段局部日志宣布整个 Go/Swift 链接或任何 VPN 功能通过。

固定上游 `WireGuardKitC.h` 仅包含 key.h/x25519.h，却使用 BSD 类型。
补上公开的 `<sys/types.h>`，保持其余字节（包括全部结构体字段）不变。
原 Git blob `54e4783d40f3346f431f92ce6e970ae4024cd417`；修改后
`84c53f7068ef9d3665e7f53d851f388806877342`。不使用 SDK 私有模块/头文件，
不重定义 typedef、不关模块、不更改协议、工具链或产品平台要求。

## 代码

新增 c_header_hook.py；compile_native 在桥接阶段和 Go/Swift 命令之前调用。
输入/输出/候选锁校验先于写入，符号链接/父目录链接/缺失/漂移/重复应用拒绝。
原始源码导出仍逐文件验证，原头文件 blob 纳入 apple.blobs；成功结果记录
经过校验的输出锁哈希。原始缓存与旧失败目录不写入；每次新运行重新导出。

四个完整上游头文件/module map 作为测试参考，版权保留，使用仓库已保留的
COPYING.reference。test_build.py 只补齐共享导出夹具中的头文件；全部原有
28 个 test_ 函数 AST 与基线相同，无删除或放宽断言。

## 本轮实际执行

环境 Linux x86_64、Clang 17.0.0、Python 3.13.5。Mac 项目入口再次返回
project_path_not_found；未借其他项目绕过范围。容器 Git 无法解析 GitHub，
源码经连接器读取，build.py、policy_hook.py、test_build.py 和候选锁在修改前
分别核对到远端完整 blob。没有获取或使用用户配置、凭据或签名资料。

| 检查 | 结果 | 范围 |
| --- | --- | --- |
| tests/wireguard/test_c_header.py | PASS，14 项，无跳过 | 本批针对性回归 |
| 原头文件独立 C / Clang 模块编译 | 预期失败 | Linux 上复现类型缺失；不是伪造 SDK 27 错误 |
| 修复后完整原头文件及真实 module map 编译 | PASS | Clang C 和模块导入；含结构体尺寸与字段偏移断言，仅语法/PCM，不链接或执行协议 |
| 完整上游 4 文件 Git blob | PASS | 无合成类型替换或 SDK 私有文件 |
| 可审查补丁 git apply --check / apply / 重复拒绝 | PASS | 输出逐字节等于实际 helper |
| compile_native 前置接线 | PASS | 执行当前函数原 AST，明确以 bridge-stop 替身截断后续阶段；没有 Go/Swift 原生构建 |
| Python AST/语法、旧 28 个测试函数不变性 | PASS | 不等于完整旧测试套件执行 |

复现：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -p test_c_header.py -v
```

哈希、字节不变性、路径含空格、缓存保留、坏锁/坏文件不写入、符号链接拒绝、
真实补丁应用及类型缺失回归均覆盖。Clang 不可用时两项正向编译和 Linux 负向
编译明确跳过，本轮未跳过；Mac 跳过 Linux 特定负向复现，仍运行正向编译。

NOT RUN：修复后 Mac SDK 27 完整 Swift/Go 链接、所有旧 engine-test/Go/应用
测试、真实 C ABI/TUN、Keychain、签名 Provider、握手/分流/DNS/撤销。
不能以此头文件 PASS 保证其他模块无后续编译错误。runtime_approval 保持
NOT_GRANTED，开发签名继续暂停。

## 权限与回退

不安装软件、不改 Xcode/Go 全局配置、不关闭模块或安全校验、不激活扩展、
不修改路由/DNS/工作区/Keychain。源码用正常后继提交回退，不清理用户数据、
.local、缓存、失败目录或 build.lock；唯一交付入口仍为 main。
