# Deep Review — M1：隧道 v2，透传 dsh 0.2 的接口

- Repo: /Users/alpha/workspace/rowel-wt-m1
- HeadSHA: 537a5493ddbd194e5cb25b8ae6cb636a084e0bfe（审查对象：commit 537a549）
- RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-rowel-wt-m1-537a549-1791531649.ptPO
- 引擎：codex，配置 `work`（~/.codex-profiles/work），模型 gpt-6-sol，effort high（owner 指定）
- 维度：correctness、goalfit、maintainability、conventions、security、concurrency；cursor 未登录，跳过
- 规模警告：diff 6717 行，超过 3000 行提示阈值
- Phase 2：未派独立回证进程。全部 C/W 由作者逐条对照源码确认成立（无误报）后修复，修复后用单测、e2e 与真实 dsh 验证

## VERDICT: NEEDS_FIX → 全部修复；一条 Suggestion 按设计留到 M4

0 条 Critical。去重后 13 组：

| # | 问题 | 来源 | 处理 |
|---|---|---|---|
| 1 | `$export` 下载中途断开 → 未处理的 Promise 拒绝，可让进程退出（存量） | correctness、goalfit | `handleCall` 捕获并作为调用失败返回；`abort`/隧道关闭时把信号传给下载与读流 |
| 2 | dsh 断线期间旧的等待请求残留，可能误振铃 | correctness、concurrency | 断线或 `$events` 结束时立即清空等待集合并通知；`rung` 保留到新一代重发窗口结束；`identify` 期间再次断线不开 `$events` |
| 3 | 同一 sid 重复 `open`：手机以为原流结束，原流仍在 | correctness、goalfit | 两条一起关闭（取消原流 + 一个 `error`），规格 §4.1 同步 |
| 4 | 慢消费者按共享缓冲判定，误伤别的流/别的手机；中继侧积压不可见 | correctness、goalfit、concurrency | 只在直连（每手机一条 socket）提供缓冲量；写完一项后超限则切断这条流；中继路径不判定、由 Relay 限额兜底；规格 §4.5 写明 |
| 5 | 帧上限只按明文算，临界帧仍会断整条隧道（存量） | goalfit | 计入 Noise 标签 16 字节与 mux 头 5 字节；边界测试 |
| 6 | 超大的流错误帧被丢弃，手机上的流等不到结束 | concurrency | 改发简短的 `too-large` 错误 |
| 7 | 契约测试"断线重发只出现一次"可在去重失效时通过 | correctness、goalfit、maintainability、concurrency | 先确认首发已落库，再断开重连、无条件用同一 requestId 重发，断言只有一条 |
| 8 | prompt 契约只排除参数错误，未断言失败原因是缺凭据 | goalfit、maintainability | 增加缺凭据的正向断言 |
| 9 | 共享连接断线（`failAll`）没有真实测试 | maintainability | 新增 `bridle/tests/remote-mux.test.js`（真实 WebSocket 断线、每流恰好一次 `upstream-lost`、重连后可再开、取消后不再通知） |
| 10 | 每周任务把安装/构建失败也报成接口漂移 | goalfit、conventions | 只有契约步骤失败才开 issue |
| 11 | 每周任务在装第三方包的任务里持有 `issues: write` | security | 拆为只读测试任务（`persist-credentials: false`，产出结果 artifact）+ 不运行第三方代码的报告任务；报告按标签设并发组防重复开单 |
| 12 | 超时报成 `internal`，规格写 `timeout`（存量） | correctness | 区分取消、超时、连接失败 |
| 13 | 设计稿仍写 `ready.api`；参考手机注释称 Swift 已迁移 | conventions | 设计稿 D6/D7/M1 改为握手协商版本 2；注释更正 |

Suggestion（未修，按设计 M4）：SECURITY.md 仍描述旧的续传/截断发现机制（conventions ISSUE_4）。

## 验证

- `npm test`：185 通过（含 check:docs）
- CI 的 e2e（approval / waiting / wake）：17 通过
- 对真 dsh 0.2.0-rc.2（contract / tunnel / direct / security / cli）：35 通过，1 个需模型的按设计跳过
