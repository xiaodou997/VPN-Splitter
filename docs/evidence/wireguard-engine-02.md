# WG-INT-02：固定源码构建管线与策略入口编译准备

日期：2026-09-25。基线 main `494e6592f90e8b49639146206d83248a4ef0be46`。任务 S1-04/S1-06 部分；T-WGB01–05；Refs #1。[ADR-014](../adr/ADR-014-wireguard-build-only-candidate.md)、[使用指南](../wireguard-engine-build.md)。

## 代码与边界

新增隔离 macOS arm64 构建管线：预检 → 显式公开下载或离线缓存 → revision/tree/逐文件校验 → 固定策略入口补丁 → Go c-archive → SwiftPM 链接 ManagedSettingsApple 和 WireGuardKit → 检查实际定义符号与产物哈希。每次独立输出、保留失败记录、不运行产物。旧 LocalDev、ManagedSettings、PolicyCore、AppCore、Provider 工程和原测试入口均未改变。

固定 Apple `2fec12a6e1f6e3460b6ee483aa00ad29cddadab1`、Go 核心 `ecfc5a8d54462e18e13c72173e2623d16d8e25a0`，来自官方仓库/官方 GitHub 镜像。核查日期如上，不把版本较新解释为安全。Go 依赖按核心自身 go.mod/go.sum 保持不变；顶层许可证副本与原 blob 一致，完整传递依赖许可及可达漏洞检查未完成。具体来源固定在 build-lock.json 与 ADR 链接。

## 本轮实际执行

环境：x86_64 Linux、Swift 6.2.1、Python 3.13.5；本机 Go 为 1.23.2，不作为本候选的原生构建工具链。Mac Runner 状态调用返回 404 / tunnel_client_not_seen。容器 git 访问 GitHub 无法解析域名，所以没有实际下载依赖或构建 Go 核心；使用 GitHub connector 读取和核对上游源文件。

| 检查 | 实际结果 | 不能替代的验证 |
| --- | --- | --- |
| Python 构建工具回归 | PASS，28 tests | 编排使用显式 Go/Swift 命令替身；不是 native build |
| tools/wireguard/test.sh | PASS | 实际运行上述完整 28 项，无引擎下载或执行 |
| 官方 Adapter 完整内容 Git blob | PASS，`f7be19b15f5cbe39fd0e6496cdf0b2d426d83b6b` | 通过 connector 读取并重建精确字节；不是本机 git fetch |
| 精确 Adapter 上执行受控变换 | PASS，patched blob `ecce2a45f1136eab99ebfd423577de2ccce543f7` | 不等于 Swift 类型检查或 NE 实际应用 |
| reviewable patch 独立 git apply --check / apply | PASS，输出与受控变换逐字节相同 | 不等于 macOS 运行验收 |
| 新探针及补丁后 Adapter 的 swiftc parse | PASS | 没有 Apple SDK 类型检查 |
| 生成的 SwiftPM manifest dump-package | PASS | 只解析 manifest，不解析/编译完整依赖 |
| Bash 语法检查、许可证原始 blob | PASS | 不证明核心可运行 |
| 原生 Go arm64 c-archive / SwiftPM 链接 | NOT RUN | 等待 Mac 和指定 Go 工具链 |

没有重跑旧 AppCore 202 项、ManagedSettings 26 项或 PolicyCore 79 项独立测试；相关生产代码未改，不把历史 PASS 计作本次结果。也没有收到用户对上一批新测试入口、Keychain 或原生对象验证的新结果。

## 回归追踪

T-WGB01：只允许两个固定公开源；拒绝浮动 ref、源 tree/blob 变化、链接/越界/重复归档成员、未知 Git 文件类型。另用真实本地 Git 临时仓库验证归档、全体文件哈希及 export-ignore 篡改拒绝，不访问远端。下载可选，缺缓存时无 --fetch 即拒绝；Linux 在任何下载/创建目录之前拒绝原生构建。

T-WGB02：政策入口无默认参数；恰好覆盖 start/update/resume 三处；保留协议 UAPI；重复补丁、锚点漂移、剩余生成器回退和错误输入 SHA 均拒绝。另在完整真实上游字节上验证变换和差异文件一致。

T-WGB03：Go 检验和编译失败后不启动 Swift；锁文件变化即停止；链接失败不产生成功结果；符号必须是定义而非未定义引用；路径含空格正确传递。原生编译命令使用替身，不把假产物当真实引擎。

T-WGB04：环境覆盖清理，保持 TLS/Go 模块校验，禁止自动 Go 工具链选择；测试 Mac 前置条件和缺失/错误 Go 版本。子进程失败与超时真实执行测试，构建锁冲突和释放真实执行测试；超时/中断只终止该命令自己创建的进程组，不结束用户其他应用。

T-WGB05：探针不调用 start/update/系统设置应用/Keychain；脚本不运行产物、不安装、不删除旧数据、不修改 GOROOT。固定源码及 licence reference 可审查。源码合同不是完整行为安全证明。

## 未完成与恢复

NOT RUN：实际源下载、Go 模块校验、arm64 archive、Apple SDK/Swift 完整链接及任何真实 NE/Keychain/VPN 测试。NOT APPROVED：运行或发行候选。没有将静态回归的 28 项冒充 Go 引擎或真实连接测试。

上游设置超时后继续、wgSetConfig / Device.Up 返回值、部分失败资源清理、日志/handle 并发、正确 utun 与实时配置绑定仍开放；本补丁仅强制策略入口。首次真实 Managed 联调前恢复签名，目前继续暂停。

所有新构建输出只在 .local/wireguard-engine，失败目录保留；不以旧产物顶替失败构建。源码用正常后继提交撤回，不 reset/clean；工作区和凭据格式不变，不触碰用户 .conf / Keychain / 系统网络。main 仍为唯一交付入口，不生成新的更新包。
