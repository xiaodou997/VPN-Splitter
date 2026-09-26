# WG-INT-07：会话控制、取消清理与进程内一次性配置交付

日期：2026-09-26。基线 main `67cac05ed08331a5fcf905da6e06209baa34786c`，
tree `7f98352071eeb55aaf597907621ebf5d1cfb91a9`。任务 S1-03/04/05 部分；
测试 T-WGG01–05；Refs #1。[ADR-019](../adr/ADR-019-provider-session-control.md)、[操作](../wireguard-session.md)。
用户本轮仅要求继续；48eee07 的 USER_REPORTED 原生 PASS 独立保留，不扩展到新代码。

## 交付

新增无外部依赖的 ProviderSession 包：单次尝试、完整身份核对、加载/启动/停止
独立期限、启动过程中取消后的排停机、重复/迟到回调处理、有限停止等待者、
后端静止与外部系统撤销观察分离。接收结果时复核单调时钟，避免仅靠定时器先后。
外部调用需保持提供者对象及控制器生命周期，不能把任意闭包当成系统观察器。

新增 ManagedWireGuardSession 原生驱动：真实 assembly/Adapter.start/stop 接线、
一次性配置快照、过期/已消费对象拒绝、静态错误转换。原生停止报错（包括
providerResetRequired）不伪装成功。Delivery 不实现 Codable，描述和反射不暴露
内容；这不是安全 IPC 或生产 Keychain 读取器，也没有放宽旧 LocalDev vault。

构建仍只链接探针，不执行；新增本地 ProviderSession 依赖和原生驱动源复制，
旧 engine-test 加入新包 Debug/Release。旧 Provider、LocalDev、AppCore、Go 核心、
已审查的 Adapter 补丁及依赖锁未改。真实 Provider/凭据/fd/撤销观察仍待接通。

## 本轮实际执行

环境：Linux x86_64、Swift 6.2.1、Python 3.13.5。Mac 项目入口返回
project_path_not_found；没有使用其他项目绕过范围。容器 Git 远端解析失败，
修改所依赖的源码由连接器读取后按完整 Git blob 核对：build.py=4c7bb638、
Probe.swift=63b44a08、test.sh=73e680be、test_assembly.py=5d6cfc7b、
bridge_assets.py=ffa98f49、ManagedWireGuardAssembly.swift=5936b523、development.md=3b501eb1。
没有调用真实 Keychain、激活 NE 或创建网络接口。

| 检查 | 本次结果 | 范围 |
| --- | --- | --- |
| ProviderSession Debug，warnings-as-errors | PASS，31 项 | 实际控制器，明确内存后端/手动时钟；含真实 Task 定时器和后台回调 |
| ProviderSession Release，warnings-as-errors | PASS，31 项 | 相同测试和生产源码，优化构建 |
| test_assembly.py | PASS，8 项 | 保留全部原用例，仅更新新增源/依赖数量；真实 SwiftPM 清单求值及文件复制 |
| test_session.py | PASS，7 项 | 接线/文件失败/入口检查及可执行驱动 harness |
| 实际原生驱动源码 + 显式原生替身 harness | PASS，11 个场景（计入上行 1 项） | 控制器和驱动为实际代码；只替换模块导入；WireGuard/NE/assembly/config 类型为明确替身 |
| 新原生驱动/Probe 单文件 Swift parse、Bash/Python 语法 | PASS | 不是 Apple SDK 编译 |
| build.py AST 比对 | PASS | create_probe 外的全部代码与基线相同 |

初次包骨架编译时因测试目录尚空，swift test 返回 no tests；补入测试后重新执行
上述两种配置并通过，不把空测试运行记为 PASS。本轮没有执行完整 engine-test
聚合入口或重跑不变的 WireGuardSupport、ManagedSettings、AppCore、PolicyCore、
Go bridge 和其余 Python 套件；不把旧通过数量计入新结果。

复现本次主要范围：

```sh
swift test --package-path Packages/ProviderSession -Xswiftc -warnings-as-errors
swift test --package-path Packages/ProviderSession -c release -Xswiftc -warnings-as-errors
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -p test_assembly.py -v
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests/wireguard -p test_session.py -v
```

T-WGG01：加载拒绝/取消/超时、重复来源、错误完整身份、迟到资源丢弃和单次消费。
T-WGG02：启动错误/超时、异步取消、先等待启动回调再停机、旧会话不可影响新对象。
T-WGG03：未知清理、迟到停机、重复结果、等待者上限、停止成功不是系统撤销。
T-WGG04：源输入快照隔离、静态错误、反射隐藏、实际 start/stop 调用点与全字段版本核对。
T-WGG05：主线程重入、跨线程回调、定时器延迟后到达的结果、真实定时器取消、构建源复制与缺失拒绝。

## 未执行和边界

NOT RUN：新增代码的完整 Mac SDK/Go/Swift 链接、真实 Adapter 运行、签名 Provider
回调、跨进程 Keychain 读取、可信描述符交付、握手/IPv4双出口/DNS/停止撤销。
停机期限只是错误报告界限，不能强制终止阻塞原生调用；延迟 OS 请求可能仍生效。
实际系统观察器、Provider 终止策略、依赖许可与可达漏洞审查仍是运行前门槛。

本轮不新增权限、工具安装、Go 版本或数据格式，不读/改用户 .conf、workspace、
Keychain、路由、DNS 或锁文件。开发签名继续暂停；首次真实连接前恢复。
恢复采用后继源码提交，不改写 main、不清空数据；交付为 main，不提供更新包。
