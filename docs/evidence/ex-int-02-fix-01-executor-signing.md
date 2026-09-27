# EX-INT-02-FIX-01：执行器重复签名构建修复

日期：2026-09-27。基线 `70098d91fa24a34ce8dcba2aae7c1fd27b6baed4`。关联 EX-INT-02；不改变[前台执行限制](../external-execution.md)或路由权限。

## 用户反馈与定位

用户提供的 `tests/external_execution` 六项 Python 测试全部通过，其中 C 适配器为 15 组模拟内核场景；保留为 USER_REPORTED PASS，不当作真实路由验收。粘贴开头的 Swift Testing “0 tests”没有提供 XCTest 汇总，不能据此新增或否定 XCTest 通过数量。

随后构建报 `VPNExternalLease: is already signed` 并失败。基线脚本先完成编译、复制和 arm64 检查，再对副本调用 `codesign --sign -`，但未允许替换已有签名。日志支持定位在这一构建后处理步骤，不是缺少开发证书，也不能将整体失败改记成原生构建 PASS。完整本机路径不入库。

## 修复范围

仅对本次新构建目录内复制的 `VPNExternalLease` 增加 `codesign --force --sign - --timestamp=none`，仍执行 `codesign --verify --strict`。不就地修改 SwiftPM 原产物或已安装程序，不使用 `--deep`、移除签名、忽略退出码或降低校验要求。`--force` 是替换已有签名的参数，参见 [Apple DTS 说明](https://developer.apple.com/forums/thread/127861)。

签名及验证的命令、标准输出和错误现在追加到同一个 `build.log`，保留之前的编译日志。两步都成功后才计算最终文件 SHA-256、写入摘要和输出 PASS；失败或超时不发布成功标记。构建仍拒绝 root，不提权、不执行产物、不安装 Helper、不修改网络。

## 本轮执行证据

Linux 部分源码验证目录，仅恢复完整基线构建脚本并核对 Git blob；不是整个仓库或 Apple SDK 环境。

| 检查 | 结果与边界 |
| --- | --- |
| 新增 `test_executor_signing.py` | 6 项 unittest 通过；实际完整 builder 的 main，编译器/lipo/codesign 为明确替身 |
| 已签名、未签名两种输入 | 副本重签后严格校验；哈希对应签名后的副本，原编译输出不改动 |
| 签名失败、验证失败、签名超时、错误架构 | 失败不输出 PASS/产物摘要、不写 hash；不重试、不执行产物；签名诊断进入日志 |
| 原样基线负向复现 | 同一已签名输入在旧脚本停止于签名，返回 2；没有 verify、PASS 或 hash |
| Python 兼容语法与入口 | Python 3.9 语法检查通过；真实 Linux 无参数入口拒绝平台（69），`--apply` 拒绝参数（2） |

复制、文件锁、日志追加及哈希操作在独立临时目录实际执行；测试产物为合成字节，不是 Mach-O。六项测试不重复累计其中断言或重跑次数。没有执行真实 codesign、Mac 原生构建、旧 Swift 包/六项 Python 全量回归或任何路由操作。新测试由原 `external-execution-test` 的 discover 自动包含，不改变测试入口。

## 本机复验

已通过的旧测试无需为此全部重跑，先执行本次针对性回归和原构建入口：

```bash
git pull --ff-only && \
python3 -m unittest discover -s tests/external_execution -p test_executor_signing.py -v && \
/bin/bash dev.sh external-executor-build
```

不需要 sudo、开发证书、WG 签名、清空缓存/锁或删除恢复标记。修复后 Mac 完整构建仍待用户反馈；预期最终摘要保留 `execution=NOT_RUN`、`network_settings=NOT_APPLIED`、`helper_installation=NOT_REQUESTED`。本次不授权真实 apply，不将重签成功等同于实际分流或恢复通过。

仅修改构建脚本、增加测试及本证据；C/Swift 执行代码、规则、默认路由/DNS、用户凭据、依赖锁和 GUI 均不变。main 非强制交付，回滚使用后续 revert，保留本机数据、旧证据和恢复记录。
