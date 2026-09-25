# ADR-008：LocalDev 单编辑事务与分层界面

> 本文记录 UI 批次；后续导入与存储变更见 ADR-009 / ADR-010。当前整合状态见 [main 证据](../evidence/localdev-main-integration.md)。

日期：2026-09-25。状态：Accepted（用户批准按交互审查继续修复）；实现离线通过，Mac UI 验证未完成。
关联：LD-UI-01–04、S4-04 前置、T-U02–U05。补充 ADR-007，不改变网络架构、产品保证或 S0–S5 门槛。

## 决策

编辑缓冲由 App 级模型持有，不由可替换的策略详情视图持有。名称 / 模式与规则分别通过一个模态编辑入口保存。同一时刻只允许一个事务，背景策略切换、规则开关、排序等写入入口同时在 UI 与模型层禁止操作。

AppCore 的 DraftEdit 记录策略基线、事务 ID 与待保存字段。保存前比较当前内存中的完整策略，防止旧副本覆盖后来的启用状态、删除或排序；选中的策略不同、目标不存在或标识被改动时拒绝保存。其他策略的变更保留，不用旧工作区整体覆盖。这个保守策略可能拒绝同一策略内互不影响的并发改动，优先避免静默合并错误；不宣称跨进程并发安全。

DraftEditor 在写入成功后才关闭缓冲；验证 / 文件写入失败保持输入和已接受工作区。取消有改动时要求显式放弃，输入恢复到原值可直接关闭。已保存 JSON 不增加字段、版本不变。正常退出使用相同脏状态检查；强制退出、崩溃或断电不承诺恢复未保存缓冲。

主流程缩为策略 → 规则 → 检查。模式使用中文目的描述，但不自动改写已有规则动作。模拟、能力预设、未支持类型及技术路由细节折叠。常驻“不接管网络”，不以折叠信息提升功能保证。已有未支持草稿可见、可编辑 / 禁用，启用时继续由真实 PolicyCore 拒绝检查。

错误展示采用静态中文说明、规则编号与稳定 ID；不字符串化任意 Error 或回显错误输入。保留错误码供本地技术检查。规则和策略删除均需明确确认，尚无撤销功能。

## 平台集成与验证

SwiftUI sheet 使用 interactiveDismissDisabled，编辑通过保存 / 取消退出；NSApplicationDelegate 的 applicationShouldTerminate 与应用退出菜单共用检查。AppKit 仅用于正常退出提示，不是网络或权限后端。原生 modal / 菜单 / Dock 退出和关闭重开窗口的交互仍须实机测试，不能由纯逻辑测试推断全部正常。

Apple API 参考：
- https://developer.apple.com/documentation/swiftui/view/interactivedismissdisabled(_:)
- https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:)

没有新增第三方依赖、权限、entitlement、系统网络 API 或签名要求。原工程、构建入口、PolicyCore、DraftStore 与 LocalSession 保持不变。证据和剩余缺口见 [本轮记录](../evidence/localdev-ui-02.md)，操作见 [LocalDev](../localdev.md)。
