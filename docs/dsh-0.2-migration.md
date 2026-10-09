# 迁移到 dsh 0.2（设计，2026-10-03；2026-10-08 按 0.2.1-alpha.1 复核）

状态：**设计稿，待评审**。线协议的事实依据见 [`dsh-0.2-protocol.md`](dsh-0.2-protocol.md)（带源码出处与实测标记）；0.1 的旧接口见 [`dsh-api-inventory.md`](dsh-api-inventory.md)。

## 0. 为什么要做

实测确认（2026-10-03）：**dsh 从 0.1.2（2026-09-03 发布）起，Rowel 就连不上了**，0.1.7-rc.2 与 0.2.0-rc.2 都已验证：

1. **认证**：所有 `/api` 请求（含 loopback）都要一个签名 cookie，只能用 dsh 启动时打印的一次性 token 换取。Bridle 不带凭据，一律 401。
2. **接口**：旧的点号方法（`/api/session.list` 等）全部删除（404），换成 `POST /api/<ns>/<method>` + `{args:{…}}`，参数名必须精确匹配。
3. **事件**：`WS /api/events.mux|events.host` 删除，换成单条 `WS /api/remote.mux` 上的多路流（`open/item/end`），会话同步改为 `session/follow` 快照 + `session/page` 分页，审批改走 `$events` 流 + `POST /api/$events/result`。
4. **桌面端**：官方 Electron 版用系统分配的随机端口，token 只经 IPC，Bridle 的端口探测找不到它。

npm 上 `@deepseek-ai/dsh` 的 `latest` 已是 0.2.0-rc.2，所以**今天新装 dsh 的人都用不了 Rowel**。CI 从不跑真 dsh，这件事没人发现。

复核（2026-10-08）：npm 上最新的是 `alpha` 0.2.1-alpha.1，也是公开仓库 `deepseek-ai/deepseek-harness` 的最新提交。本设计依赖的接口在它和 rc.2 之间没有变化，唯一要处理的是启动时打印的 URL 不再保证是 loopback（见 D2）。证据见协议参考开头的复核说明。

决定（2026-10-03，owner）：**app 和 Bridle 一起改成新接口**，不做兼容旧协议的翻译层。

## 1. 目标与非目标

**目标**

- Rowel（app）+ Bridle 在 dsh **≥ 0.2.0** 上恢复现有全部功能：会话列表与工作区、打开会话（尾页快照 + 向上翻页）、流式文字与思考、工具卡片、发送（含排队、steer、取消、图片）、审批与提问、斜杠命令与技能、模型选择、权限预设、子代理只读视图、搜索、归档、重命名、分叉、推送唤醒。
- 支持 `dsh web`。
- 加一道防线：CI 里跑真 dsh 的契约测试，dsh 再改接口时我们第一天就知道。

**非目标（本次不做，列入后续）**

- dsh 0.2 的新功能：后台任务（`job/*`）、定时任务（`schedule/*`）、Goal、工作区文件浏览、文件上传（非图片）、置顶、账号余额。迁移完成后按价值逐个加，每个都是"app 调新端点"，Bridle 不用动（见 D3）。
- 继续支持 dsh ≤ 0.1.1。那条线由现有的 Bridle 0.1.x + app 1.0 覆盖，不再改。
- 桌面端（Electron 版 dsh）。插件路径在设计上同样适用于 `desktop` profile（端口与 token 都由 `ctx` 给出），但本机没装、没实测，本次不承诺；有人用时再验证并补 `bridle plugin install` 对 `desktop` profile 的写入。
- 给旧 app（1.0）专门的"请更新"提示。见 D6。

## 2. 关键决策

### D1. 只支持 dsh ≥ 0.2.0

0.1.2–0.1.7 是 0.2 的过渡版本，接口还在变（0.1.7 已有 `ns/method`，但方法集与 0.2 不同），没人会停在那里。Bridle 0.2 拿到认证后读 **真实版本号**（`pluginManager/listBundles` 里 `name` 为 `@deepseek-ai/dsh-base` 那一项的 `version`；插件模式下也可读宿主包版本；自起 dsh 时用 `dsh --version`），低于 0.2.0 就明确提示"请升级 dsh"或"请继续用 Bridle 0.1.x"。**401 只说明"需要认证"，不是版本判据**——0.1.2 起所有版本都回 401（0.1.7-rc.2 已实测）。不带 cookie 时 `POST /api/session.list` 回 200 只用来认出 ≤0.1.1；版本读不到时提示"无法确认兼容性"，不推断为 0.2。无论哪种情况都不再静默超时、也不再试图另起一个 dsh 去抢 3080 端口。

### D2. 认证：插件为主，自起 dsh 时抓 token，只有这两条

可选路径（事实见协议参考 §1.7）：

| 路径 | 结论 |
|---|---|
| (a) Bridle 作为 dsh 插件运行，用 `ctx.connection.authenticatedUrl()` + `ctx.webServer.port` | **主路径**。官方接口、零配置；端口由 dsh 直接告诉我们，不用探测 |
| (b) Bridle 自己启动 dsh 时读 stdout 里的 `dsh web: …?token=` 行，换成 cookie | **保留**，给不装插件、由 Bridle 拉起 dsh 的独立模式用（现有 `ensureDsh` 改为管道读 stdout）。**只取 `token` 参数**，换 cookie 时请求 `http://127.0.0.1:<Bridle 指定的端口>/?token=…`，不跟随打印出来的 host：0.2.1 起用户可在 profile 里配 `publicUrl`，那一行会变成反代地址。Bridle 拉起 dsh 时也不传 `--public-url` |
| (c) 用户已在跑的 `dsh web`（没装插件）：让用户贴一次带 token 的 URL，换 cookie 存进 `~/.rowel` | **不做**（owner 决定，2026-10-09）。cookie 绑定 `host:port`，要按端口分别保存、端口一变就得让用户重贴，代码与体验都不划算。这种情况下 Bridle 明确提示"运行 `bridle plugin install`，然后重启 dsh"，不静默重试 |
| (d) 读 `$DSH_HOME/.credentials.yaml` 的签名密钥自己签 cookie | **不用**。可行但不是官方接口，格式一变就静默失效，正是这次要避免的那种耦合 |

插件安装：`@rowel/bridle-plugin` 没发布到 npm，现在靠在 `profiles/web/cordis.patch.yml` 写本地绝对路径。新增 `bridle plugin install|uninstall`，在 `web` profile 里写入/移除这一行，指向 `~/.rowel/src/dsh-plugin/lib/index.js`；安装脚本装完提示运行它。本地路径插件条目在 rc.2 与 0.2.1-alpha.1 上都已实测可用（写进 profile 补丁文件、或用 `--patch` 覆盖层，插件都拿到 `port` 与 `authenticatedUrl`），不再是风险项；M0 只把它列入回归检查。将来 dsh 若不再接受本地路径，再评估发布到 npm（需要 npm 组织 `@rowel`，人工一次）。

### D3. 隧道协议 v2：Bridle 成为认证网关，app 直接说 dsh 的新接口

app 与 Bridle 之间的 Noise 隧道照旧，帧换成 dsh 的原生形态：

| app → Bridle | Bridle 做什么 |
|---|---|
| `call {id, endpoint, args}` | `POST /api/<endpoint>`（带 cookie），把 `server-response` 原样回给 app |
| `open {sid, endpoint, args}` / `item` / `cancel` / `end` | 在 Bridle 自己的那条 `remote.mux` 上开对应的流，`streamId` 做一层映射，`item/end/error` 原样回给 app |

理由：

- **以后加功能只改 app。**dsh 每加一个端点，app 直接调，Bridle 不用跟着发版。这次的教训正是 Bridle 夹在中间翻译一套会变的接口。
- **Bridle 变薄。**去掉方法表、事件折叠、历史瘦身、重放缓冲（见 D4），剩下认证、隧道、多路复用、推送。
- **不做端点白名单。**已配对的手机本来就拥有与 Mac 终端同等的权限（SECURITY.md 已写明），白名单挡不住任何实际风险，却会让每个新端点都要 Bridle 发版。

代价与对策（owner 决定，2026-10-09）：dsh 再改接口时，修复要靠 **app 发版**，过 App Store 审核要几天；若由 Bridle 翻译，Bridle 发版、用户重跑安装命令几分钟就恢复。选透明转发，是因为翻译层要随 dsh 的每次变化同步改，而且每个新功能都得 app 与 Bridle 一起改；这次断掉正是夹在中间的翻译跟不上 dsh。对策是**提前量**：D8 每周对 dsh 的 `@alpha` 跑契约测试，接口变化在进入 `@latest`（默认安装）之前就被发现，留出 app 先发版的时间。

保留的边界：

- **流归属**：每条转发的流记在开它的那条手机隧道名下；隧道关闭时 Bridle 立即 `cancel` 它名下全部流，重连后由 app 重新订阅，不留孤儿流。在途的一元调用同样中止（断开对 dsh 的那个 HTTP 请求）：0.2.1 起 `session/list` 会随连接断开而取消，手机走了就不再白算。
- **背压**：每条流的待转发队列设上限（按字节）；手机太慢导致超限时，取消这条流并给 app 一个可恢复的错误（app 重开即可），不让 Bridle 内存无限增长。
- **帧上限**：单帧 32 MiB。超限的一元调用回 `too-large`，流的超限 item 回流错误并关流。
- `bridle revoke` 等本地命令不经 dsh。

### D4. 重连：照官方客户端，重新订阅、用新快照替换，去掉 Bridle 的重放缓冲

dsh 的 `session/follow` 每次打开都返回当前位置的尾页快照，没有"从某 seq 之后续传"（协议参考 §4）。官方 Web 客户端重连时就是重开流、整体替换窗口。我们照做：

- app 断线重连后，对屏幕上的会话重新 `open session/follow`，用快照替换当前窗口；已经向上翻过的更早页面，用 `session/page {throughSeq, beforeSeq}` 按需重新取。
- 列表：`$events` 不重放断线期间的会话增删与状态变化，上游也没有"列表快照与事件流的共同切点"。所以重连时**先开 `$events` 并暂存收到的会话事件，再读一次 `session/list` 整体替换；暂存期间若有任何会话事件，丢弃这些暂存事件并再读一次列表**（最多补读一次），之后只应用此后到达的事件。这样不会用早于快照的通知覆盖较新的状态；持续高频变化时以最后一次列表为准，下一条事件到来即收敛。工作区：重开 `workspace/follow`，它本来就先发全量。
- **删除** Bridle 的 `event-log.ts`（重放缓冲）、`epoch/resume/resync` 机制、`history.ts`（0.1 的历史瘦身），以及 app 侧对应的 epoch 处理。它们存在是因为 0.1 的事件流本身不能续传；0.2 的快照语义让"重开即一致"成立，再在中间加一层缓冲只会多出一套要保证一致的状态。

- **快照大小**：`session/follow` 用 `maxMessages`（与 `session/page` 同规则）控制尾页大小，app 默认取一个保守值；打开失败且原因是超过帧上限时，减半重开，直到放得下——沿用 Bridle 现在对历史分页的做法，只是挪到 app 侧。大会话"接近与超过帧上限"、以及反复重连，列入 M2 验收。
- **排队与未决交互**：排队内容在 follow 快照的投影里（`inbox` 的 `next-turn` / `next-step`），重开 follow 即恢复，不依赖断线前收到的队列帧；待审批与待回答由 dsh 在 `$events` 重连后**重发**（同一 `eventId`，已实测），提问的活动列表也在投影 `userQuestions.active` 里。"服务端已收下、客户端还没收到确认时断线"列入 D8 契约测试。

代价：重连时会多传一次尾页快照（通常几十 KB 级）。可以接受，且省掉的是最难验证的那部分代码。

### D5. 推送：Bridle 自己订阅 `$events`，只看不答

Bridle 开一条自己的 `$events` 流：收到 `approval/request` 或 `user-questions/request` 且没有手机连着时，照现有逻辑振铃（按 token 去重、只振一次）；对应请求被任何客户端回答（Bridle 会收到 `cancel`）后清掉欠账。**欠账按每一代 `$events` 连接重建**：Bridle 与 dsh 之间断线（dsh 重启、Bridle 重启、网络抖动）后，旧的待处理集合整体作废，以重连后 dsh 重发的未决请求为准——断线期间被手机或网页端答掉的请求不会留下来误响。**"已振过铃"按稳定的 `eventId` 记录，跨连接代次保留**（dsh 重发未决请求时 `eventId` 不变），重建待处理集合时不清它，请求结束或在新一代里消失时才清——否则网络一抖，同一个请求会再响一次。这要求把 `BridleCore` 现在按帧对象记账的 `dueForRing/markRung` 改成按 `eventId`。**Bridle 从不回答**——实测多个客户端同时在线时先答者生效，Bridle 作为一个永不作答的客户端不会干扰手机和网页端。没有客户端在线时 dsh 会一直等，不会自动拒绝，所以手机晚点打开仍能作答。

### D6. 版本协商与旧 app

- **哪些不变、哪些变**：Noise 握手、配对、中继与直连、外层多路帧都不变，所以三种新旧组合都能完成握手；变的只是隧道里请求与事件的载荷语法。
- 隧道版本升到 **2**，在握手里协商（`docs/protocol.md` §3.3、§4.6）。Bridle 0.2 只支持 `[2]`，app 1.1 只说 2；任何一端不支持对方的版本，握手就以 `{ok:false, reason:"version", supported:[…]}` 结束，app 据此在发出任何调用前说清"请更新 app"或"请在 Mac 上更新 Bridle"。`ready` 帧另带 `dsh` 版本。（实现见 M1，2026-10-09。）
- 旧 app（1.0，说旧方法名）连到 Bridle 0.2：**不做专门识别**（owner 决定，2026-10-09）。Bridle 0.2 不保留旧请求帧的解析，旧 app 的请求得到隧道 v2 的通用"无法识别的请求"错误，app 显示为普通错误。1.0 用户本来就少，发布时官网与 TestFlight 说明里写清"需要 app 1.1"即可，不为它在 Bridle 里长期养一段只回错误的代码。
- 不做 Bridle 双栈（同时对接 dsh 0.1 与 0.2）：两代 dsh 的认证、接口、事件模型全都不同，双栈等于两套 Bridle，且 0.1 已不再分发；旧组合由不再改动的 Bridle 0.1.x 覆盖。
- Bridle 0.1.x（旧 dsh）+ app 1.1：握手被拒，`supported:[1]`，app 提示更新 Bridle，并说明需要 dsh ≥ 0.2。

### D7. 发布顺序（避免任何时刻"新 app 配旧 Bridle"或反之成为默认）

1. Bridle 0.2 合入 main，但 `install.sh` 默认版本**先不动**；app 1.1 走 TestFlight（Internal 先，Public Beta 审核一天）。
2. 1.1 进 Public Beta 后，发 Bridle 0.2（`install.sh` 默认 → `v0.2.0`，`git push --atomic`）。此时 TestFlight 用户只要升级 app 即可；仍在 1.0 的人会看到普通错误（D6），发布说明里写明需要升级 app。
3. **任一步失败的回退**：
   - Bridle 0.2 发布后发现严重问题，或 app 1.1 迟迟过不了审：`install.sh` 默认改回 `v0.1.x`（同样 `--atomic` 推送），官网与 README 保留旧版安装说明，已升级的用户可以 `ROWEL_REF=v0.1.x` 重装。
   - 用户这边升级 dsh 失败：提示里写清楚——升级前完整备份 `~/.dsh`；要回到旧版就恢复整个备份目录并安装 `@deepseek-ai/dsh@0.1.1-rc.2`（0.2 写过的会话日志 0.1 读不了，所以必须恢复备份而不是只降级程序）。
   - 迁移开发与验收一律用独立的临时 `DSH_HOME` 和端口，不动 owner 日常在用的 dsh（3080）。
4. App Store：**1.0 若过审，先不上架**（发布方式本来就是手动）——它只能配 dsh ≤ 0.1.1，而新用户拿到的都是 0.2。1.1 提审过审后直接上架 1.1。是撤回 1.0 重提 1.1，还是让 1.0 过审后搁置，由 owner 定。现状（2026-10-08）：1.0 因副标题含 "Mac" 被拒（5.2.5），已改副标题、换上 build 190（含会话页卡死修复）重新提审，等待审核。

### D8. 防线：CI 里跑真 dsh

- 新增 CI 任务：`npm install @deepseek-ai/dsh@<pinned>`，隔离 `DSH_HOME` 起 `dsh web`，用 D2(b) 抓 token，跑**不需要模型**的契约测试：
  - 读：认证、`session/create`、`session/list`、`session/follow` 快照、`session/page`、`workspace/follow`、`$events` 能开、`commands/list`、`permissionPresets/catalog`。
  - 写：`commands/execute {line: "/permission read-only"}` 的完整往返（不需要模型，已实测）；`session/prompt` 用 Rowel 实际发送的参数形状（含 `requestId` 与内嵌图片）——没有模型凭据时断言得到的是"凭据/模型"类错误而**不是** `gateway/arguments-invalid`，以此锁住参数契约；`POST /api/$events/result` 的请求形状同理。
  - 断线：消息被服务端收下、客户端收到确认前断开，重连后从 follow 快照能看到它（D4）。
- 再加一个**每周定时**任务，对 `@latest` 和 `@alpha` 跑同一套：dsh 改接口时提前一周看到，而不是等用户报。
- 需要模型的端到端用例（真实对话、审批）仍在本机跑，和现在一样。
- **漂移处置**：每周任务失败时开 issue 通知维护者并做兼容性评估。`@alpha` 失败是**预警**：不阻断发版，但当周就要评估影响；会影响 app 的变化立即开始 app 侧修复，目标是在该改动进入 `@latest` 之前让修好的 app 过审上架（透明转发下这是唯一的缓冲，见 D3）。`@latest` 失败说明预警没起作用，**阻断下一次发版**，直到兼容修复或确认不影响。确认兼容并更新 `dsh-0.2-protocol.md` 后，才把 CI 固定的版本往前挪。

## 3. 改完之后的样子

```
 iPhone (app 1.1)                          Mac
┌──────────────────┐   Noise 隧道    ┌───────────────────────────────┐
│ Harness v2       │◄───────────────►│ Bridle 0.2（插件或独立）       │
│  call / open /   │ (relay 或直连)  │  · 认证（ctx 或 token→cookie） │
│  item / end      │                 │  · POST /api/<endpoint>        │
│ 折叠 0.2 记录     │                 │  · remote.mux 多路复用         │
└──────────────────┘                 │  · 自己的 $events → 推送        │
                                     └──────────────┬────────────────┘
                                                    │ loopback + cookie
                                              dsh ≥ 0.2（dsh web）
```

## 4. 功能对照（app 侧）

| 功能 | 0.1 | 0.2 |
|---|---|---|
| 会话列表 | `session.list` + `host/*` 事件 | `session/list {_request}` + `$events` 里的 `api-session/added\|removed\|status\|activity` |
| 工作区 | `workspace.list` 等 | `workspace/follow` 流（先全量后增量）+ `workspace/create\|rename\|delete\|archiveSession`；新增 `unarchiveSession` |
| 打开会话 | `session.history`（Bridle 瘦身） | `session/follow`（尾页快照 + 增量，`assistantStream: true` 取流式文字）+ `session/page` 向上翻。尾页大小沿用现在的 25 条消息：app 的会话列表已改为非懒加载的 `VStack`（懒加载在真机上会卡死，见 `ConversationView`），布局代价随已加载的行数线性增长，快照取得越大，打开越慢 |
| 流式文字/思考 | `assistant/chunk` 事件 | follow 的 `assistant-stream` 帧（start/chunk/end） |
| 工具卡片 | 服务端 `view` | 0.2 不再给 `view`，app 从 `tool/call`、`tool/result` 记录自己渲染（现有的本地渲染路径补全）。`ask_user_question` 的问题卡片（app 1.0 起有）读调用参数里的 `questions` 和结果里的 `{answers:[{id, selected, custom?}]}`，与 0.2 的 `AskUserQuestionAnswer` 形状一致，不用改；但 timed 模式下答案以 `user-question-reply` 消息 steer 进会话、不进工具结果（协议参考 §5.3），卡片会显示"未回答"——timed 默认关闭，延后到 dsh 打开该模式时再接（把该消息关联回对应卡片） |
| 发送 | `session.prompt` | `session/prompt`，新增必填 `requestId`（客户端生成 UUID，重试复用同一个） |
| 发送图片 | 内嵌在 `session.prompt` 的内容里 | 照旧内嵌在 `session/prompt` 的内容里（`{type:'image', mediaType, data}`），服务端转成持久引用；限制取投影 `imageLimits`（单张 20 MiB 等），同时受隧道 32 MiB 帧上限约束，超限在 app 侧压缩或拒绝。`fileUploads/*` 只用于非图片文件（非目标） |
| 读历史图片 | `session.attachment` | `session/attachment {sessionId, attachmentId}`，返回 base64 |
| 排队/steer/取消 | `session.updateQueue` / `session.cancel` | `session/updateQueue` / `session/cancel` |
| 审批/提问 | `approval/*` 帧 + `POST /api/respond` | `$events` 的 `waterfall`（`approval/request`、`user-questions/request`）+ `POST /api/$events/result`；提问也可 `userQuestions/answer` |
| 斜杠命令 | `commands/list` / `commands/execute {images}` | 同名，参数 `images` → `submittedAttachments` |
| 技能 | `skill.list` | `skills/list` |
| 模型 | `session.models` / `llm.models` / `session.selectModel` | `session/modelCatalog` + 会话的 `model/selection` 记录 + `session/selectModel` |
| 权限预设 | `settings.describe/update`（写死三档）+ `/permission` 命令 | 档位列表 `permissionPresets/catalog`；当前档位读投影 `permissions.currentValue`；切换走 `commands/execute {line: "/permission <preset>"}`（已实测）；默认档位如需修改再走 `settings/update`，M3 实测确认参数 |
| Agent 预设 | `agentPreset.list` | `agentPresets/list`（`copy/openDocument/remove` 已删，Rowel 本来也没用） |
| 插件清单 | `pluginInventory/list` | 同名同参数，只受认证影响 |
| 子代理 | `subagent.list` | 从 `session/list` 行的 `parentSessionId` / `origin: 'subagent'` 识别，用 subagent 地址 follow |
| 机器信息 | `host.describe` | 删除；Bridle 在 `ready` 帧里自己给（主机名、dsh 版本、工作目录） |
| 目录浏览 | `host.listDirectory` | `directoryPicker/list {path}` |
| 搜索/重命名/分叉 | `session.search\|rename\|fork` | `session/search\|rename\|fork`（`fork` 可带 `atSeq`）。**搜索依赖 dsh 的会话索引，默认关闭**：M3 先在 0.2 的默认 `web` profile 上确认启用方式（0.1 是 `profiles/web/cordis.patch.yml` 里的 `session-query-sqlite`，0.2 需重新核对），app 在未启用时照现在一样提示怎么开，并把真实搜索调用列入验收 |

## 5. 里程碑与验收

| # | 内容 | 验收 |
|---|---|---|
| M0 | Bridle：版本识别、认证两条路径（插件 ctx / 自起抓 token）、`bridle plugin install`；本地路径插件回归检查 | 对隔离的 dsh 0.2 `web` profile 两条认证路径都拿到 cookie、`session/list` 200；配了 `publicUrl` 时 (b) 仍用 loopback 换到 cookie；用户自起 dsh 且没装插件时给出"运行 `bridle plugin install`"的明确提示；读到真实版本号，0.1.1 与 0.1.7 都给出明确提示 |
| M1 | Bridle：隧道 v2（call / open / item / end / cancel、流映射、32 MiB 边界）、隧道版本 2（握手协商，只支持 `[2]`）；删除 event-log / history / resume；自己的 `$events` 推送 | e2e（JS 测试手机）对真 dsh 0.2：列表（含重连合并）、开会话快照、翻页、审批经 waterfall 作答、无手机时振铃且网络抖动不重复振铃、手机断线时其名下流被取消；D8 的 CI 契约任务（读、写、断线）上线 |
| M2 | app：Harness v2、列表与工作区、打开会话（follow + page）、新记录折叠、流式帧、重连重订阅 | 单测覆盖折叠；模拟器对真 dsh 0.2 打开历史会话、看完整流式回答；接近与超过帧上限的大会话能打开（减半重开）；反复断网重连后列表、排队、未决审批都正确 |
| M3 | app：发送（requestId、图片、排队/steer/取消）、审批与提问、命令/技能、模型、权限预设、子代理、搜索/重命名/分叉/归档 | 现有 UI 测试全部改到 0.2 并通过；模拟器对真模型走一遍审批；内嵌图片发送与历史图片读取；权限切换；默认 `web` profile 上搜索的启用与真实调用（2026-10-09 完成，实测见协议参考 §12） |
| M4 | 文档（inventory 换成 0.2、architecture、SECURITY、protocol）、CHANGELOG、TestFlight 1.1、按 D7 发布 | D7 每一步执行完毕；官网与 README 写明需要 dsh ≥ 0.2；TestFlight 1.1 在真机上走一遍审批 |

粗估：M0 半天，M1 1.5 天，M2 3 天，M3 2–3 天，M4 1 天，共约 **1.5 周**（2026-10-09 砍掉贴 URL 认证、旧 app 识别、桌面端后）。每个里程碑单独 PR、CI 通过再进下一个。

## 6. 风险与开放问题

1. ~~桌面端没实测~~：已移出本次（见非目标）。
2. ~~本地路径插件条目在 0.2 是否仍可用~~：rc.2 与 0.2.1-alpha.1 均已实测可用（D2），保留回归检查。
3. **dsh 仍是 rc**，0.2 正式版前接口可能再变。D8 的每周任务就是为此。0.2.1-alpha.1 已于 2026-10-08 复核：我们用到的端点与 rc.2 一致，只多了 `--public-url`（已并入 D2）；需要模型的路径（流式帧、审批重发与先答先得、提问、`requestId` 去重）依据相关包代码逐字节相同，未在 alpha.1 上重测；M3 已在 rc.2 上用真模型验过（协议参考 §12），alpha.1 由 D8 的每周任务与 M4 的真机走查覆盖。
4. **实测发现的 dsh 缺陷**：`session/prompt` 的 `requestId` 去重有竞态（出队与落盘之间重发会重复）；编辑排队消息会丢附件。app 侧规避：重试只在确认未送达时进行；编辑带附件的排队消息时提示。两条都报给上游。
5. **子代理会话里的审批**：M3 已实测（协议参考 §12）——默认配置下子代理以委托策略 `never` 运行，不弹审批；app 仍把子代理的请求挂到父会话上，供将来放开时使用。**带倒计时的异步提问**默认关闭，仍未实测，留待 dsh 打开该模式后再接。
6. **升级 dsh 会改写 `~/.dsh`**（`settings.yaml` → `.imported`，合并进 profile 配置）。这是 dsh 的行为，不归我们管，但"需要 dsh ≥ 0.2"的提示里要说清楚升级是单向的。**更要紧的是 pi-ai provider 会丢**（协议参考 §12）：0.2 默认 profile 不装 `dsh-llm-pi-ai`，导入时 `llm-pi-ai` 一节被丢弃，用 commandcode 等 provider 的人（包括 owner 本机）升级后模型全部不可用，要在 profile 里 `insert` 该插件并带上原 `providers`。M4 的发布说明与升级步骤必须写这一条，最好给出可复制的片段。
7. **用户本机现在是 0.1.1-rc.2**。迁移验收需要升级它；升级前备份 `~/.dsh`，并且在 app 1.1 就绪前不升，以免手机断线。
