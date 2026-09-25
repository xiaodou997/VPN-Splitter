# LocalDev：本地配置草稿、规则与诊断开发版

任务 LD-01；不是可连接的 VPN 客户端。源码与离线测试已提供，macOS SDK 构建、ad-hoc 签名和窗口交互待真机验证。开发顺序见 [ADR-007](adr/ADR-007-localdev-before-signing.md)，结果见 [本轮证据](evidence/localdev-01.md)。

## 从 main 构建并打开

条件：Apple Silicon、macOS 26.0+、已选择的完整 Xcode / macOS SDK 26+。不用提供 Team ID、证书、provisioning profile 或真实 VPN 配置。

在仓库根目录执行；有未提交修改时先保留，不强制切换、reset 或 clean：

```sh
git switch main
git pull --ff-only
/bin/bash tools/localdev/build.sh run
```

只构建而不请求打开：

```sh
/bin/bash tools/localdev/build.sh build
```

脚本只构建 `apps/macos/LocalDev/VPN-Splitter-LocalDev.xcodeproj` 的独立 `VPN-Splitter-LocalDev` scheme，使用 `CODE_SIGN_IDENTITY=-` 的本地 ad-hoc 签名。它不调用 `tools/s1/build.sh`，不构建、嵌入或激活 Packet Tunnel，不复制到 Applications，不申请 root，不修改路由 / DNS。构建后检查签名及意外嵌入的扩展；检查失败不打开。`run` 中 open 返回成功只表示提出了打开请求，窗口是否正常仍需人工确认。

产物：

```text
.local/localdev/DerivedData/Build/Products/Debug/VPN-Splitter-LocalDev.app
.local/localdev/build.log
.local/localdev/signature.txt
```

成功时脚本结尾应包含：

```text
schema=localdev-build-v1
mode=run
exit_code=0
network_settings=NOT_APPLIED
extension_activation=NOT_REQUESTED
```

窗口顶部必须显示 **本地开发模式：不接管网络**。不要把旧的 `VPN-Splitter.app` unsigned 扩展工程当成这个开发版运行。已通过的 S1 preflight / unsigned 不必重做；`build.sh development` 暂不需要执行。

构建失败只检查这次的 `build.log`，不要通过关闭 Gatekeeper、SIP 或改变企业策略解决。反馈时给出失败阶段、错误片段和 Xcode 版本即可，先去掉用户名、私有路径及其他敏感内容；不要上传整个 `.local` 目录。

## 这一版能操作什么

| 页面 | 当前实现 | 明确没有实现 |
| --- | --- | --- |
| 配置 | 新建、重命名、删除多份策略草稿；Include / Bypass 与后端能力预设；本地保存 | `.conf` / `.ovpn` 导入、VPN 参数编辑、Keychain 凭据保存 |
| 规则 | 添加、编辑、启用 / 禁用、删除、上下移动；IP / CIDR 真实编译；保存暂不支持的规则草稿 | DOMAIN、后缀、IPv6、REJECT 的执行；不支持的启用规则不会被跳过 |
| 诊断 | 调用 PolicyCore 的规则意图预览、规则遮蔽说明、输入 IPv4 的命中解释 | 基础设施 / peer 校验、DNS 解析、网络探测、实际出口观察 |
| 模拟 | 连接中、成功、注入认证失败、取消、重试；拒绝迟到回调 | 真实认证、重连隧道、Network Extension、External 路由修改 |

WireGuard / OpenVPN / External 选择框只是编译能力预设，不证明后端可用。当前预览使用 `IPv4PolicyCompiler`，未接入基础设施 / peer 的约束编译阶段。所有结果只表示预期选路，不表示配置已完整、可连接或路由可直接安装。IPv6 未覆盖，不提供系统级 Kill Switch。

名称和规则编辑区需要点保存 / 添加。预览只使用已经保存的规则；编辑区尚未保存的文字不会影响它。任何成功保存、配置切换、删除或重新编译都会清掉旧预览并停止旧模拟。

## 首次真机验收：只用合成数据

1. 新建草稿，命名为“本地测试”；保留 WireGuard 预设与默认 DIRECT。规则页点“添加合成示例”。两条规则顺序为 `198.51.100.0/24 → VPN`、`198.51.100.7 → DIRECT`。
2. 编译预览，在诊断页解释 `198.51.100.7`。应显示预期 VPN、命中规则 1；后面的主机规则完全被遮蔽。把主机规则上移后重新编译，同一地址应为 DIRECT。这里不会访问该地址。
3. 添加一条启用的 DOMAIN 草稿并编译，应显示 `E_CAPABILITY_UNSUPPORTED`，不能留下旧的成功预览。禁用这条草稿后可重新编译。启用 REJECT 或 IPv6 也应被阻止；External + Include 同样拒绝。
4. 开始模拟后立刻取消，延迟结束后不应再次变成成功。勾选“下次模拟：认证失败”再开始，应显示模拟失败；取消勾选后重试应显示模拟成功，而非真实 VPN 已连接。模拟中保存或切换草稿应回到未开始。
5. 退出并重新打开，名称和规则顺序应保留，模拟状态应为未开始，旧预览不自动恢复。另建草稿，确认切换与删除确认框正常。

这是待执行的人工验收清单，不是已通过的记录。截图中可保留合成样例，但不要暴露真实业务网段或秘密。

## 数据、权限与恢复

草稿文件：

```text
~/Library/Application Support/VPN-Splitter-LocalDev/workspace.json
```

仅含名称、能力预设、默认动作与规则；不保存真实配置、凭据、诊断输入或模拟连接状态。普通文本字段不是秘密输入框，请勿粘贴私钥和密码。字段是单行且有长度限制，整个工作区限 2 MiB、100 份配置、每份 1000 条规则。

新建目录权限 0700，草稿文件 0600。保存经临时文件准备和原子替换；保存失败不会把失败编辑接纳到当前工作区。数据损坏、未来版本、读取失败或符号链接目标时启动会报错并禁止写入，**不会自动重置或删除原数据**。

恢复时先退出 LocalDev，在 Finder 的“前往文件夹”打开上述目录，先把 `workspace.json` 复制到安全的本地备份位置，再排查内容 / 版本 / 权限。确认需要空白工作区后，把原文件改为一个尚不存在的备份名称，再重启；不要删除整个 Application Support 或 `.local`。符号链接等异常先人工核查，不跟随删除其指向的数据。备份可能含私有规则，不上传公共 Issue。

不要同时启动多个独立实例编辑同一文件。本轮不提供跨进程锁、自动迁移或自动损坏恢复。删除草稿需确认，但没有撤销功能。LocalDev 数据目录与将来的正式 VPN 数据 / Keychain 边界分开。

## 可重复的离线测试

```sh
swift test --package-path Packages/AppCore -Xswiftc -warnings-as-errors
swift test --package-path Packages/AppCore -c release -Xswiftc -warnings-as-errors
python3 -m unittest discover -s tests/localdev -v
```

Python 只用于开发合同测试，不是产品运行依赖。上述测试不能替代 Xcode SDK 类型检查、Mac 文件行为、签名或 GUI 验收。原 PolicyCore、S0、S1 测试继续按各自规程执行，不因 LocalDev 自动关闭原阶段。

下一项 LD-02 / S1-03 是 WireGuard 配置结构解析、兼容报告、凭据安全边界与基础设施 / peer 校验的接入；不是现在恢复开发签名。首次真实 Managed 隧道联调前再恢复签名，发行签名、公证和 DMG 继续后置。
