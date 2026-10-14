# PolicyCore 1,000 条规则原生编译基线

日期：2026-09-30。对应 docs/test-plan.md 第 10 节纯编译指标。参考机 Mac14,2 / Apple M2 / arm64；Apple Swift 6.4，-O / Swift 6 / warnings-as-errors。此样本不访问网络、凭据或系统路由，不代替运行后端性能。

## 可复现入口

```sh
swiftc -O -swift-version 6 -warnings-as-errors -parse-as-library Packages/PolicyCore/Sources/PolicyCore/*.swift tools/policy/benchmark.swift -o .local/external/policy-benchmark
.local/external/policy-benchmark
```

工具直接编译真实 PolicyCore 源码。固定种子 20260930、排列后的 1,000 个相邻 /24、混合 DIRECT/VPN、External bypass 默认 VPN。生成夹具和结果校验不计入计时，测量包括策略校验与编译。每条规则网络地址的 first-match 决策与独立解释器一致；每次结果与参考计划一致。输出 724 routes / 1,016 effective regions。

预热 10 次，正式 100 次，nearest-rank P95 为排序第 95 项：

| 指标 | 毫秒 |
| --- | --- |
| 中位数（第 50 项） | 2.015 |
| P95 | 2.392 |
| 最大值 | 2.734 |

本固定样本 P95 <=100 ms：PASS。不覆盖所有重叠/稀疏最坏输入、约束编译器、域名/应用 Flow 策略、冷启动、DNS、吞吐或 2 小时资源稳定性。首次工具编译发现 throwing 调用不能放在 precondition autoclosure，已修复后重新编译运行；产品源码未改。
