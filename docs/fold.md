# 事件折叠规范

agent 不发送渲染结果，它发送 append-only 事件日志，每个客户端各自折叠成屏幕上的东西。

**折叠是纯函数**：`items = fold(events)`。同一串事件必须得到同一个结果，与分页边界、断线重连无关。

dsh 0.2 用 `session/follow` 送这份日志（`docs/dsh-0.2-protocol.md` §4）：先一个尾页**快照**，然后按 seq 递增、无缺口地推后续事件，另有不落盘的 `assistant-stream` 流式帧。follow 不能从某个位置续传，所以每次重连都会来一个新快照，**新快照整体替换窗口**（§4.1）。

本文档规定折叠的确切语义。参考实现 `ios/Rowel/Store/Conversation.swift`，回归测试 `ios/RowelTests/StoreTests.swift`（加载与重连在 `LoadingTests.swift`）。

- 状态：§1
- 事件信封：§2
- 逐事件规则：§3
- 快照与分页：§4
- projection：§5
- 乐观发送与排队：§6
- 工具卡片：§7
- 边界情况：§8

---

## 1. 状态

折叠器为**每个会话**维护：

| 字段 | 类型 | 说明 |
|---|---|---|
| `items` | `[ConversationItem]` | 转录，日志顺序 |
| `running` | bool | 在 `turn/start` 与 `turn/end` 之间 |
| `title` | string? | 来自 projection 或 `session/title` |
| `todos` | `[TodoItem]` | 来自 projection 或 `todo/write` |
| `queue` | `[QueuedMessage]` | 未被 agent 领取的消息，来自 `inbox` projection（§6.2） |
| `contextFraction` | double? | 上下文占用比例 |
| `planning` | bool | 是否在计划模式 |
| `modelName` | string? | 当前模型 |
| `hasMore` / `oldestSeq` / `cursor` / `loaded` | | 窗口游标：最早 seq、最晚 seq、有无更早页、快照是否已到 |
| `generation` | int | 每次窗口被替换加一；替换前发出的翻页请求据此作废 |

以及若干**内部状态**（不对外暴露）：

| 名称 | 用途 |
|---|---|
| `assistantIndex: [String: Int]` | `"turn.step"` → `items` 下标，流式气泡定位 |
| `toolIndex: [String: Int]` | callId → `items` 下标 |
| `seen: Set<Int>` | 已折叠的事件序号 |
| `projectionSeq: [String: Int]` | 每个 projection 键的水位线，**跨快照保留**（§5.1） |
| `streaming: (attemptId, turn, step)?` | 正在流式输出的那次尝试，来自 `start` 帧（§3.4） |
| `pending: [(id, text)]` | 乐观气泡，id 是发送时的 `requestId`（§6.1） |
| `provisional: [QueuedMessage]` | 机器还没列出的排队项，id 同上（§6.2） |

**任何插入或删除 `items` 中间元素的操作，都必须重建索引。**下标会移位，不重建会导致后续 chunk 拼进错误的气泡。

`ConversationItem` 是闭集：

```
user(UserTurn) | assistant(AssistantTurn) | tool(ToolCard) | notice(Notice)
```

---

## 2. 事件信封

follow 的 `event` 项、快照与翻页的 `records[]` 里，每条都是：

```json
{ "type": "tool/call", "seq": 1234, "time": 1700000000000, "data": { ... } }
```

| 字段 | 说明 |
|---|---|
| `type` | 事件类型，字符串 |
| `seq` | 会话内单调递增序号，从 0 开始 |
| `time` | 毫秒时间戳 |
| `data` | 类型相关载荷 |

### 2.1 去重

```
若 seq 已在 seen 中 → 丢弃整个事件
否则 → 记入 seen，cursor = max(cursor, seq)，继续折叠
```

dsh 0.2 的事件都有 seq，且从 0 开始，所以 0 也去重。

**这是更早的页可以与窗口重叠的原因。**重叠部分被静默丢弃。

### 2.2 未知类型

**必须**静默忽略，**禁止**渲染占位符或错误。

agent 的事件词汇是开放的——插件会加新类型。渲染未知事件会让每个装了插件的用户看到噪音。

已知的"只记日志不渲染"类型包括 `step/start`、`step/end`、`system/message`、`request/context`、`agent/inbox/spliced`（排队区读 `inbox` projection，它说的是同一件事的全量）、`approval/asked`、`approval/decided`，它们与"这个 build 之后才出现的类型"走同一条路径。

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
    detail = data.reason.error.message ?? data.reason.message ?? data.reason.failure.message
    若 detail 非空 → 追加 notice(id: "n<seq>", kind: .failure, text: detail)
```

0.2 的失败原因形如 `{kind: "error", error: {message, code}}`；取消是 `{kind: "aborted", reason: {kind: "user"}}`，没有 message，不出 notice。

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
images = 所有 type=="image" 且有 attachment.attachmentId 的 block（只有引用，字节按需用 session/attachment 取）

若 kind == "runtime-context" → 丢弃
    （机器每个 turn 前给模型的运行环境说明。不是谁说的话，画出来是每个回答前一页样板）

若 kind != "user"（注入的上下文：AGENTS.md、skill 正文、审批说明等）：
    追加 user(text: data.source.summary ?? text, synthetic: true)
    结束
    （它是真实的模型输入，隐藏会歪曲对话；但它不是人说的，
      所以必须标记，UI 渲染成可展开的一行灰字而非气泡）

若 text 与 images 皆空 → 丢弃

若 data.source.rpcId 存在（本机或别处发送时带的 requestId）：
    撤下 id 等于它的乐观气泡、provisional 排队项与 queue 里的同名项（§6）
追加 user(id: data.id ?? "u<seq>", text, images, synthetic: false)
```

### 3.4 流式帧（`assistant-stream`）

0.2 **不再持久化** `assistant/chunk`。模型的输出以 follow 上的 `assistant-stream` 帧到达（`docs/dsh-0.2-protocol.md` §4.2），落盘的只有之后的 `assistant/message`（或失败时的 `assistant/attempt`）。

```
start {attemptId, turn, step}   → streaming = (attemptId, turn, step)
chunk {attemptId, time, chunk}  → attemptId 必须等于 streaming.attemptId，否则忽略
                                   key = "<streaming.turn>.<streaming.step>"
                                   text-delta      → 定位/新建 key 的气泡，text += chunk.text
                                   reasoning-delta → 同上，reasoning += chunk.text
                                   其他            → 忽略（tool-call-delta 由随后的 tool/call 覆盖；
                                                      usage / finish / block-* 没有可渲染内容）
end {attemptId, outcome}        → streaming = nil
                                   outcome.kind == "abandoned" → 撤下该 key 下未完成的气泡
```

空字符串的 delta **必须**忽略（不新建气泡）。新建的气泡：`id = "a<turn>.<step>"`，`complete = false`。

`abandoned` 的尝试日志里什么都不留，所以它流出的文字必须撤下；`committed` 的那次，持久事件已先于 `end` 到达并替换了气泡（§3.5），`end` 不再做任何事。

App 把 chunk 攒一帧（33 ms）再一起折叠（`MachineSession.hold`），其他任何 follow 项到达前先把攒着的折完——结束这一步的消息不能越过构成它的文字。

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

### 3.6 `assistant/attempt`

一次没有提交成消息的尝试（失败、被重试取代）。撤下 `data.turn.data.step` 下未完成的气泡：重试会流进同一个 step，不撤的话新文字会接在失败那次后面。

### 3.7 `tool/call`

```
callId = data.callId          若缺失 → 丢弃
name   = data.name ?? "tool"
arguments = data.arguments ?? "{}"      （未解析的 JSON 字符串）
presentation = questionPresentation(name, arguments) ?? callPresentation(name, arguments)   见 §7

若 callId 已在 toolIndex → 原地替换（重发）
否则 → 追加 tool(running: true)
```

### 3.8 `tool/result`

0.2 的结果消息直接带内容：`data.message = {role: "tool", source: {kind: "tool", callId}, toolCallId, content: [...], isError}`。

```
callId = data.message.source.callId ?? data.message.toolCallId

若 callId 缺失，或 toolIndex 里没有它 → 丢弃，且**不记入 seen**
    （调用在更早的页上。凭空造一张没有上下文的卡片更糟；
      不占用 seq，是为了调用随后到达时，重发的结果还能落下）

card.running = false
card.failed  = (data.error 存在且非 null) 或 data.message.isError == true
card.resultText = 拼接 data.message.content[] 里的 text
若是提问卡 → 从 resultText 解析答案（§7.2）
否则 → card.presentation = resultPresentation(resultText, 当前 presentation)
```

### 3.9 `todo/write`

```
todos = data.todos[] 中每个有 content 且 status ∈ {pending, in_progress, completed} 的项
```

### 3.10 `session/title`

```
title = data.title ?? 保持原值
```

### 3.11 `request/header`

```
modelName = data.header.config.model ?? 保持原值
```

### 3.12 `command/run` 与 `command/done`

斜杠命令由客户端发起（`commands/execute`），机器把它的生命周期原样记进会话日志：`command/run` 在
handler 之前、`command/done` 在结算之后，两者都不包在 turn 里。所以命令的结果不用等回包，它自己会
沿着 follow 回来。

```
command/run:  running[data.commandId] = "/" + data.name + data.args      （记着，不画）
command/done: line = running.removeValue(forKey: data.commandId)
              text = [line, data.text].compactMap{}.filter{ !empty }.joined(" — ")
              text 非空 → 追加一条 notice（kind = data.kind == "error" ? .failure : .info）
```

**为什么要配对**：`command/done` 只有 `commandId` 和结果，没有产生它的那行字。不配对的话屏幕上只有
"preset read-only"，看不出是谁要求的。浏览器端跑的命令、或翻页加载进来的日志没有 `command/run`
可配，这时只显示结果那半句——那也是这个会话自己的记录，总比没有强。

### 3.13 `subagent/descriptor`

不画。只置一个"子代理列表过期"的标记，子代理面板下次打开时重新拉取。

---

## 4. 快照与分页

窗口按**消息**分页（`maxMessages`，app 取 25），但一页携带这些消息跨越的**全部事件**。

### 4.1 快照（`adopt`）

follow 的第一项。**整体替换**窗口，不与旧窗口拼接——这是 dsh 自己的客户端的做法，也是"重开即一致"成立的前提。

```
generation += 1
清空 items、索引、seen、command 配对、streaming        （projectionSeq 保留，见 §5.1）
按顺序折叠 records[].event
oldestSeq = 首条 seq；cursor = snapshot.cursor；hasMore = snapshot.hasMore
吸收 snapshot.projections（§5）
若有 assistantStream.activeAttempt → 续上那次尝试（见下）
把仍未被日志确认的乐观气泡（pending）追加回末尾
loaded = true
```

**续上正在进行的尝试**：快照里的 `activeAttempt = {attemptId, turn, step, stream[]}` 是重连时还在写的那一次。`streaming` 设为它；`stream[]` 是落盘格式的紧凑流：`text-chunks` / `reasoning-chunks` 的 `texts[]` 拼起来分别加进 text / reasoning，`chunk` 项按 §3.4 的 chunk 处理。随后的 chunk 帧接着往上写。

之前翻过的更早页随替换丢弃，需要时重新翻。

### 4.2 更早的页（`absorb`，来自 `session/page`）

请求 `{throughSeq: cursor, beforeSeq: oldestSeq}`：上界取窗口的 `cursor`，保证这一页和窗口读的是同一份日志。

**不能**直接倒序折叠——折叠只在追加顺序下正确。

```
1. 新建一个临时折叠器，按顺序折叠 records[].event
2. 把它的 items 中 **id 不在当前 items 里的**整体插到当前 items 前面
3. 重建索引
4. seen ∪= 临时折叠器的 seen
5. oldestSeq = min(oldestSeq, 首条 seq)；hasMore = page.hasMore
```

第 3 步是必须的：插入使所有下标右移，不重建的话一条实时 chunk 会拼进错误的位置（或新建重复气泡）。

翻页请求发出后若窗口被替换（`generation` 变了），这一页丢弃。

### 4.3 帧上限

快照或某一页超过隧道的单帧上限时，Bridle 回 `too-large`；app 把 `maxMessages` 减半重开（快照）或重取（翻页），直到放得下。这是 `MachineSession` 的事，折叠器不感知。

---

## 5. projection

projection 是 agent 算好的派生状态，三条路到达：

- 快照里的 `projections`：`{ asOfSeq, values: { key: value } }`
- `session/control` 流：每次打开先给 `baseline`（所有已挂载会话各自一块 `{asOfSeq, values}`），之后逐键 `projection {sessionId, key, value, seq}`
- `session/projections` 一元调用（模型、子代理目录等按需读取，不经折叠器）

### 5.1 水位线

```
若 projectionSeq[key] 存在且 > seq → 丢弃
否则 → projectionSeq[key] = seq，应用
```

`session/control` 与 `session/follow` 是两条独立的流，谁先到没有保证。**陈旧的值禁止覆盖较新的值**——所以替换窗口时水位线**保留**，否则一个较旧的快照会把 control 先送到的新值（排队、标题）改回去。

本机改名（`retitle`）直接改 `title`，不经水位线：给本地猜测抬高水位，会压住 Mac 上之后的每一次改名。

### 5.2 已折叠的键

| key | 效果 |
|---|---|
| `title` | `title = value` |
| `todos` | 同 §3.9 |
| `contextPressure` | `window = value.contextWindow`；`used = value.projectedTokens ?? value.pressureTokens`；`window > 0` 且 `used` 存在时 `contextFraction = min(1, used/window)`，否则置 nil。另外原样留下 `contextTokens = used`、`contextWindow = window`——"83%" 和 "830k / 1M" 回答的不是同一个问题 |
| `plan` | `planning = (value.mode == "plan") 或 (value.active == true)` |
| `sessionStats` | `stats = SessionStats(value)`。`ttftMs` 是**总和**、`ttftSteps` 是次数，平均值要自己除；`ttftSteps == 0` 时返回 nil 而不是 0 |
| `tokenUsage` | `tokens = TokenUsage(value)`。`cacheHitRate` 在没有任何输入时返回 nil——"还没请求过"和"每次都没命中"是两件事，用 0% 表达前者是错的 |
| `contextBreakdown` | `contextBreakdown = ContextBreakdown(value)`（system / tools / messages 三段） |
| `permissions` | `permissions = PermissionChoice(value)`。0.2 的值只有 `currentValue`，**不带可选项**；可选项取自机器的 `permissionPresets/catalog`（`offer(presets:)`），两者谁先到都能补齐。**是会话级的**：机器从该会话自己的日志折叠出来，改一个会话不影响别的。机器级的默认档位是 settings 里 `permission.defaultPreset`，只决定新会话的起点。`custom` 只在当前旋钮不匹配任何 preset 时出现，是显示状态、不是可切换目标，`PermissionChoice.choices` 把它过滤掉 |
| `inbox` | 排队区，见 §6.2 |
| 其他 | 忽略 |

### 5.3 尚未折叠的键

数据已在传输中，加一个 case 即可用（无需新请求）：

`goal` · `turnOutline` · `agentPreset` · `userQuestions` · `subagentCatalog` · `subagent` · `subagentTiming` · `modelSelection` · `sessionListMetadata` · `imageLimits`

其中 `modelSelection` 与 `subagentCatalog` 已由 `Harness.models` / `Harness.subagents` 经 `session/projections` 读取，只是不进折叠器。

> `scripts/check-docs.mjs` 从上面两个小节**解析**键名再比对代码，不是手抄一份清单。这一条本身就是被这个 bug 教出来的：早先脚本里硬编了 §5.3 九个键中的三个，于是折叠另外六个中的任何一个，检查都不会响。

---

## 6. 乐观发送与排队

发送时立即上屏，不等 agent 回音。每次发送都带一个新铸造的 `requestId`，dsh 把它记在消息上（`source.rpcId`）——这是乐观副本与真实消息之间唯一可靠的对应。

### 6.1 乐观气泡（`pending`）

发给空闲会话、或 steer 进正在运行的 turn 时，消息马上就是转录的一部分：

```
showPending(text, id = requestId):
    pending += (id, trim(text))
    追加 user(id, text, synthetic: false)

收到 source.rpcId == id 的 user/message → 从 pending 与 items 删除该 id，重建索引，再追加真实消息
发送失败（确定没送出）→ dropPending(id)
```

agent 铸造自己的消息 id，与客户端的永不相同；**按 `rpcId` 匹配，不按文本**。别处（webui、另一台手机）发来的消息 rpcId 不同，即使文字一样也不会误吃。

快照替换窗口时，`pending` 里还没被日志确认的条目追加回末尾——那条消息还在路上。

> 这条规则是从一个真实 bug 来的：早期按 id 匹配，两者永不相等，导致**每一条消息都在屏幕上出现两次**。0.1 没有 rpcId，只能按文本匹配；0.2 起改为精确匹配。测试 `testTheRealMessageReplacesTheOptimisticOne` 与 `testRepeatedTextClearsOneBubblePerEcho` 守着它。

### 6.2 排队区（`inbox` + `provisional`）

排队（`mode: "queue"`）发给正在运行的会话时，消息还没对模型说出口，不该画成转录里的气泡，而是放进底部的排队条：

```
showQueued(text, id = requestId): provisional += 项；queue += 项

inbox projection {next-step: [...], next-turn: [...]}：
    listed = next-step 的每条（placement "steering"）+ next-turn 的每条（placement "queued"）
             id = 消息 id，text = 拼接 content 里的 text
    provisional 中 id 出现在任何一条的 source.rpcId 里的 → 移除
    queue = listed + 剩下的 provisional
```

`inbox` 是全量，所以替换而不是合并——只有本机发出、机器还没列出的那几条保留。真实 `user/message` 到达（§3.3）也会撤下同 rpcId 的 provisional 与 queue 项：机器把它说出口就是领取，不依赖可能在重连中错过的那次 `inbox` 更新。

---

## 7. 工具卡片

0.2 的 follow 与 page **不再附 `view`**（README："the controller does not resolve a Tool definition, run a presenter, or attach UI data"）。卡片由客户端按**工具名与参数**选，闭集是：

```
generic(title, kind, detail)
terminal(command, cwd, output, exitCode)
diff(title, files[{path, oldText, newText}])
search(title, lines[], truncated, total)
read(path, lines[{number, text}], totalLines)
question(items, answers)
```

### 7.1 call 时（`callPresentation(name, arguments)`）

`arguments` 解析失败按空对象处理。

| 工具 | 卡片 |
|---|---|
| `bash` | `terminal(command: command, cwd: workdir)` |
| `edit`（有 `file_path`） | `diff(title: file_path, files: [{file_path, old_string, new_string}])` |
| `write`（有 `file_path`） | `diff(title: file_path, files: [{file_path, nil, content}])` |
| `grep` / `glob` | `search(title: pattern, lines: [])` |
| `read` / `read_image` | `generic(title: file_path, kind: "read")` |
| `web_fetch` | `generic(title: url, kind: "fetch")` |
| `web_search` | `generic(title: queries[0], kind: "search", detail: 多条时全部列出)` |
| 其他（含插件新加的） | `generic(title: 工具名, detail: description / file_path / path / pattern / url / name 中第一个非空的)` |

### 7.2 result 时（`resultPresentation(resultText, 当前)`）

| 当前卡片 | 规则 |
|---|---|
| `terminal` | 沿用 command 与 cwd，`exitCode` 取结果末尾的 `[exit code: N]` 标记；输出由视图直接显示 `resultText` |
| `search` | `lines` = `resultText` 的非空行，`total` = 行数 |
| `question` | `ask_user_question` 的答案是结果里的 JSON `{"answers":[{id, selected, custom?}]}`，失败时不解析 |
| 其他 | 不变，`resultText` 原样显示在卡片里 |

`ask_user_question` 在 call 时就是提问卡：参数里的 `questions[]` **每一条**都能读出时才用提问卡，有一条读不出就退回 generic——一张漏掉问题的卡片比原样显示参数更糟。

### 7.3 不认识的工具

**必须**画成 `generic`，**禁止**丢弃或崩溃，并且保留完整的参数（卡片可展开查看）与结果文本。客户端不需要知道每个工具做什么，但不能把它吞掉。

---

## 8. 边界情况

实现**必须**处理下列每一条。括号内为对应测试。

| 情况 | 正确行为 |
|---|---|
| 同一 seq 到达两次 | 第二次丢弃（`testDuplicateSequenceIsIgnored`） |
| 未知事件类型 | 静默（`testUnknownEventIsSilent`） |
| 只调工具的一步（空 assistant 消息） | 不留空气泡（`testEmptyAssistantStepLeavesNoBubble`） |
| 孤儿 `tool/result`（调用在更早页上） | 丢弃（`testOrphanResultIsIgnored`）；调用随后到达时结果仍能落下（`testAnUnplacedResultCanLandWhenItsCallArrives`） |
| turn 无最终消息就结束 | 气泡与卡片都置为完成，失败原因成一条 notice（`testTurnEndCompletesStreamingBubbles`） |
| `turn/end` 且 `reason.kind == "completed"` | 不产生 notice（`testSuccessfulTurnEndAddsNoNotice`） |
| 尝试被放弃（`abandoned`） | 撤下它流出的文字（`testAnAbandonedAttemptIsTakenDown`） |
| 失败后重试同一 step | 新尝试从空气泡开始（`testARetriedAttemptStartsAFreshBubble`） |
| 没见过 `start` 的 chunk | 忽略（`testChunksWithoutTheirStartAreIgnored`） |
| 结束这一步的消息紧跟在 chunk 后 | 先折完 chunk，再替换（`testStreamedTextFoldsBeforeTheMessageThatEndsIt`） |
| 快照中途打开 | 续上正在写的尝试（`testASnapshotResumesTheAttemptInFlight`） |
| 重连的新快照 | 整体替换窗口，仅保留还在路上的乐观气泡（`testASnapshotReplacesTheWindow`） |
| prepend 之后来了实时 chunk | 拼进正确的气泡（`testPrependKeepsLiveStreamingCoherent`） |
| projection 乱序 | 高 seq 胜出（`testStaleProjectionIsDropped`），快照不改回 control 的新值（`testASnapshotDoesNotPutBackAnOlderProjection`） |
| 注入的上下文 | 标 synthetic，显示 summary（`testSyntheticUserMessageIsMarked`） |
| runtime-context 消息 | 不显示（`testRuntimeContextIsNotShown`） |
| `source.kind == "tool"` 的 user 消息 | 丢弃（`testToolSourcedUserMessageIsDropped`） |
| 乐观气泡与真实回音 | 按 rpcId 合并为一条（`testTheRealMessageReplacesTheOptimisticOne`） |
| 相同文本发两次 | 各自按自己的 rpcId 消掉（`testRepeatedTextClearsOneBubblePerEcho`） |
| 发送失败后又收到同 rpcId | 不受影响（`testAFailedSendLeavesNoGhost`） |
| 排队项被机器列出 / 被说出口 | provisional 让位（`testTheInboxReplacesTheProvisionalEntry`、`testAClaimedMessageLeavesTheQueueStrip`） |
| 权限 projection 只有当前档位 | 可选项从目录补齐（`testAccessChoicesComeFromTheCatalog`） |
| 真 dsh 0.2 的一段录制 | 折叠结果与 webui 一致（`testARecordedFollowFoldsIntoWhatTheWebUIShows`） |

---

## 附：最小实现顺序

从零写一个客户端折叠器，建议顺序：

1. 信封解析 + `seq` 去重 + 未知类型静默 → 此时能安全消费任何日志
2. 快照整体替换 + `user/message` + `assistant/message` → 能看到对话
3. `assistant-stream` 帧 → 流式，含 abandoned 撤回与 activeAttempt 续上
4. `tool/call` / `tool/result` + generic 卡片 → 能看到工具
5. `turn/start` / `turn/end` → 状态正确
6. 更早的页（prepend + 重建索引）
7. projection（含跨快照保留的水位线）
8. 乐观发送（按 rpcId）与排队区
9. 按工具名的具体卡片

每一步都可独立测试，且都对应 `StoreTests.swift` 里的一组用例。
