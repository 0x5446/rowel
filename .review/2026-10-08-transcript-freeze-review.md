# Deep Review — 会话页卡死修复 + 问题卡片

- Repo: /Users/alpha/workspace/rowel-wt-q
- HeadSHA: aabd964c1a269a0c0f50fb4b957ad90125dd234d（审查对象：commit aabd964）
- RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-rowel-wt-q-aabd964-1791463224.F3Yx
- 引擎：codex（personal 配置），实际模型 gpt-6-luna，effort xhigh，provider commandcode
- 维度：correctness、goalfit、maintainability、conventions、concurrency（信号触发）；cursor 未登录，跳过
- 模式：默认（Phase 1 + Phase 2 回证）
- 说明：goalfit 首轮没读到 context/diff，输出作废后重跑一次，以重跑结果为准

## VERDICT: NEEDS_FIX → 修复后无未解决的 Critical

审查结论是 NEEDS_FIX（3 条 Warning，0 条 Critical），3 条都经过源码回证（VERIFIED）。处理如下。

## 🔴🔴 顶级必修（高共识 + 已回证）

### 1. iOS 17 上滚回底部后不会恢复跟随 — 已修
- 来源：correctness ISSUE_1（0.97）+ goalfit ISSUE_2（0.98，R4 部分兑现）；回证 VERIFIED
- 位置：ios/Rowel/Views/ConversationView.swift `TailAnchor` 的 iOS 17 分支
- 问题：到底检测只在 iOS 18（`onScrollPhaseChange`）里有；`FollowState.drag` 又不再在上滑时恢复跟随。最低系统是 iOS 17.0，那里只有"回到底部"按钮能恢复跟随。
- 修复：只在 iOS 17 分支保留原来的规则（上滑 = 底部来迎读者，调用 `reachedEnd()`）；iOS 18 不变。FollowState 文档同步。
- 验证：编译通过、352 个单元测试通过。本机没有 iOS 17 运行时，这条分支没能实机验证。

### 2. 多次"加载更早消息"后，VStack 的布局行数没有上限 — 接受，记为已知取舍
- 来源：maintainability ISSUE_1（0.97）+ goalfit ISSUE_1（0.98）；回证 VERIFIED
- 位置：ios/Rowel/Views/ConversationView.swift `transcript(_:)`
- 问题：分页只限制每页请求的条数，不限制已加载的总数；成本随加载行数线性增长。
- 决定：本次不修。理由：这是线性变慢，不是卡死（模拟器上 360 行首次布局 520 ms），而且要连续点很多次"加载更早消息"才会到这个量；窗口化回收是独立且有风险的改动。原代码注释"paging keeps bounded"不准确，已改写为如实描述。PR 里列为已知代价，后续单独跟进。

## 🔴 高置信（单来源 + 已回证）

### 3. 提问参数里有一项坏掉时，卡片会漏掉这道题 — 已修
- 来源：goalfit ISSUE_3（0.99，R6 部分兑现）；回证 VERIFIED
- 位置：ios/Rowel/Store/Conversation.swift `questionPresentation(name:arguments:)`
- 修复：所有题目都能解析才显示问题卡片，否则退回通用卡片；新增测试 `testQuestionWithOneUnreadableItemStaysGeneric`。

## Suggestion

- conventions ISSUE_1：`StreamFollowsTests` 头部注释仍把列表写成懒加载 — 已改。

## 各维度判定

| 维度 | VERDICT | 说明 |
|---|---|---|
| correctness | NEEDS_FIX | 第 1 条 |
| goalfit | NEEDS_FIX | 第 1、2、3 条；R1、R2、R3、R5、R7、R8 已兑现 |
| maintainability | NEEDS_FIX | 第 2 条 |
| conventions | SAFE | 1 条 Suggestion |
| concurrency | SAFE | 无发现 |
