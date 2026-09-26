# WG-INT-07：Provider 会话控制与一次性配置交付

本批把真实 Adapter 的 start/stop 调用接入会话控制器，不新增模拟场景。
**代码已进入编译候选；正式扩展还没有启用，应用仍不能连接 VPN。**

## 已有路径与本批新增

```text
可信配置提供者（生产 Keychain 读取/跨进程授权仍待接入）
  -> 一次性 WireGuardConfigurationDelivery（进程内对象，不是 IPC 格式）
  -> 完整身份核对 -> ManagedWireGuardAssembly / PolicyCore
  -> WireGuardAdapter.start / stop
  -> ProviderSessionController 的结果与清理状态
```

加载取消/超时后迟到的配置不启动；启动过程中取消不会假装底层启动已被取消，
而是撤销绑定并等回调结束后再停机。期限检查使用单调时钟，迟到的定时器调度
不能让过期回调重新授权连接。未知原生错误只向上层返回静态错误码。
停止成功只表示后端不再活动；系统路由/DNS 是否撤销仍需另行观察。
无回调或失败显示 cleanupUnconfirmed，不自动重试、不在旧实例换配置。

配置提供者必须验证原 Keychain 记录的归属/引用/结构；填写 UUID 并不能获得
授权。Delivery 仅消费一次，不写 JSON、日志、options 或应用消息；原生内存
中仍会有引擎所需密钥，不承诺零化全部 Swift/Go 副本。LocalDev vault 不变，
没有悄悄把本地 ad-hoc 凭据变成正式扩展共享条目。

## 验证入口

新源码和 ProviderSession 库已由现有 engine 命令加入探针，拉取后验证这批原生
接线仍只需：

```sh
git switch main &&
git pull --ff-only &&
/bin/bash dev.sh engine --fetch
```

它不调用新 start/stop、不运行探针、不访问 Keychain 或建立隧道。仅缓存构建
仍可省略 --fetch；没有新安装要求或历史更新包。Git 冲突时停止，不强制覆盖。
成功仍以 compile_link=PASS 为准；provider=NOT_LINKED 是当前真实边界。
离线入口 dev.sh engine-test 加入 ProviderSession Debug/Release，不要求 Go；
其中原生驱动 harness 使用明确的替身，不能代替 Mac SDK 或真实 VPN 测试。

## 剩余工作

下一项不是重新做界面，而是正式 Provider 的配置/凭据来源、可信隧道资源交付
与系统回调/撤销观察。真实握手、IPv4 双出口、DNS、停止恢复及 OpenVPN 尚未通过。
开发签名按约定在首次真实连接前恢复。本轮不改变 LocalDev 界面（仍 LD-03B）、
工作区和凭据版本，不修改原 .conf。48eee07 的首次 Mac PASS 保留为独立证据。
实际已执行和未执行范围见 [证据](evidence/wireguard-session-07.md)。
