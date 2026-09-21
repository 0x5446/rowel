# 事件折叠规范

agent 不发送渲染结果，它发送 append-only 事件日志，每个客户端各自折叠成屏幕上的东西。

**折叠是纯函数**：`items = fold(events)`。同一串事件必须得到同一个结果，与到达顺序、分页边界、断线重连无关。

本文档规定折叠的确切语义。参考实现 `ios/Rowel/Store/Conversation.swift`，回归测试 `ios/RowelTests/StoreTests.swift`。

- 状态：§1
- 事件信封：§2
- 逐事件规则：§3
- 分页：§4
- projection：§5
- 乐观发送：§6
- 渲染意图：§7
- 边界情况：§8

---

## 1. 状态

折叠器为**每个会话**维护：

| 字段 | 类型 | 说明 |
|---|---|---|
| `items` | `[ConversationItem]` | 转录，日志顺序 |
| `running` | bool | 在 `turn/start` 与 `turn/end` 之间 |
| `title` | string? | 来自 projection |
| `todos` | `[TodoItem]` | 来自 projection 或 `todo/write` |
| `queue` | `[QueuedMessage]` | 未被 agent 领取的消息 |
| `contextFraction` | double? | 上下文占用比例 |
| `planning` | bool | 是否在计划模式 |
| `modelName` | string? | 当前模型 |
| `hasMore` / `oldestSeq` / `loaded` | | 分页游标 |

以及三个**内部索引**（不对外暴露）：

| 索引 | 用途 |
|---|---|
| `assistantIndex: [String: Int]` | `"turn.step"` → `items` 下标，流式气泡定位 |
| `toolIndex: [String: Int]` | callId → `items` 下标 |
| `seen: Set<Int>` | 已折叠的事件序号 |
| `projectionSeq: [String: Int]` | 每个 projection 键的水位线 |
| `pending: [(id, text)]` | 乐观气泡，见 §6 |

**任何插入或删除 `items` 中间元素的操作，都必须重建索引。**下标会移位，不重建会导致后续 chunk 拼进错误的气泡。

`ConversationItem` 是闭集：

```
user(UserTurn) | assistant(AssistantTurn) | tool(ToolCard) | notice(Notice)
```

---

## 2. 事件信封

```json
{ "type": "assistant/chunk", "seq": 1234, "time": 1700000000000, "data": { ... } }
```

| 字段 | 说明 |
|---|---|
| `type` | 事件类型，字符串 |
| `seq` | 会话内单调递增序号 |
| `time` | 毫秒时间戳 |
| `data` | 类型相关载荷 |

### 2.1 去重

```
若 seq != 0 且 seq 已在 seen 中 → 丢弃整个事件
否则 → 记入 seen，继续折叠
```

`seq == 0` 视为"无序号"，不去重也不记录。

**这是分页与实时流可以重叠的唯一原因。**一页历史盖住实时流的一段时，重叠部分被静默丢弃。

### 2.2 未知类型

**必须**静默忽略，**禁止**渲染占位符或错误。

agent 的事件词汇是开放的——插件会加新类型。渲染未知事件会让每个装了插件的用户看到噪音。

已知的"只记日志不渲染"类型包括 `step/start`、`step/end`、`request/context`、`session/end-seed`，它们与"这个 build 之后才出现的类型"走同一条路径。

---

## 3. 逐事件规则

### 3.1 `turn/start`

```
running = true
```

### 3.2 `turn/end`

```
running = false
完成所有未完成的流式内容（见下）
若 data.reason.kind 存在且不是 "success" / "completed"：
    detail = data.reason.message ?? data.reason.failure.message
    若 detail 非空 → 追加 notice(id: "n<seq>", kind: .failure, text: detail)
```

**"完成所有未完成的流式内容"** 指：

- 每个 `complete == false` 的 assistant 气泡 → `complete = true`
- 每个 `running == true` 的工具卡 → `running = false`

turn 可以在没有最终消息的情况下结束（取消、provider 报错）。留一个还在闪光标的气泡等于宣称答案还在路上。

### 3.3 `user/message`

```
kind = data.source.kind ?? "user"

若 kind == "tool" → 丢弃
    （工具结果通过 tool/result 到达；出现在这里是屏幕上已有卡片的重复）

blocks = data.content[]
text   = 拼接所有 type=="text" 的 block 的 text
images = 所有 type=="image" 且有 attachment.attachmentId 的 block

若 kind != "user"（注入的上下文：AGENTS.md、skill 正文、文件变更通知）：
    追加 user(text: data.source.summary ?? text, synthetic: true)
    结束
    （它是真实的模型输入，隐藏会歪曲对话；但它不是人说的，
      所以必须标记，UI 渲染成可展开的一行灰字而非气泡）

若 text 与 images 皆空 → 丢弃

清理匹配的乐观气泡（§6）
追加 user(id: data.id ?? "u<seq>", text, images, synthetic: false)
```

### 3.4 `assistant/chunk`

```
turn = data.turn ?? 0，step = data.step ?? 0，key = "<turn>.<step>"
kind = data.chunk.type

text-delta      → 定位/新建 key 对应的气泡，text += data.chunk.text
reasoning-delta → 同上，reasoning += data.chunk.text
其他            → 忽略
    （tool-call-delta 由随后的 tool/call 覆盖；
      usage / finish / block-* 没有可渲染内容）
```

空字符串的 delta **必须**忽略（不新建气泡）。

新建的气泡：`id = "a<turn>.<step>"`，`complete = false`。

### 3.5 `assistant/message`

同一 `turn.step` 的最终消息。**替换**流式气泡，不追加第二份。

```
blocks    = data.message.content[]
text      = 拼接 type=="text"
reasoning = 拼接 type=="reasoning"

若 text 与 reasoning 皆空：
    删除该 key 的气泡（若存在），重建索引
    结束
    （只调了工具的一步。工具卡片承载了它，空气泡只是一道缝）

否则：定位/新建气泡，设 text、reasoning，complete = true
```

### 3.6 `tool/call`

```
callId = data.callId          若缺失 → 丢弃
name   = data.name ?? "tool"
arguments = data.arguments ?? "{}"
presentation = callPresentation(view.view, view.for, name, arguments)   见 §7

若 callId 已在 toolIndex → 原地替换（重发）
否则 → 追加 tool(running: true)
```

### 3.7 `tool/result`

```
block  = data.message.content[0]
callId = data.message.source.callId ?? block.toolCallId

若 callId 缺失，或 toolIndex 里没有它 → 丢弃
    （调用在更早的历史页上。凭空造一张没有上下文的卡片更糟）

card.running = false
card.failed  = (data.error 存在且非 null) 或 block.isError == true
card.resultText = 拼接 block.content[] 里的 text
若 view.for == "result" → card.presentation = resultPresentation(view.view, 当前 presentation)
```

### 3.8 `todo/write`

```
todos = data.todos[] 中每个有 content 且 status ∈ {pending, in_progress, completed} 的项
```

### 3.9 `request/header`

```
modelName = data.header.config.model ?? 保持原值
```

### 3.10 `command/run` 与 `command/done`

斜杠命令由客户端发起（`commands/execute`），机器把它的生命周期原样记进会话日志：`command/run` 在
handler 之前、`command/done` 在结算之后，两者都不包在 turn 里。所以命令的结果不用等回包，它自己会
沿着重放路径回来。

```
command/run:  running[data.commandId] = "/" + data.name + data.args      （记着，不画）
command/done: line = running.removeValue(forKey: data.commandId)
              text = [line, data.text].compactMap{}.filter{ !empty }.joined(" — ")
              text 非空 → 追加一条 notice（kind = data.kind == "error" ? .failure : .info）
```

**为什么要配对**：`command/done` 只有 `commandId` 和结果，没有产生它的那行字。不配对的话屏幕上只有
"preset read-only"，看不出是谁要求的。浏览器端跑的命令、或事后翻页加载进来的日志没有 `command/run`
可配，这时只显示结果那半句——那也是这个会话自己的记录，总比没有强。

---

## 4. 分页

历史按**消息**分页（`maxMessages`），但一页携带这些消息跨越的**全部原始事件**。

### 4.1 尾页（`prepend = false`）

按顺序折叠每个 `events[].event`，`view` 取 `events[].view`。

```
oldestSeq = min(oldestSeq ?? 首条seq, 首条seq)
hasMore   = page.hasMore
若 page.projections 存在 → 吸收（§5）
loaded    = true
```

### 4.2 更早的页（`prepend = true`）

**不能**直接倒序折叠——折叠只在追加顺序下正确。

```
1. 新建一个临时折叠器
2. 用它以 prepend=false 折叠这一页
3. 把它的 items 整体插到当前 items 前面
4. 重建索引
5. seen ∪= 临时折叠器的 seen
```

第 4 步是必须的：插入使所有下标右移，不重建的话一条实时 chunk 会拼进错误的位置（或新建重复气泡）。

### 4.3 瘦身

Bridle 会剥掉**已提交消息**的 `assistant/chunk`（同一 `turn.step` 已有 `assistant/message`）。

对折叠语义**无影响**：committed 消息的完整内容在 `assistant/message` 里；未提交那条的 chunk 会被保留。

客户端**禁止**依赖 chunk 一定存在。

---

## 5. projection

projection 是 agent 算好的派生状态，两条路到达：

- 历史页里的 `projections` 基线块：`{ asOfSeq, values: { key: value } }`
- 实时 `session/projection` 帧：`{ key, value, seq }`

### 5.1 水位线

```
若 projectionSeq[key] 存在且 > seq → 丢弃
否则 → projectionSeq[key] = seq，应用
```

重连时实时帧可能先于历史基线到达。**陈旧的值禁止覆盖较新的值。**

### 5.2 已折叠的键

| key | 效果 |
|---|---|
| `title` | `title = value` |
| `todos` | 同 §3.8 |
| `contextPressure` | `window = value.contextWindow`；`used = value.projectedTokens ?? value.pressureTokens`；`window > 0` 且 `used` 存在时 `contextFraction = min(1, used/window)`，否则置 nil。另外原样留下 `contextTokens = used`、`contextWindow = window`——"83%" 和 "830k / 1M" 回答的不是同一个问题 |
| `plan` | `planning = (value.mode == "plan") 或 (value.active == true)` |
| `sessionStats` | `stats = SessionStats(value)`。`ttftMs` 是**总和**、`ttftSteps` 是次数，平均值要自己除；`ttftSteps == 0` 时返回 nil 而不是 0 |
| `tokenUsage` | `tokens = TokenUsage(value)`。`cacheHitRate` 在没有任何输入时返回 nil——"还没请求过"和"每次都没命中"是两件事，用 0% 表达前者是错的 |
| `contextBreakdown` | `contextBreakdown = ContextBreakdown(value)`（system / tools / messages 三段） |
| `permissions` | `permissions = PermissionChoice(value)`（`options[]` + `currentValue`）。**是会话级的**：机器从该会话自己的日志（`permission/preset` + `sandbox/mode` + `approval/policy`）折叠出来，改一个会话不影响别的。机器级的是另一个东西——settings 里 `permission.defaultPreset`，只决定新会话的起点，两者共用一个取值词表。`options` 里的 `custom` 只在当前旋钮不匹配任何 preset 时出现，是显示状态、不是可切换目标，`PermissionChoice.choices` 把它过滤掉 |
| 其他 | 忽略 |

### 5.3 尚未折叠的键

数据已在传输中，加一个 case 即可用（无需新请求）：

`subagent` · `subagentTiming` · `goal` · `sessionListMetadata` · `imageLimits`

形状见 `docs/architecture.md` §3.2。

> `scripts/check-docs.mjs` 从上面两个小节**解析**键名再比对代码，不是手抄一份清单。这一条本身就是被这个 bug 教出来的：早先脚本里硬编了 §5.3 九个键中的三个，于是折叠另外六个中的任何一个，检查都不会响。

---

## 6. 乐观发送

发送时立即上屏，不等 agent 回音。

```
showPending(text, id):
    pending += (id, trim(text))
    追加 user(id, text, synthetic: false)

发送失败：
    dropPending(id) → 从 pending 和 items 中删除，重建索引
```

### 6.1 与真实回音的合并

agent 铸造自己的消息 id，**与客户端铸造的乐观 id 永不相同**。因此不能按 id 匹配。

```
收到 kind=="user" 的 user/message 时：
    在 pending 中找第一条 text == trim(收到的 text) 的记录
    找到 → 从 pending 移除，从 items 删除该 id 的项，重建索引
    然后再追加真实消息
```

**按最早匹配**：人不可能乱序发送同样的内容。

> 这条规则是从一个真实 bug 来的：早期按 id 匹配，两者永不相等，导致**每一条消息都在屏幕上出现两次**。测试 `testTheRealMessageReplacesTheOptimisticOne` 与 `testRepeatedTextClearsOneBubblePerEcho` 守着它。

### 6.2 不匹配时

来自别处（webui、另一台手机）的消息**不会**误吃乐观气泡，因为文本不同。文本恰好相同时会误吃一条——代价是一次显示合并，不会丢内容，可接受。

`reset()` **必须**清空 `pending`。

---

## 7. 渲染意图

agent 在事件旁附 `view`，host 已算好这个工具该怎么画。

```json
{ "for": "call" | "result", "view": { "card": "terminal", ... } }
```

客户端翻译成闭集：

```
generic(title, kind, detail)
terminal(command, cwd, output, exitCode)
diff(title, files[{path, oldText, newText}])
search(title, lines[], truncated, total)
read(path, lines[{number, text}], totalLines)
```

### 7.1 call 时

```
若 for != "call" 或 view 缺失 或 view.card 缺失 → generic(title: 工具名)
terminal → terminal(command: view.title ?? 名, cwd: view.cwd, output: nil, exitCode: nil)
diff     → diff(title, files: view.diffs)
其他     → generic(title, kind: view.kind, detail: view.rawInput 的可读化)
```

### 7.2 result 时

**`title` 缺省意味着"沿用 call 时定下的"**，所以此函数必须接收当前 presentation，而不是整个替换。

| card | 规则 |
|---|---|
| `terminal` | 沿用 command 与 cwd，填入 `output` 与 `exitCode` |
| `diff` | 替换 files |
| `search` | `shape == "paths"` 时取 `paths[]`；否则把 `files[].matches[]` 摊平成 `"<path>:<line>  <text>"` |
| `read` | `lines[{number, text}]`，**保留文件原行号** |
| `web` | `kind=="fetch"` → generic(detail: `"<status>  <url>"`)；否则 generic(detail: answer + sources) |
| 其他 | generic，沿用旧 title/kind，`view.content[]` 有内容则取之 |

### 7.3 未知 card

**必须**降级为 `generic`，**禁止**丢弃或崩溃。

但"不崩溃"不等于"支持"。降级时**必须**：

1. 保留完整的原始渲染意图（结构化载荷，不只是标题）
2. 保留结果文本
3. **明说这个版本画不了它** —— 例如"这个工具的展示需要更新 Rowel"

第 3 条不是礼貌，是正确性。未知 card 可能带着位置信息或**可执行的动作**，降级成一张只读的通用卡片会让人以为"就这些了"，而实际上有操作被吞掉了——那正好重新制造这个品类的第二痛点（手机端只能看不能做）。

> 这与 `architecture.md` §12 的能力协商是同一条原则：**能力缺失要明说，不能静默降级。**早期版本这两处互相矛盾，deep review 指出后统一到"明说"。

**客户端永远不需要知道某个具体工具做什么**——但需要知道自己画不了它。

---

## 8. 边界情况

实现**必须**处理下列每一条。括号内为对应测试。

| 情况 | 正确行为 |
|---|---|
| 同一 seq 到达两次 | 第二次丢弃（`testDuplicateSequenceIsIgnored`） |
| 未知事件类型 | 静默（`testUnknownEventIsSilent`） |
| 只调工具的一步（空 assistant 消息） | 不留空气泡（`testEmptyAssistantStepLeavesNoBubble`） |
| 孤儿 `tool/result`（调用在更早页上） | 丢弃（`testOrphanResultIsIgnored`） |
| turn 无最终消息就结束 | 气泡与卡片都置为完成（`testTurnEndCompletesStreamingBubbles`） |
| `turn/end` 且 `reason.kind == "success"` | 不产生 notice（`testSuccessfulTurnEndAddsNoNotice`） |
| prepend 之后来了实时 chunk | 拼进正确的气泡（`testPrependKeepsLiveStreamingCoherent`） |
| projection 乱序 | 高 seq 胜出（`testStaleProjectionIsDropped`） |
| 注入的上下文 | 标 synthetic，显示 summary（`testSyntheticUserMessageIsMarked`） |
| `source.kind == "tool"` 的 user 消息 | 丢弃（`testToolSourcedUserMessageIsDropped`） |
| 乐观气泡与真实回音 | 合并为一条（`testTheRealMessageReplacesTheOptimisticOne`） |
| 相同文本发两次 | 一次回音消一条（`testRepeatedTextClearsOneBubblePerEcho`） |
| 发送失败后又收到同文本 | 不受影响（`testAFailedSendLeavesNoGhost`） |

---

## 附：最小实现顺序

从零写一个客户端折叠器，建议顺序：

1. 信封解析 + `seq` 去重 + 未知类型静默 → 此时能安全消费任何日志
2. `user/message` + `assistant/message` → 能看到对话
3. `assistant/chunk` → 流式
4. `tool/call` / `tool/result` + generic 渲染意图 → 能看到工具
5. `turn/start` / `turn/end` → 状态正确
6. 分页（先尾页，再 prepend + 重建索引）
7. projection
8. 乐观发送与合并
9. 各种具体渲染意图

每一步都可独立测试，且都对应 `StoreTests.swift` 里的一组用例。
