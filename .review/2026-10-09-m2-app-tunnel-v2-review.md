# Deep Review — M2：iOS app 改说隧道 v2 / dsh 0.2

- Repo: /Users/alpha/workspace/rowel-wt-m2
- HeadSHA: b5493ffaab4d056d0112910f22182a61d897cb22（审查对象：commit b5493ff，相对 main）
- RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-rowel-wt-m2-b5493ff-1791544242.EVCJ
- 引擎：codex 0.157.1，配置 `work`（~/.codex-profiles/work），实际模型 gpt-6-sol / llm_proxy / effort high（owner 指定）
- 维度：correctness、goalfit、maintainability、conventions + 信号 concurrency；cursor 未登录，跳过
- 规模：73 文件 +13285/−2254，其中约 10.7k 行是新增的录制 fixtures（diff 中只列文件名）；去掉 fixtures 35 文件 +2572/−2241
- Phase 2：5 条独立回证进程（覆盖全部 correctness 发现，其余维度的 Warning 与之配对共享结果），5/5 VERIFIED，0 误报；其余单来源 Warning 由作者对照源码确认

## VERDICT: NEEDS_FIX → 已修复（见下）；R12 的真模型验收留给 owner 决定

0 条 Critical。去重后 9 组：

| # | 问题 | 来源 | 回证 | 处理 |
|---|---|---|---|---|
| 1 | 列表重连未按 D4：事件与 `session/list` 并行，旧列表可覆盖较新的增删/状态；上一连接的读取还会让新连接的读取被跳过 | correctness、goalfit、maintainability、conventions、concurrency | VERIFIED | `$events` 每收到 `ready` 起一代列表同步：期间的 `api-session/*` 列表变化不应用、只记"脏"，读完若脏则补读一次，以后读为准；代次号防旧读落地；`$events` 本身失败时仍会读列表。测试：交错到达时补读且不被旧列表覆盖；安静时只读一次 |
| 2 | 快照清空投影序号，旧快照可把 `session/control` 先送达的较新值（排队、标题）改回去 | correctness、concurrency | VERIFIED | `adopt` 保留投影水位；测试两条流反序到达 |
| 3 | dsh 重启但隧道未断时旧审批/提问卡不撤；作答失败无条件写回旧卡，可能盖住新一代重发的卡 | correctness、concurrency | VERIFIED | `.harness(false)` 与每个新 `ready` 都清卡和 `clientId`；作答失败只在仍是同一 client、且该位置没有新卡时恢复 |
| 4 | `timeout`/`internal` 等暂时性流错误（含 dsh 的 `gateway/internal`，如 follow 跳号）后流就停了，隧道在线不会有握手来恢复 | correctness | VERIFIED | 机器流与 follow 对这些错误按 1s 起翻倍、30s 封顶退避重开，收到数据即复位 |
| 5 | 翻更早历史遇 `too-large` 不减半，错误被吞 | correctness | VERIFIED | 与快照同样减半重试；非连接类失败在会话里显示原因 |
| 6 | 作答 `$events/result` 的参数没有 iOS 单测 | maintainability | 作者确认 | 新增审批、提问的完整参数断言，以及失败恢复/换代不恢复的测试 |
| 7 | `Harness.prompt` 注释称同 requestId 重发安全，与已知去重竞态矛盾 | conventions | 作者确认 | 注释改为：用于对上乐观副本；结果不明时对照日志，不重发 |
| 8 | `docs/architecture.md` §6 仍描述 v1 帧与重放 | conventions | 作者确认 | 节首加"已过时"说明并指向 protocol.md §4；完整重写留在 M4 |
| 9 | R12：模拟器验收未用真模型看完整流式回答；too-large 单测只断言减半后的第二次请求 | goalfit | 作者确认（部分） | 已补"翻页减半后成功显示"的测试。流式、too-large 减半后打开、dsh 重启后审批卡恢复并作答成功，已在模拟器上用假 dsh 时间线验证（截图）；对真 dsh 0.2 的 FlowTests 5/6 通过（失败项为目录选择器，M3）。真模型流式需要花模型额度，未做，待 owner 决定 |

## Suggestion（未处理）

- 重录 fixtures 时随机 id 与时间戳会产生大量无关 diff（maintainability）。现阶段 fixtures 只随 CI 钉住的 dsh 版本重录，暂不做跨文件 id 映射。

## 修复后的验证

- iOS 单测全量 368/368 通过（新增 10 个）
- `npm test` 185/185、e2e 56 通过 5 跳过（需 `ROWEL_E2E_MODEL=1`）、check-docs 通过（修复前跑过，修复只动 iOS 与文档）

## 维度元信息

| 来源 | VERDICT | issues | exit |
|---|---|---|---|
| dim-correctness | NEEDS_FIX | 5 W | 0 |
| dim-goalfit | NEEDS_FIX | 2 W | 0 |
| dim-maintainability | NEEDS_FIX | 2 W + 1 S | 0 |
| dim-conventions | NEEDS_FIX | 2 W + 1 S | 0 |
| dim-concurrency | NEEDS_FIX | 3 W | 0 |
