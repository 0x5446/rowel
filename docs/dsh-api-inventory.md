# dsh 0.2 接口清单（Rowel 实际用到的部分）

dsh 0.2 有上百个端点，插件还会再加。这里只列 **app 真正调用的**，以及谁调用它。每个端点的完整语义、实测样本和错误码见 [`dsh-0.2-protocol.md`](dsh-0.2-protocol.md)，本文不重复。

版本：`@deepseek-ai/dsh 0.2.0-rc.2`（CI 钉住的版本；D8 的每周任务对 `@latest` / `@alpha` 跑同一套契约）。参数形状以录制为准：`e2e/scripts/capture-fixtures.mjs` 把真 dsh 的回答录进 `ios/RowelTests/Fixtures/dsh-0.2/`，iOS 测试按录制核对 app 发出的参数（`PresetAndPluginTests`）。

## 1. 怎么到达 dsh

- 隧道版本 2 **透传**：app 的 `call {endpoint, args}` 由 Bridle 变成 `POST /api/<endpoint>`，`open {endpoint, args}` 变成 Bridle 那条 `remote.mux` 上的一条流（`docs/protocol.md` §4）。Bridle 不翻译、不白名单。
- 认证由 Bridle 负责：它作为 dsh 插件拿到 launch token，或者自己启动 dsh 时从输出里读到，再换成 cookie（`dsh-0.2-protocol.md` §1）。app 看不到 cookie。
- dsh 对参数名**精确**校验：多一个、少一个都是 `gateway/arguments-invalid`。下文的 `args` 就是 dsh 的 `payload.args`。
- 唯一由 Bridle 自己回答的端点是 `$export`（会话归档，`docs/protocol.md` §4.1）；app 目前没有调用它。

## 2. 流（`open`）

| 端点 | `args` | 用途 | 调用方 |
|---|---|---|---|
| `$events` | `{}` | 首项 `ready {clientId}`；之后 `waterfall`（`approval/request`、`user-questions/request`）、`cancel {eventId}`、`emit`（`api-session/added\|removed\|status\|activity\|error` 等） | `Harness.events` ← `MachineSession.attach` / `handleEvent` |
| `workspace/follow` | `{}` | `baseline {items, archivedSessionIds, pinnedSessionIds}`，之后 `upsert` / `remove` / `archived` 等增量 | `Harness.followWorkspaces` ← `attach` / `handleWorkspaces` |
| `session/control` | `{}` | 所有已挂载会话的 projection：`baseline`，之后逐键 `projection {sessionId, key, value, seq}` | `Harness.followControl` ← `attach` / `handleControl` |
| `session/follow` | `{request: {address, assistantStream: true, maxMessages}}` | 一个会话：快照，然后事件与 `assistant-stream` 帧。子代理用 `{kind: "subagent", parentSessionId, childSessionId, mode}` 地址 | `Harness.follow` ← `MachineSession.run(follow:)` |

每次握手、或 Bridle 报告 dsh 恢复时，`MachineSession.attach` 把这些流全部重开；每条流的第一项就是完整基线，替换已有状态（迁移设计 D4）。

## 3. 一元调用（`call`）

调用方一栏里没写类名的，都是 `MachineSession` 的方法。

### 会话

| 端点 | `args` | 用途 | 调用方 |
|---|---|---|---|
| `session/list` | `{_request: {}}` | 会话列表（含子代理行，app 过滤掉并记下父子关系） | `Harness.listSessions` ← `readList` |
| `session/page` | `{request: {address, throughSeq, beforeSeq?, maxMessages}}` | 窗口之前的更早一页 | `Harness.page` ← `loadOlder` |
| `session/create` | `{request: {cwd?, workspaceId?, agentPreset?}}`（`cwd` 与 `workspaceId` 二选一） | 新会话；落在工作区里时只传 `workspaceId` | `Harness.createSession` ← `createSession` |
| `session/prompt` | `{request: {requestId, sessionId, mode: "queue"\|"steer", content, clientTimeZone}}` | 发消息；`content` 含内嵌 base64 图片 | `Harness.prompt` ← `send` |
| `session/cancel` | `{request: {sessionId}}` | 停止当前 turn | `Harness.cancel` ← `cancel` |
| `session/updateQueue` | `{request: {sessionId, itemId, action: {kind: "edit"\|"remove"\|"steer", …}}}` | 编辑、撤回、插队一条排队消息 | `Harness.updateQueue` ← `promote`、`ConversationView` |
| `session/rename` | `{request: {sessionId, title}}` | 改标题 | `Harness.rename` ← `rename` |
| `session/fork` | `{request: {sessionId}}` | 分叉 | `Harness.fork` ← `fork` |
| `session/search` | `{request: {query}}` | 全文搜索；默认 profile 关闭，返回 `gateway/internal` "session search is disabled" | `Harness.search` ← `SessionListView` |
| `session/attachment` | `{request: {sessionId, attachmentId}}` | 取历史里一张图片的字节 | `Harness.attachment` ← `Store/Attachments.swift` |
| `session/projections` | `{request: {sessionId}}` | 单个会话的 projection（模型选择、子代理目录） | `Harness.projections` ← `Harness.models`、`Harness.subagents` |
| `session/modelCatalog` | `{}` | 机器可路由的模型与默认模型 | `Harness.models` / `machineModels` ← `loadModel`、`ModelPicker`、`DefaultModelPicker` |
| `session/selectModel` | `{request: {sessionId, provider, model, reasoningEffort?}}` | 切模型 | `Harness.selectModel` ← `selectModel`、`createSession` |

### 工作区

| 端点 | `args` | 用途 | 调用方 |
|---|---|---|---|
| `workspace/create` | `{request: {path}}` | 把文件夹认领为工作区（已存在则返回已有的） | `Harness.createWorkspace` ← `createWorkspace`、`createSession` |
| `workspace/rename` | `{request: {workspaceId, title}}` | 改名 | `Harness.renameWorkspace` ← `renameWorkspace` |
| `workspace/delete` | `{request: {workspaceId}}` | 取消分组（目录与会话都保留） | `Harness.deleteWorkspace` ← `deleteWorkspace` |
| `workspace/archiveSession` | `{request: {sessionId}}` | 归档 | `Harness.archive` ← `archive` |
| `workspace/unarchiveSession` | `{request: {sessionId}}` | 取消归档（已封装，界面暂无入口） | `Harness.unarchive` |

### 命令、技能、权限、杂项

| 端点 | `args` | 用途 | 调用方 |
|---|---|---|---|
| `commands/list` | `{agentId}`（值为 sessionId） | 机器会执行的斜杠命令 | `Harness.commands` ← `loadCommands` |
| `commands/execute` | `{agentId, line, submittedAttachments: []}` | 执行一行命令，如 `/permission read-only` | `Harness.command` ← `runCommand`、`setSessionPermission` |
| `skills/list` | `{request: {sessionId}}` | 会话可用技能 | `Harness.skills` ← `loadCommands` |
| `permissionPresets/catalog` | `{}` | 档位可选项与新会话的默认档位 | `Harness.permissionPresets` ← `refreshAccessDefault` |
| `settings/describe` | `{}` | 读 `permission` 命名空间的 revision | `Harness.setPermission` |
| `settings/update` | `{ns: "permission", patch: {defaultPreset}, expectedRevision}` | 改新会话的默认档位（乐观并发） | `Harness.setPermission` ← `setPermission` |
| `agentPresets/list` | `{}` | 可选的 agent 预设（0.2 只给 id） | `Harness.presets` ← `loadPresets` |
| `pluginInventory/list` | `{}` | 已挂载的插件 | `Harness.pluginInventory` ← `plugins` |
| `directoryPicker/list` | `{path?}` | 浏览 Mac 上的目录；默认 profile 是 native 选择器，返回 `directory-picker/unavailable` | `Harness.listDirectory` ← `DirectoryPicker` |
| `$events/result` | `{clientId, eventId, outcome: {kind: "result", value}}` | 回答审批（`allowed-once` / `rejected`）或提问（`{answers: [...]}`）；先答者生效 | `Harness.answerApproval` / `answerQuestion` ← `answer(approval:)`、`answer(question:)` |

## 4. 没有用到、但容易以为要用的

- `userQuestions/answer`、`userQuestions/attachWait`：只属于 timed 提问模式，默认关闭（`dsh-0.2-protocol.md` §5.3）。
- `fileUploads/upload`：app 把图片直接内嵌在 `session/prompt` 的 `content` 里。
- `session/initializeDefaultModel`、`credentials/*`、`settings/*` 的其他命名空间：属于 Mac 上的配置，不在手机上做。
