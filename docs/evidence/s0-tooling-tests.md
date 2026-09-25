# S0 工具离线测试记录

日期：2026-09-23。任务：S0-01/S0-02 辅助工具。状态：PASS（仅下述离线检查），macOS/VPN 真机检查 NOT RUN。

## 环境

Linux x86_64；GNU bash 5.2.37；mawk 1.3.4；Python 3.13.5。没有使用 macOS SDK、Network Extension、签名、有效 VPN 配置或宿主网络修改权限。脚本按 Bash 3.2 兼容语法编写，但**未声称已在 Apple Bash 3.2 上运行**。

## 实际执行

```sh
/bin/bash -n tools/s0/collect-network.sh
python3 -m unittest discover -s tests/s0 -v
```

结果：语法检查通过；27 项 unittest 测试通过。输入地址均为内联合成数据；成功/失败/缺命令/超时和中断测试使用本机 echo/false/sleep 等无害子进程。真正的采集命令没有在 Linux 上执行，静态分发以测试函数记录参数；非 Darwin 环境的直接采集被拒绝。

覆盖：IPv4 合法/非法输入与参数数量；不回显敏感参数；只读命令分发与停止条件；父目录符号链接拒绝；输出 mode 600；失败/超时/中断；同网关同隧道的成对 /1；不同网关/接口、残缺、重复、多 default、scoped/reject/blackhole/down 路由；未知格式与无输入；原始字段不出现在共享摘要；失败路由采集保持 UNKNOWN。

历史快照的 before/after 另做实际离线识别，结果见 [S0 基线](s0-baseline.md)，未把私有快照提交为夹具。

## 未执行与限制

未运行 macOS 26 arm64 采集、Apple Bash/awk 的原生测试、真实系统目录权限检查、ACL/磁盘满、真实网络抖动或系统命令卡死、Developer ID 构建、VPN 连接/分流/恢复、安装卸载、GitHub Actions。单元测试中的 mock/子进程结果不能替代上述检查。

本记录的 27 项是工具回归测试，不是 docs/test-plan.md 中 63 个产品验收用例的通过数。工具不提供兼容判定，也没有修改系统路由/DNS。
