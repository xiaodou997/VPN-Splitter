# 第三方 VPN：External 开发入口

当前批次 EX-INT-01：原 VPN 保持连接，应用读取本机网络并预览指定 IPv4 的 DIRECT 例外。**还不能应用规则、改变实际流量或撤销路由；目前没有路由写入。** 这是独立的 External 开发应用，不是 `dev.sh run` 的 LocalDev，也不是 WireGuard Runtime。

## 更新和运行

在原项目目录执行：

```bash
git pull --ff-only
/bin/bash dev.sh external-test
/bin/bash dev.sh external-run
```

`external-test` 是合成/离线回归，不运行本机网络采集。`external-run` 编译并打开 ExternalPreview.app，只用本机 ad-hoc 标识，不需要 Apple Development 证书、VPN 扩展授权或 Go。仍需现有 macOS 26+、Apple Silicon、Xcode/Swift 与 Python 开发环境；不会安装工具或下载依赖。只编译不打开时使用 `dev.sh external-build`。

构建目录为 `.local/external/build.*`，失败查看该次 build.log 的首个错误；不要清空缓存、锁或原配置。代码不改 WireGuard，已有 WG 构建证据不会因此失效。不需要执行 `provider-build --sign`。

## 页面操作

由你继续使用原客户端连接 VPN，再点击“检测当前网络（只读）”。页面列出物理服务/网关候选、IPv4 隧道接口线索、路由记录数及动态存储中 IPv4 DNS 地址数。有多出口、多个隧道或未知格式会显示原因，不自动选择。

在文本框每行输入一个需要直连的 IPv4 或 CIDR，最多 64 条，点击“重新检测并预览直连规则”。每次都重新采集，不复用上一次网关。结果显示拟议目标、物理网关、接口，以及“拟增加，未执行”或“已有直连，不认领、不删除”。局域网、本机、观察到的 DNS 和保留地址受保护；已有路由冲突时整个预览失败，不自动裁剪规则。

这只是 Bypass：保留全局 VPN + 指定直连例外，不是默认直连/仅部分目标 VPN，不是按应用分流。预览不是实际选路证明。尚未检测厂商/登录身份、VPN 端点、过滤器、enforceRoutes、完整系统代理或企业策略；不保证任意第三方客户端可分流。

没有应用按钮；关闭或退出该预览不会断开原 VPN。取消/重新检测会丢弃旧结果，编辑规则清理旧预览，睡眠/唤醒清理观察；结果最多保留 30 秒。它不是实时监视器，网络变化后要重新检测。原始网络内容只在本机内存与页面中，不自动保存、上传或复制到剪贴板。截图/日志可能含内网地址，应先遮盖后分享。

## 下一批

EX-INT-02 接有限权限执行和可确认撤销：真正让目标走直连、其他目标保持原 VPN，并在停止时只清理本会话可确认的修改。需要另行完成权限/身份、当前网络复核、操作应答/状态读回和恢复；不能拿本预览当授权。OpenVPN 的 .ovpn 导入/兼容性检查已提前到后续队列，本批还没有实现。

[ADR](adr/ADR-EX-INT-01-external-first.md) · [本批证据](evidence/ex-int-01-discovery-preview.md) · [路线图](roadmap.md)
