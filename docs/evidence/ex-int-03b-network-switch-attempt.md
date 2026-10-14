# EX-INT-03B 切网协调样本

2026-09-30。用户先切到热点并连接 VPN；只读 0/1+128.0/1 和目标 utun8，Helper noRecovery。实际单目标 ADD/readback 后 en0；随后通知用户切回原 Wi-Fi。

18:24:05.929 Helper 记录 closed/code=none/owned0/comparison=unchanged/cleanup=none，GUI DELETE reason=none/mutation_attempts=2，目标回 utun8。用户随后回复已切回；再次 audit noRecovery、目标 utun8。

没有取得足以证明网络切换发生在活动租约内的时间证据；返回相同接口名也不能证明物理网络未改变。有限 configd 时间窗口查询无匹配事件，不能据此断言没有切换。因此本次只确认会话安全结束及用户切网后的 noRecovery，T-E09 活动分流切网保持 NOT VERIFIED，不用自然到期样本冒充网络变化触发撤销。未延长 60 秒租约、未重连 VPN、未执行网络 reset。后续应在同一单调时钟记录物理路径变化和事务终态，并缩短现场协调延迟。

## 同步采样工具

新增 tools/external/watch-network-transition.py：只读 ipconfig 的物理地址/router 和目标 route GET，记录同一系统单调时钟下的采样起止、物理路径是否变化、目标路径类别。地址和网关仅驻内存，不输出明文或哈希；输出独占创建 0600，时长限制 1..120 秒，无写路由或恢复操作。物理信息不可读记 unknown，不当成已切换；相同地址/router 的不同接入网络无法靠此证明切换。

本机 2 秒冒烟取得 8 个样本，物理信息均可读、无变化、目标 tunnel、文件权限 0600。该验证只证明观测工具可运行，不是活动切网通过。下一次将先建立基线，再与 GUI apply/active 的 monotonic_ns 时间戳对齐；用户准备确认后才启动有限租约。

## 同步记录复验

实际 apply 前 monotonic_ns=532395216219333，active 确认=532399808408291。只读观察覆盖 apply 前约 3.89 秒至后约 85.97 秒，未观察到物理地址/router 改变或不可读。Helper 18:45:29.288 closed/none/owned0/unchanged/cleanup=none；GUI DELETE reply_type2/mutation_attempts2，后续恢复核查 noRecovery。用户报告已切到热点，但观测窗口不能证实实际路径变化与 active 重叠，仍 NOT VERIFIED；不推断用户未切换，也不把接口类别等同 Wi-Fi 身份。停止重复聊天往返式限时协调；下一次应采用本机提示或经确认的本机切网操作，使动作与租约共享同一执行流程，不延长安全租约。
