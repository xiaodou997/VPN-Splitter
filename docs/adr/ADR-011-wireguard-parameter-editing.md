# ADR-011：WireGuard 参数编辑与凭据安全换绑

日期：2026-09-25。状态：Accepted（用户授权继续既定配置编辑开发；原生验证另行记录）。任务 LD-03A、S1-03 部分；延续 ADR-008/009/010，不关闭真实隧道门槛。

## 决策

在一个可取消的编辑事务内调整接口 Address、DNS 地址、ListenPort、MTU，以及各 Peer 的 Endpoint、PersistentKeepalive。复用导入器的格式和资源上限。Peer 数量、身份与顺序、AllowedIPs、预共享密钥标记、DNS 搜索域不在本轮编辑范围，始终从基线保留；密钥更换仍用显式重新导入。参数编辑不是执行网络设置，也不会写回原 .conf。

格式合法但超出当前规划能力的 IPv6、主机名端点、空接口/端点等可以保存结构，兼容提示必须显示，后续约束检查仍拒绝，不删字段制造部分成功。保存不等于检查或认证；保存后清除旧预览与模拟 token。

没有凭据的策略仅原子保存工作区。有关联凭据时不能只改 JSON，否则旧 Keychain 中的精确结构绑定失效；必须以旧引用和旧结构校验原记录，在 vault 内保留所有密钥创建一个新的随机引用记录，读回比对，然后发布新结构/新引用，最后显式清理旧项。不存在直接覆盖或 plaintext fallback。

准备记录先落盘；任何 create/授权/读回/最终保存失败都保留原策略和旧引用，以及新引用的待清理记录。原凭据不可读、归属或结构不匹配则失败，不清空凭据。清理重试仅处理已记录引用、不枚举 Keychain；编辑窗口中允许明确重试清理，保留未保存输入。无实质变化不触碰 Keychain 或磁盘。

完整策略基线、当前选择和磁盘工作区都必须匹配。编辑期间背景操作、其他编辑、导入及普通退出不能并发执行保存；原生调用在工作线程执行。参数编辑的退出提示只允许继续编辑或明确放弃，先在编辑器保存再退出，不在 applicationShouldTerminate 内异步开始凭据写入。强退、掉电和不遵守 advisory lock 的外部进程不在保证范围。

## 不变边界与参考

工作区仍为 v1/v2/v3，Keychain envelope 仍为 v1；不增加系统权限、依赖、联网或扩展能力，不恢复开发签名。密钥只在 vault 内短时用于新记录，Swift 内存副本不保证零化；本轮不声称同一用户竞态安全或跨存储原子事务。

WireGuard 字段语义参照官方 [wg(8)](https://git.zx2c4.com/wireguard-tools/about/src/man/wg.8)。本轮沿用项目已有导入子集，并非支持所有 wg-quick 指令。Keychain 延续 [SecItemCopyMatching](https://developer.apple.com/documentation/security/secitemcopymatching(_:_:)) 的定向查询与后台调用，不扩展 ACL 或访问组。

实际测试、失败恢复和 Mac 未验项见本轮 LD-03A 证据；模拟 vault 不等于 Security.framework 行为已通过。
