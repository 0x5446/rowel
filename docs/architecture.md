# Rowel 技术架构

本文档描述 Rowel 的整体设计、每个接缝的契约、以及新功能应该落在哪里。它同时是一份**扩展指南**——未做的功能（定时任务、多 agent）在这里有明确的落点；推送与 trace 已按这里的落点做完，实施时不需要重新设计。

写作原则：每个决策给出理由和代价。没有理由的决策是巧合，没有代价的决策是谎话。

- 组件与命名：§1
- 架构论点（全文的骨架）：§2
- 三个扩展点：§3
- 分层与依赖方向：§4
- 加密与信任：§5
- 隧道协议：§6
- 可达性阶梯：§7
- 两个入口，一份核心：§8
- iOS 端：§9
- 推送：§10
- 待建子系统（定时 §11、多 agent §12、trace §13）
- 版本协商与兼容：§14
- 测试策略：§15
- 不变量清单：§16
- 明确不做：§17
- 已知代价：§18

---

## 1. 组件与命名

| 组件 | 是什么 | 跑在哪 | 代码 |
|---|---|---|---|
| **Rowel** | iOS app | iPhone | `ios/` |
| **Bridle** | 伴生进程，套住本机 agent | 与 agent 同机 | `bridle/` `dsh-plugin/` |
| **Relay** | 内容盲交换机 | 公网 | `relay/` |
| **protocol** | 两端共享的线上格式 | 两端各一份实现 | `protocol/`（TS）+ `ios/Rowel/Protocol/`（Swift） |

一句话：**Bridle 套住 agent，Relay 传递密文，Rowel 别在骑手身上。**

命名不是装饰。笼头戴在马身上，马刺轮戴在人身上，中继在两者之间——三个词各自说清了自己那一端的职责边界，读代码的人不需要记住一张缩写表。这也是分界线的形状：Bridle 贴着 agent，Rowel 贴着人，Relay 谁都不属于，因此它什么也读不到。

---

## 2. 架构论点

> **系统是一根管子，两端各有一次折叠。中间的每一层都不理解内容。**

这句话是全文的骨架，所有分层都是它的推论。

dsh 不发送渲染结果，它发送自己那份 append-only 事件日志，每个客户端各自折叠成要显示的东西。这一点决定了整个系统的形状：

- **Relay 不理解内容**——它只有密文，连端点名都看不到。
- **Bridle 透传 dsh 自己的接口，只解释被明确列出的控制语义**。隧道版本 2 里，手机的 `call` 原样变成 `POST /api/<endpoint>`，`open` 原样变成 dsh `remote.mux` 上的一条流（`docs/protocol.md` §4），Bridle 不认识任何端点。被列出的例外只有两处，各自有界：§10 的通知判定（Bridle 自己开一条 `$events`，只按 `eventId` 记"有没有人在等"，从不作答），以及 §3.4 的 `$export`（把 dsh 的归档下载转成 base64，是格式转换，不读内容）。

  > 早期版本称历史瘦身是"唯一的例外"，同时又要求 Bridle 识别审批与调度事件。deep review 指出这是自相矛盾。原则改写成上面这句：**例外必须被列出，而不是被称为不存在。**瘦身已随隧道版本 1 删除（dsh 0.2 不再持久化流式 chunk）。
- **只有 app 折叠**——`Conversation` 是唯一知道流式帧（`assistant-stream`）该拼进哪个气泡、工具调用该画成哪种卡片的地方。

### 为什么这样是对的

**折叠是纯函数。**`items = fold(events)`。这带来三个白拿的性质：

1. **断线重连不需要对账**。dsh 的流不续传，每次打开都先给一份当前状态（会话快照、工作区基线、projection 基线），之后才是增量；app 重开流、用新快照整体替换窗口，折叠出的就是当前真相。中间不需要任何缓冲或重放。
2. **快照、更早的页和实时事件走同一条折叠路径**，`seq` 去重，一页历史与窗口重叠不会双渲染。
3. **可测**——iOS 单元测试里大半是喂事件、断言 `items`，不需要网络也不需要 UI；其中一批喂的是真 dsh 0.2 的录制（`ios/RowelTests/Fixtures/dsh-0.2`）。

**中间层不理解内容，所以中间层不需要跟着功能升级。**dsh 加一个端点、一个事件类型、一个 projection，Bridle 和 Relay 一行都不用改。这是本项目最重要的可维护性性质，§3 把它具体化成三个扩展点。

### 代价

- **app 必须容忍未知**。不认识的事件类型静默丢弃（`Conversation.apply` 的 `default` 分支），不认识的工具降级成 `.generic` 卡片。写死枚举会让插件生态每装一个东西就崩一次。
- **折叠成本在客户端**。dsh 0.2 不再持久化流式 chunk，但一页仍带着每一步的请求头（含完整工具 schema）和全部工具输出，字节数没有上限。app 的会话快照只要 25 条消息，超过帧上限就减半重开（§6.1）。
- **dsh 改接口，修复要靠 app 发版**。透传意味着没有翻译层替 app 挡住变化；对策是 CI 每周对 dsh 的 `@alpha` 跑契约测试，提前发现（迁移设计 D3、D8）。

---

## 3. 三个扩展点

**大多数**功能待办会落在这三个口子之一，改动是局部的。但不是全部——下面 §3.5 列出落不进去的那几类，那是真实的结构性工作，不该被这套说辞粉饰成增量。

> 早期版本这里写的是"每一项都只会落在这三个口子之一"，以及"改三个以上文件即接缝错误"。deep review 用待办清单压测后证伪了：定时任务要服务端作业、subagent 是独立会话树、trace 要跨事件聚合，三者都不属于"透传方法 / 折叠 projection / 渲染意图"。断言已删除。

### 3.1 新方法：透传，零改动

app 调用 dsh 0.2 的任意一个端点，只需要在 `ios/Rowel/Net/Harness.swift` 加一个函数，参数名照 dsh 的声明写（dsh 精确校验参数名，多一个少一个都是 `gateway/arguments-invalid`）：

```swift
public func fork(sessionId: String) async throws -> String {
    let value = try await transport.call("session/fork", .object(["request": .object(["sessionId": .string(sessionId)])]))
    guard let id = value["sessionId"]?.stringValue else { throw CallError(code: "internal", message: "…") }
    return id
}
```

Bridle 的 `TunnelSession` 是完全泛型的——`endpoint` 是字符串，`args` 是不透明值，`call` 转成 `POST /api/<endpoint>`，`open` 转成 `remote.mux` 上的一条流。**Bridle 不需要知道 `session/fork` 存在。**参数形状以录制为准：`e2e/scripts/capture-fixtures.mjs` 对一个一次性 dsh 录下请求与回答，iOS 测试按录制核对 app 发出的参数。

> 唯一的例外是 `$export`（§3.4）。

### 3.2 新 projection：一个 case

dsh 每个会话带一组 projection。加一个是 `Conversation.applyProjection` 里的一个 case：

```swift
case "inbox":
    applyInbox(value)
```

**projection 的传输是白拿的**——会话快照带着 `projections` 基线块，`session/control` 流对每个已载入的会话逐键推送变化（带 `seq`，旧值不覆盖新值）。不需要新请求，不需要碰 Bridle。

dsh 0.2 实测出现过的 projection：

| projection | 用了吗 | 内容 |
|---|---|---|
| `title` `todos` `contextPressure` `plan` | ✓ | 标题、清单、上下文占用、计划模式 |
| `sessionStats` `tokenUsage` `contextBreakdown` | ✓ | 统计、token、上下文明细 |
| `permissions` | ✓ | 只有 `{currentValue}`；可选档位来自 `permissionPresets/catalog` |
| `inbox` | ✓ | 排队中的消息（`next-turn` / `next-step`），取代 0.1 的 `session/queue` |
| `modelSelection` `subagentCatalog` `agentPreset` | ✓（经 `session/projections` 或列表行读） | 当前模型、子代理清单、预设 |
| `goal` `userQuestions` `turnOutline` `subagent` `subagentTiming` | — | 长任务目标、提问、turn 概要、子代理状态与耗时 |
| `sessionListMetadata` `imageLimits` | — | 列表元数据、图片上限 |

### 3.3 新工具卡片：一个 case

dsh 0.1 在事件旁边附一份渲染意图（`view`），0.2 不再给了（"the controller does not … run a presenter, or attach UI data"）。卡片因此由 app 从工具名和参数选：`Conversation.callPresentation(name:arguments:)` 在调用时选卡片，`resultPresentation` 在结果到达时补内容（shell 的退出码、搜索的结果行）。

```
bash → terminal · edit / write → diff · grep / glob → search · read → read
web_fetch / web_search → 带 kind 的 generic · ask_user_question → question
其他 → generic，标题是工具名，详情是最能说明它的那个参数
```

新增一种卡片 = `callPresentation` / `resultPresentation` 各加一个 case，`ToolCardView` 加一个分支。

**关键性质换了说法**：app 现在要知道少数几个内置工具的参数名，但仍然**不需要认识每一个工具**——插件新加的工具落到 `.generic`，显示工具名、最有信息量的参数和原始输入，是退化而不是崩溃。

### 3.4 Bridle 自己回答的唯一端点：`$export`

dsh 把会话归档作为普通下载提供（`GET /api/session.export`，二进制 zip），不是一元端点，手机够不着。Bridle 收到 `call {endpoint: "$export"}` 时自己取回，以 `{filename, contentType, base64}` 作为结果返回；归档超过帧上限时回 `too-large`，而且不会先整份读进内存（`bridle/src/tunnel/session.ts`）。

它是格式转换，不读内容。版本 1 时这里还有一个历史瘦身钩子（剥掉已提交消息的 `assistant/chunk`）；dsh 0.2 不再持久化 chunk，钩子随版本 1 删除。

**边界**：任何需要理解"这条消息说了什么"才能做的事，都不属于 Bridle，属于 app。

### 3.5 落不进三个口子的那几类

| 扩展类型 | 例子 | 状态归谁 | 上下行 | 断线恢复 | 为什么不是前三类 |
|---|---|---|---|---|---|
| **请求命令** | `session/fork` `workspace/archiveSession` | 无（一次性） | `call`/`result` | 重试即可 | ← §3.1 |
| **复制状态** | 访问模式、上下文明细、统计 | agent，app 只读 | 快照基线 + `session/control` 的 projection 帧 | 重开取新基线 | ← §3.2 |
| **工具卡片** | terminal / diff / search 卡片 | app 按工具名本地选 | 随 `tool/call` / `tool/result` 事件 | 重开收敛 | ← §3.3 |
| **读写状态** | 切换访问模式 | agent | projection 读 + 方法写 | 写要幂等 | 读是 §3.2，**写不是**——要处理并发修改与失败回滚 |
| **会话图** | subagent | agent，**独立会话树** | 经父会话的 subagent 地址 `session/follow` / `session/page` | 每棵树各自快照 | 不是当前会话的派生状态，是**另一批会话** |
| **跨事件聚合** | trace | app 自己算 | 无新协议 | 需要重算 | 折叠器现在是逐事件的；时序聚合要跨 `step/start`–`step/end` 配对 |
| **后台作业** | 定时任务 | **Bridle**，手机不在也要活 | 新方法 + 触发通知 | 作业不能因手机断线而丢 | 前三类都假设"手机在看"，这一类不成立 |
| **主动通知** | 推送 | Bridle 判定 + Relay 投递 | 隧道外的另一条路 | 不适用 | 完全在隧道之外 |

后四类**都需要设计**，不是加个 case。实施前应各自补一份规范级文档（`docs/README.md` 的规格等级）。

---

## 4. 分层与依赖方向

```
                 ┌──────────────────────────────────────┐
   iPhone        │  Views      （只读 Store，不碰网络）  │
                 │  Store      Conversation / MachineSession / AppModel
                 │  Net        Tunnel / Harness / Carrier │
                 │  Protocol   Noise / Frames / Pairing   │
                 └──────────────┬───────────────────────┘
                                │  Noise 密文
                 ┌──────────────┴───────────────────────┐
   公网          │  Relay      registry / offers / limit │
                 └──────────────┬───────────────────────┘
                                │  Noise 密文
   用户的电脑    ┌──────────────┴───────────────────────┐
                 │  TunnelSession  握手 / 帧循环 / 流映射 │
                 │  BridleCore     身份 / 自己的 $events  │
                 │  AgentClient    ← 唯一的 agent 适配面  │
                 └──────────────┬───────────────────────┘
                                │  loopback HTTP + 一条 remote.mux（带登录 cookie）
                                ▼
                          dsh (127.0.0.1:3080)
```

**依赖只向下。**`Views` 不 import `Net`，`Net` 不知道 `Views` 存在。Bridle 的 `TunnelSession` 通过 `BridleCore` 拿 agent，不直接构造。

### 4.1 agent 适配面

这是可扩展性最重要的一条边。整个 agent 侧的接触面是一个接口（`bridle/src/agents/types.ts`）：

```ts
interface AgentClient {
  readonly baseUrl: string
  start(): void
  stop(): void
  readonly connection: MuxState                       // 到 dsh 的那条流连接现在通不通
  onConnection(listener: (state: MuxState) => void): () => void
  call(endpoint: string, args: unknown, signal?: AbortSignal): Promise<AgentResult>
  open(endpoint: string, args: unknown, sink: StreamSink): StreamHandle
  export(sessionId: string, includeDescendants: boolean, signal?: AbortSignal): Promise<Response>
}
```

`DshClient` 实现它：一元调用走 `POST /api/<endpoint>`，所有流——每部手机的和 Bridle 自己的 `$events`——共用一条 `remote.mux` WebSocket（`bridle/src/dsh/remote-mux.ts`），流 id 由 Bridle 自己编号，两部手机选了同一个 sid 也不会撞。这条连接断了，上面每条流都以 `upstream-lost` 结束，由打开它的一方重开。`BridleCore` 只认接口：`constructor(state, overrides: { dsh?: AgentClient })`。`e2e/src/fake-agent.ts` 是第二个实现，它编译得过这件事本身就是接缝为真的证明。

> **但接口存在 ≠ 第二个 agent 快做完。**接口仍然带着 dsh 的形状：端点名、参数、`$events` 的 waterfall、流帧都是 dsh 0.2 的原样。app 侧的 projection、工具卡片、审批应答也一样。**第二个后端需要的是这个接口之上的一层归一化，而不是这个接口的另一个实现。**见 §12。

---

## 5. 加密与信任

### 5.1 为什么是 Noise_IK

`Noise_IK_25519_ChaChaPoly_SHA256`，两端只用标准库（Node `node:crypto` / Swift `CryptoKit`），零第三方密码学依赖。

选 IK 而不是别的：

- **发起方在第一条消息里就知道响应方的静态公钥**（从配对码拿到），所以不需要额外往返，也不给中间人任何"先冒充再说"的窗口。
- **双向认证**：消息一的 `s, ss` 认证发起方，消息二的 `ee, se` 给出前向保密。
- **对比**：HPKE base 模式是单向的、不认证发送方；一个自定义的"共享密钥 + SecretBox"方案没有前向保密，密钥泄露一次全历史可解。

### 5.2 密钥生命周期

| 密钥 | 存哪 | 生命周期 |
|---|---|---|
| 手机静态私钥 | iOS Keychain，`afterFirstUnlockThisDeviceOnly` | 装机时生成，重置才换 |
| 机器静态私钥 | `~/.rowel/bridle.json`，0600 | 首次运行生成 |
| 机器签名密钥（Ed25519） | 同上 | 同上，与静态密钥**分离** |
| 每连接临时密钥 | 内存 | 一次连接。**不可用于推送**——推送发生时它已不存在，见 §10.2 |
| 配对令牌 | 状态文件，带过期 | **一次性**，用掉即废 |

**密钥不复用。**签名用 Ed25519，DH 用 X25519，对称加密用握手派生的传输密钥——三者独立。把一个 32 字节秘密同时当 SecretBox key、Ed25519 seed 和 X25519 私钥用，是明确的密码学异味。

### 5.3 配对的两条路

**二维码**（默认）：配对码直接带着机器的静态公钥，手机在第一个字节之前就知道对方是谁。恶意 Relay 无法介入。

**短码**（扫不了码时）：手机从 Relay 换取配对载荷，而 Relay 读得到它、改得了它、也能自己拿去用。所以短码载荷里是**另一把** token（`codeToken`），它只能换来一次"申请"：Bridle 记下申请的手机（`offer.claimant`）并以 `pending` 拒绝；`bridle pair --code` 在 Mac 的终端里显示该手机的密钥指纹并询问是否接受，手机在等待期间显示自己的指纹。两者一致才接受。

一次比对同时挡住两种攻击：Relay 冒充手机（Mac 看到的是 Relay 的密钥），Relay 居中替换机器公钥（Mac 看到的仍是 Relay 的密钥）。

> 早期版本这里写的是握手后两端比对 6 位确认数。Mac 端从未实现它，而短码载荷里放的又是与二维码同一把 token——Relay 拿着它就能直接配对。2026-09 改成上面的两把 token + Mac 端确认。

### 5.4 dsh 的认证只到本机为止，这是设计的中心事实

dsh 0.2 的 `/api` 连 loopback 也要一枚签名 cookie，而 cookie 只能用 dsh 启动时打印的 launch token 换（`GET /?token=` → 303 + `set-cookie`，见 `docs/dsh-0.2-protocol.md` §1）。这把锁是给同一台机器上的浏览器用的：token 只出现在 dsh 自己的终端输出里，也只交给 dsh 的插件。

Bridle 因此有两种拿到它的办法：作为 dsh 插件运行时，dsh 把端口和 token 交给插件（`dsh-plugin/`，`bridle plugin install` 写入 profile）；作为独立进程且由 Bridle 自己启动 dsh 时，从 dsh 打印的那一行里取。换来的 cookie 存在 `~/.rowel/secrets/dsh-cookies.json`，按 `host:port` 分开，30 天有效、跨 dsh 重启（`bridle/src/dsh/credentials.ts`）。

**这把锁不延伸到网络上，所以 Bridle 不能是哑转发器。**一个拿着 cookie、把 `0.0.0.0` 转到 dsh 的代理，就等于把一个远程代码执行接口暴露给整个网段。

Bridle 补的是网络这一段的认证：

- 监听器**只讲 Noise 隧道**，非 WebSocket upgrade 一律 `426`，不吐一个字节的 API（`direct-server.ts`）
- 未配对设备完不成 IK 握手
- e2e 测试 `the direct listener is not a web server` 盯着这条

**推论也要说清楚：配对进来的设备 = dsh 的完整权限。**Bridle 不做细粒度授权、也不做端点白名单——dsh 本身没有权限分级，白名单挡不住任何实际风险，却会让每个新端点都要 Bridle 发版（迁移设计 D3）。`bridle revoke` 是唯一的**收回**手段。这是产品必须诚实告知用户的事。

### 5.5 手机丢了怎么办

上面那条推论有个直接后果：一部**已解锁**的已配对手机，就是一个不再需要任何凭证的远程 shell。系统锁屏挡不住这个场景——手机被递出去、在餐桌上被顺走、放在工位上没锁——它本来就是解锁状态。

app 自己那把锁（`ios/Rowel/Store/AppLock.swift`）不解决这件事，它只给这个窗口设一个上限：

| 机制 | 做什么 | 为什么是这个选择 |
|---|---|---|
| 冷启动即锁 | 从外部进来一次就要认证一次 | 启动是唯一能确定"刚才不在手里"的时刻 |
| 离开前台超时 | 可配：立即 / 1 / 5 / 15 分钟 / 1 小时，默认 1 分钟 | 默认要短到有意义，又不能让"切出去看条消息"都要刷脸 |
| `.inactive` 就遮挡 | app 一旦不在最前就盖住内容 | **iOS 在 `.inactive` 阶段给窗口拍照做多任务缩略图**。等到 `.background` 再遮，拍到的已经是完整会话内容 |
| 时钟倒退即锁 | 墙钟往回走就当超时 | 不知道密码、但能改系统时间的人，否则可以直接跑赢一小时的超时 |
| 不可认证则放行 | 设备没有密码时自动关掉这把锁 | 这不是绕过（拿掉密码本来就要先知道密码）；要避免的是机主被永久关在自己的配对之外 |
| 不可逆操作二次认证 | 重置身份、遗忘某台 Mac 前再认证一次 | 这两件事从手机上撤不回来 |

**审批不在二次认证之列，这是有意的。**审批本身就是那次确认。给每一次审批都加一道刷脸，只会把人训练成"不看内容先认证"——那比不问更糟。

**这把锁没做的事，要说清楚**：

- **没有远程吊销。**手机丢了，只能走到电脑前跑 `bridle revoke`。经中继转交、由机器验证的远程吊销是对的方向，但它需要第二台已配对设备来发起——只有一部手机的人，丢了就是没有发起端。在有多设备之前，做它等于做一个没有入口的功能。
- **锁不保护静态数据。**app 的会话缓存和 Keychain 里的密钥不因为这把锁而更安全，它们的保护来自 iOS 的数据保护和 `afterFirstUnlockThisDeviceOnly`。
- **越狱设备上它不成立。**任何进程内的开关在能读写别人内存的系统上都不成立。

---

## 6. 隧道协议

单条隧道复用全部流量，手机只持有一个 socket。隧道版本 2 就是 dsh 0.2 自己的接口，原样透传；完整规格见 `docs/protocol.md` §4。

| 帧 | 方向 | 语义 |
|---|---|---|
| `call {id, endpoint, args}` | app→bridle | 一元调用，对应 `POST /api/<endpoint>` |
| `result {id, result}` | bridle→app | 应答，`result` 是 dsh 的 `{ok, value}` / `{ok:false, error}` 原样 |
| `abort {id}` | app→bridle | 放弃在途调用，Bridle 中止上游请求 |
| `open {sid, endpoint, args}` | app→bridle | 打开一条 dsh 流（`session/follow`、`workspace/follow`、`session/control`、`$events`…） |
| `item {sid, value}` | 双向 | 流上的一项 |
| `end {sid}` / `error {sid, error}` | bridle→app | 流结束 / 失败（每条流至多一个终止帧） |
| `cancel {sid}` | app→bridle | 停止一条流，Bridle 在 dsh 那边也取消 |
| `hello` `wake` `ready` `status` `ping` `pong` `fault` | 双向 | 生命周期、推送 token、dsh 可达性 |

每条隧道最多 64 个在途调用、64 条打开的流，超出立即回 `busy`，不排队。审批与提问不再有专门的帧：它们是 `$events` 流上的 waterfall，手机以自己的 `clientId` 调 `$events/result` 作答（dsh 先到先得，§9.4）。

### 6.1 重连：重开流，新基线替换旧状态

dsh 0.2 没有流级续传：`session/follow` 每次打开都从当前位置给一份快照，`workspace/follow` 先发全量，`session/control` 先发 projection 基线，新的 `$events` 客户端会收到所有仍在等待的请求（`eventId` 不变）。所以重连的做法与 dsh 自己的网页客户端一样：**重新打开每条流，用新基线整体替换旧状态**（迁移设计 D4）。

Bridle 因此不缓冲、不重放任何东西。版本 1 的环形缓冲、`resume{since, epoch}`、`resync` 都已删除——它们存在是因为 dsh 0.1 的事件流不能续传；0.2 的快照语义让"重开即一致"成立，中间再加一层缓冲只会多出一套要保证一致的状态。代价是每次重连多传一份尾页快照。

两条边界：

- **流的归属**：每条流记在打开它的隧道名下，隧道关闭时 Bridle 取消它名下的全部流，不在 dsh 上留下孤儿流；Bridle 到 dsh 的连接断了，所有流以 `upstream-lost` 结束。
- **帧上限 32 MiB**（按线上字节算）：超限的 `result` 变成 `too-large` 失败，超限的流 item 让 Bridle 取消这条流并回 `too-large`，只失败这一个调用或这一条流，隧道不动。app 收到快照或翻页的 `too-large` 就把消息数减半重开。

### 6.2 字节级对齐

协议在 TS 和 Swift 里各实现一遍。**"我自己写的服务器能连上我自己写的客户端"证明不了任何事**，所以：

`protocol/scripts/emit-vectors.js` 用固定密钥、固定临时密钥跑出确定性向量，Swift 侧逐字节比对握手消息、handshake hash、确认数、传输层密文、配对链接、版本 2 的帧编码（`call` `abort` `open` `item` `end` `cancel` `wake`）。

这里的失败是协议分叉，不是 flaky test。

> 一个真实教训：Foundation 的 `JSONEncoder` **不保证 key 顺序**（不是声明顺序，而且跨进程不稳定）。帧编码因此改成显式声明顺序（`TunnelFrame.members`）。没有向量的话这个问题不会被发现，因为两端都能正常解析。

---

## 7. 可达性阶梯

**中继是兜底，不是路径。**这是与竞品最重要的架构分歧——调研中最高频的用户抱怨是"为什么我的流量要过你的服务器"。

app **并发**拨所有候选，让 Relay 晚 250ms 起跑，先握手成功者胜，其余立即关闭。这是 Happy Eyeballs（[RFC 8305](https://datatracker.ietf.org/doc/html/rfc8305)）的形状用在端点选择上，250ms 也是该规范实测出的 Connection Attempt Delay。

早先是串行的——先试局域网、失败再试 Relay——那在手机离开家的一刻就变成 bug：不可达的局域网地址不会立刻失败，只会超时，两个地址就是 16 秒，而那正是只有 Relay 能通的场合。

| 层 | 机制 | 我们的服务器 | 状态 |
|---|---|---|---|
| 1 | 同一局域网直连 | 零 | ✓ |
| 2 | Tailscale / 其他 overlay | 零 | ✓ 自动——Bridle 绑 `0.0.0.0`，网卡枚举天然包含 `100.64/10` |
| 3 | 用户自带隧道（CF Tunnel / ngrok / 端口转发） | 零 | ✓ `--advertise` |
| 4 | Relay | 兜底 | ✓ |
| 5 | P2P 打洞（STUN/ICE） | 仅信令 | 未做，见下 |

Bridle 侧的地址选择（`dialableAddresses`）丢掉 `169.254/16`（DHCP 失败的自赋地址，只会换来超时），排序为 `192.168` → `10` → tailnet → `172.16/12`（多半是 Docker 网桥）→ 其他。

app 侧还有三条规则，每一条都是踩出来的：

- **地址是现问的，不是配对时记的。** Bridle 在每个 `ready` 帧里带上它此刻的局域网地址，app 存下来覆盖配对码里那份。没有这个，一台换过网的 Mac 就永远只能走 Relay——手机拿着配对那天的地址空拨。发过的事故：Mac 从热点换到办公室网，`ready` 里播报的却是启动时缓存的热点地址，手机连着中继待了一上午。
- **只拨证明得了在同一网段的地址**（`isOnOurNetwork`，`getifaddrs` 比对子网）。这取代了"是不是 WiFi"这类猜测——后者在两头都会错：蜂窝下白拨，而 Mac 连着本机热点时反而不拨。判不了的（不是 IPv4 字面量的主机名、读不到网卡表）一律拨，因为误杀会让一条能用的路彻底隐形。
- **升级到局域网就是一次重连**，不是第二条隧道。关掉当前 socket，重连的竞速自然偏好本地，各条流随新的握手重新打开（§6.1）。曾经为"无缝切换"写过一百五十行含代际计数器的机器，删了。

> **为什么不用 ICE**：[RFC 8445](https://datatracker.ietf.org/doc/html/rfc8445) 是这个问题的通解，但它的候选收集、优先级公式、controlling/controlled 角色和 nomination 全部服务于 NAT 穿透——规范自己写明动机是"双方都在 NAT 后面时直连大概率失败"。我们不打洞，Relay 是永远能通的交会点而非最后手段，候选只有两类，没有可协商的东西。IPv4/IPv6 那一层的竞速 URLSession 已经在做。

> **P2P 是否值得做**：能把 Relay 从数据通道缩成信令（每次连接几百字节），但仍需信令点，且约 10-20% 对称 NAT 需要 TURN 兜底——而 TURN 就是中继。鉴于层 1-3 已经覆盖了绝大多数场景且成本为零，**P2P 的边际收益低于实现复杂度，暂不做**。

---

## 8. 两个入口，一份核心

Bridle 有两种装法，共享同一个 `BridleCore`：

| 形态 | 命令 | 适合 |
|---|---|---|
| 独立进程 | `bridle` | 需要独立托管，或以后指向别的 agent |
| dsh 插件 | 见下方 | 常见场景：跟着 dsh 起停，不必单独托管 |

插件**没有发布到 npm**，它随 `install.sh` 拉下的 checkout 一起分发，按本地绝对路径挂进 dsh profile 的
`cordis.patch.yml`。`bridle plugin install` 写这一行（`bridle/src/dsh/plugin-entry.ts`，只动它自己那一种形状，别的写法原样不碰并给出手工片段），`bridle plugin uninstall` 撤掉：

```yaml
- insert:
    - id: rowel-bridle
      name: "/absolute/path/to/rowel/dsh-plugin/lib/index.js"
```

**对 dsh 0.2 来说，插件不只是一种装法，还是登录的途径**：dsh 只把自己绑定的端口和 launch token 交给插件（§5.4）。独立进程形态只有在 Bridle 自己启动 dsh 时才拿得到 token；面对一个别人启动的 dsh，它只能靠之前存下的 cookie，或者提示去装插件（`dsh asks to sign in — run "bridle plugin install" and restart dsh`）。

插件可以配 `directPort`（局域网监听端口）。钉死而不是交给系统分配：手机的配对包记着它收到的直连地址，端口每次重启都换的话，等于悄悄退掉每一台已配对手机的局域网快路，把它们全赶到 relay 上。

**插件仍然走 loopback HTTP 连它自己所在的那个 dsh。**看起来浪费，实际不是：调用不出机器，与独立二进制同一条路径、同一套测试覆盖，**两者不会漂移**。插件文件因此是生命周期包装，不是第二份实现。

插件的两条契约由测试守着：`apply` 必须立刻返回（Cordis 并发挂载，慢插件拖住整个 harness）、`dispose` 不能抛（抛了会带崩整次 reload）。

### 8.1 一个身份只许一个 Bridle

两个入口带来一种真实碰撞：独立进程还在跑，用户又装了插件（或反过来）。两个 Bridle 读同一个 `ROWEL_HOME`，就以同一身份注册到 Relay——Relay 永远信最新的注册，于是两边互相顶替，以重试速度无限循环。两台机器都显示"在线"（每一方在被踢下去之前确实在线），没有任何一处报错，唯一的痕迹是 Relay 的请求量。实测过一次：两小时四千多次注册。

三层防御，各挡各的：

1. **门口的锁**：两个入口启动时都先查 `runtime.json`——pid 还活着且不是自己，就拒绝启动并说明谁占着、怎么办（停掉那个，或用 `ROWEL_HOME` 分家）。检查在一切副作用之前：插件若晚于 heartbeat 创建才退出，失败者会每 5 秒覆盖赢家的快照。
2. **退避靠稳定挣来**：注册成功不再重置重试间隔——身份战争里每次注册都"成功"。只有连接活过 `2 × RETRY_MAX`（60 秒）才回到 1 秒起点；战争中每一方恰好活对方的重试间隔那么久（上限 30 秒），所以门槛必须高于上限，否则战争会把速度挣回去。这挡的是锁够不着的场景：`~/.rowel` 被 dotfile 同步复制到第二台机器。
3. **Relay 记一行**：`register` 顶替旧连接时 `console.warn` 设备 id 和上一次注册距今的毫秒数。一次是笔记本睡醒，每隔几秒一次是战争——这是唯一能同时看见双方的视角。

---

## 9. iOS 端

### 9.1 状态所有权

```
AppModel        设备身份、已配对机器列表、当前连接的机器（同时只连一台）
 └ MachineSession  一台机器的一切：tunnel、会话列表、审批/提问、打开的会话
    └ Conversation  一个会话的折叠结果
```

**同时只连一台机器**是刻意的：每台机器一个 socket 就是每台机器唤醒一次射频，而"同时盯两台 Mac"的场景比电池代价罕见。切换 = 断开 + 连接，两者都快。

技术选型：SwiftUI + Observation（`@Observable`），iOS 17 起步，无第三方依赖。`Tunnel` 是 actor，`Store` 层 `@MainActor`。

**`MachineSession` 在每次握手（以及 Bridle 报 dsh 恢复）后打开这些流**（`attach`），每条都以全量开头：

| 流 / 调用 | 管什么 |
|---|---|
| `$events` | 审批与提问（waterfall）、`cancel`、会话列表的变化（`api-session/*`） |
| `workspace/follow` | 工作区与归档集合：`baseline`，之后增量 |
| `session/control` | 所有已载入会话的 projection：基线，之后逐键 |
| `session/list` | 每个 `$events` 客户端读一次（§9.4） |
| `session/follow` × 内存中的每个会话 | 快照整体替换窗口，之后是事件与流式帧；最多保留 8 个会话，淘汰即取消 |
| `session/page` | 向上翻页，按窗口的 `cursor` 读，拼在前面 |

暂时性失败（`busy`、`slow-consumer`、`timeout`、`internal`、`gateway/internal`）在隧道还在时按 1 秒起翻倍、30 秒封顶退避重开；连接丢失不自行重试，等下一次握手。快照超过帧上限时减半 `maxMessages` 重开。

### 9.2 UI 的几条硬规则

这些不是风格偏好，每一条都对应一个具体的失败模式：

1. **发送永不禁用。**离线、规划中、turn 跑到一半都能发，变的是 placeholder。信号一格时给个灰掉的按钮，比让消息排队差得多。
2. **健康的连接不显示任何东西。**"已连接"是噪音；状态行只在出问题时出现，并且说清楚该怎么办。
3. **不断言自己不知道的事。**连不上机器时不能说"dsh 没在跑"——没有隧道就没有远端信息。（这条是从一个真实 bug 来的：dsh 好好的，挂的是 Bridle。）
4. **破坏性操作要能被找到，也要说清代价。**"忘记某台 Mac"曾经只是一个滑动手势——而滑动手势唯一的发现方式是你已经知道它在。
5. **单向的事要说是单向的。**手机端取消配对不影响电脑端，界面必须写出来。
6. **同名实例必须可辨，诊断只到证据够得着的深度。**一台 Mac 可以跑多个 Bridle 身份；显示层派生后缀区分（冲突才出现），离线文案按结构化拨号证据分档收窄。全套设计与理由见 `docs/instance-awareness.md`。

### 9.3 会话分组：账本 + 规则，不只账本

dsh 的 workspace 成员表是个只进不补的账本：只有"创建进 workspace"的会话会被记账，workspace 建立之前的历史、Mac 终端里起的会话，永远不在里面，且没有任何公开调用能补录（`insertSessionBefore` 只做组内重排，组外直接拒绝）。照账本分组的结果实测过：112 个可见会话只有 18 个入组，其余全堆在 Ungrouped——而它们的目录就是某个 workspace 的目录。

`SessionBoard` 因此按两个来源就座：先账本，再账本所缓存的那条规则本身——**会话属于路径等于其工作目录的 workspace**。这条规则是 dsh 自己在 `attachSession` 里强制的（路径不等就拒绝），所以按 cwd 精确匹配就座，得到的分组与账本补全后会得到的完全一致，只是不等它补。前缀不算匹配（`~/code` 里的 workspace 不吞 `~/code/sub` 的会话），归档赢过一切。

新会话直接**建在 workspace 里**：`session/create {request: {workspaceId}}`，一次调用就写进账本，Mac 自己的侧边栏随之跟上；手机端的分组不依赖这次写入。目录还没有 workspace 时，先 `workspace/create` 把目录认下来，再建会话。不走"先按目录建、再归入"：dsh 0.2 的账本按字符串比对会话目录与 workspace 目录，而 workspace 的路径已经解析过（`/private/var/…` 对 `/var/…`），归入会被 `session/conflict` 拒绝；`cwd` 与 `workspaceId` 同时传也会被拒（协议参考 §12）。

因为账本只进不补，会话一旦生在还没有 workspace 的目录里，Mac 侧边栏就永远少这一行——`~/workspace/rowel` 那条正是 workspace 比会话晚两分钟建出来的结果。代价是 Mac 上会多出用户没在那里手工建过的分组：一行可删的分组，磁盘上什么都没有。机器的 `workspace/follow` 还没给出基线（或目录取的是 Mac 默认值、手机侧叫不出路径）时不动手，按目录建会话。这条只治将来：已经错位的历史行没有任何公开调用能补录。

### 9.4 会话、发送与审批的几条约定

- **列表重连**：`$events` 不重放断线期间的变化，也没有与列表快照共同的切点。所以每个 `$events` 客户端收到 `ready` 后读一次 `session/list`；读的期间到达的列表变化不应用、只记下"有变化"，读完若有变化就再读一次，以后读为准（迁移设计 D4）。
- **发送带 `requestId`**：dsh 把它记在消息的 `source.rpcId` 上，乐观显示的气泡和排队项靠它精确撤下，不按文字猜。结果不明的发送（答复在路上丢了）不重发——dsh 的去重在"出队到落盘"之间有竞态，重发可能产生两个回合——而是等快照说明它到没到。
- **排队区读 `inbox` projection**；把排队消息插进当前 turn 是 `session/updateQueue {action: {kind: "steer"}}`。
- **审批与提问**：卡片来自 `$events` 的 waterfall，按 `eventId` 标识；作答是 `$events/result {clientId, eventId, outcome}`，`clientId` 是送来这张卡的那条 `$events`。dsh 先到先得，别处答了会发 `cancel` 撤卡。每个新的 `$events` 客户端（重连、dsh 重启）先清掉旧卡，等 dsh 重发仍在等待的。
- **子代理**：子代理的会话只能经父会话的 subagent 地址读（`{kind: "subagent", parentSessionId, childSessionId, mode}`），用会话地址会得到 `session/agent-busy`；子代理发起的请求挂到父会话的卡片上。父子关系来自列表行（`origin: "subagent"` + `parentSessionId`）与父会话的 `subagentCatalog`。实测 dsh 0.2 默认以委托策略 `never` 运行子代理，子代理不弹审批。

---

## 10. 推送

**已实现并在真机跑通**（2026-08-20）。app 被挂起后隧道即断，此后 agent 每次停下来提问都落在一台没人告知的机器上——而"人在别处"正是这个产品的前提，所以这是常态而非边缘情况。

### 10.1 实际做法

```
app 拿到 APNs token → 经 Noise 隧道发 wake 帧给 Bridle，每次 ready 重发
Bridle 存进 PairedPeer.push
Bridle 自己的 $events 收到 approval/request 或 user-questions/request（waterfall）→ core.onWaitingChanged 触发
Bridle 检查 core.attached === 0（两种传输都没人）且 dueForRing 非空 → MuxType.Wake 让 Relay 振铃
Relay 用 APNs 密钥签 ES256 JWT，发一条固定文案的 alert 推送
手机显示横幅（不运行 app）→ 用户点开 → app 重连隧道 → 显示真实请求
```

横幅上的字是 `relay-worker/src/apns.ts` 里的常量加机器名。Worker 只从 wake 请求里读 `token` 和 `machine`（截到 64 字符），其余字段忽略——所以一条推送最多说出常量加 64 个字符的机器名，不靠 Relay 承诺不看。

### 10.2 放弃了 NSE，以及为什么

早期设计是 `mutable-content` + Notification Service Extension：Relay 搬不透明 blob，NSE 在设备上解密后替换成真实文字。为此要一套独立的长期推送密钥对、sealed box 封装、Keychain access group 共享、keyId 轮换、4 KB 载荷预算、以及一个新 target。

**没做，因为它买的东西比看上去少。**它买的是"横幅上直接显示 agent 问了什么"。而不做它的代价只是横幅上写一句通用的话，用户点开就看到真实内容——中间隔了一次点击。

用一个新 target、一套第二密钥体系、一条独立的轮换/吊销/重装/多设备语义，换一次点击，不划算。§10.4 那个真实的元数据泄露两种方案都消不掉。

**如果以后横幅太笼统成了真实抱怨**，NSE 那套设计仍然成立，上面几节的分析（尤其"NSE 拿不到隧道密钥，因为隧道密钥是每连接临时派生的"）依然是对的，可以照着实施。

### 10.3 用 alert 不用 silent

`content-available` 是更诱人的设计——醒来、取、发真实文案，连 NSE 都不用。但 iOS 把静默推送当可丢弃的：限流、低电量模式丢、app 被划掉后干脆不送。"能删掉这个吗"不能等系统心情好了再送。

### 10.4 诚实的泄露

Relay 必须知道 **device token**（它要调 APNs），因此能建立 `device token ↔ 某台机器` 的关联。

能否避免？只有让 Bridle 自己调 APNs——那需要把 APNs 私钥分发到每个用户的机器上，等于每个用户都握着能推给所有其他用户的钥匙，不可接受。

**所以这是一个真实的、不可消除的元数据泄露，必须写进隐私说明。**Relay 知道：deviceId、明文机器名、Bridle 版本、IP、谁连谁、搬了多少字节与时序、振铃时哪个 token 属于哪台机器，短码配对时还持有 bundle（公钥、局域网地址）。它不知道：任何内容。

Relay **不持久化** token——只在振铃那一刻从 Bridle 手里拿到，用完即弃。

### 10.5 三个反直觉的决定

| 决定 | 为什么 |
|---|---|
| 帧里不带 APNs 环境 | token 由沙盒还是生产主机签发，是苹果自己会回答的问题（错主机回 `BadDeviceToken`）。早期让 app 读自己描述文件里的 `aps-environment` 再逐层传下来——那是把猜测当事实，而且猜错时推送静默不到达 |
| 只有苹果说设备已消失才算 token 死了（410 / `Unregistered`，或生产与沙盒都回 `BadDeviceToken`；本地格式不合法的 token 也直接判死） | 早先把所有非 200 都当失效回传，于是一次限流、一次苹果 5xx、一个填错的 topic，都会让 Bridle 永久删掉一个好地址 |
| 欠下的振铃要记账 | 该不该振铃由 core 的待处理列表推导（`dueForRing`/`markRung`），注册完成时 `flushWake` 补发。Relay 离线时直接丢弃 = 那个问题永远不会有人被通知 |
| 每个请求只振一次 | "该不该振"会被反复重新判断——每次接入/离开、每次 Relay 重新注册（Mac 睡醒、换网络）。只看"有没有待处理"，同一个问题就会随每次重连再振一遍。core 记下已为哪些请求振过（`dueForRing` / `markRung`），请求被回答或删除时出账 |
| 待处理请求按每一代 `$events` 重建 | 请求活在 dsh 进程里，dsh 重启就没了，`cancel` 也不会来。所以 Bridle 的 `$events` 每次重开都清空"在等的"集合，以 dsh 重发的为准；"已振过"按稳定的 `eventId` 跨代保留，重开后 2 秒内没被重发的才出账——否则网络一抖，同一个请求会再振一次。在线的手机自己处理：新的 `$events` 客户端先清卡，再收 dsh 的重发 |

### 10.6 落点

| 位置 | 做什么 |
|---|---|
| `protocol/src/frames.ts` | `wake` 帧（app→Bridle） |
| `protocol/src/mux.ts` | `MuxType.Wake`（双向：请求振铃 / 回传失效 token） |
| `ios/Rowel/App/Push.swift` | 每次启动和回前台向 iOS 要 token |
| `ios/Rowel/Net/Tunnel.swift` | 每次 `ready` 重发 token |
| `bridle/src/core.ts` | 自己的只读 `$events`、按 `eventId` 的 `dueForRing`/`markRung`、`onWaitingChanged` 钩子、接入计数 |
| `bridle/src/relay-client.ts` | 判断无人接入、按 token 去重、欠账补发 |
| `relay-worker/src/apns.ts` | ES256 签名、生产→沙盒回退、错误分类 |
| `ios/Rowel/Rowel.entitlements` | `aps-environment`（付费会员才签得下来） |

配置见 `docs/deployment.md` 的 APNs 一节：四条 `ROWEL_APNS_*` secret，缺一个则 Relay 不振铃任何人，其余功能不受影响。

---

## 11. 待建：定时任务

dsh **有**调度能力（`@deepseek-ai/dsh-schedule`），但有三个限制：

1. 只有**模型**能调（`schedule_create` / `list` / `delete` 是会话内工具），客户端方法里没有 `schedule.*`
2. `deliveryMode: "session-local"`——到点只是在那个会话里塞一轮，不通知任何人
3. 分叉不继承提醒

所以 webui 上没有入口，任何客户端都没有。**这是一个真空。**

> 上面三条是对 dsh 0.1 的调查。dsh 0.2 的 `dsh-schedule` 包声明了客户端端点（`schedule/list`、`schedule/catalog`、`schedule/update`、`schedule/delete`、`schedule/history` 等，`schedule/changed` 也在 `$events` 的转发白名单里），还多了 `dsh-client-ui-schedule`。这些端点的行为没有实测；实施前先在 0.2 上重新核实这三条限制，很可能真空已经不在了，要做的只剩手机入口和推送桥接。

### 落点：管理适配层，不是第二个调度器

**必须复用 `@deepseek-ai/dsh-schedule` 的存储与触发器。**我们缺的是客户端入口和完成后的推送桥接，不是一套新的调度实现。

```
dsh-schedule-plugin/     把上游的 schedule_* 暴露成 schedule.list/create/delete
                         读写同一份任务存储，复用同一个触发器
bridle/src/push.ts       监听上游的分发事件 → 触发推送
ios/Views/Schedule*.swift 清单、新建、删除
```

**实施前必须先验证**：上游有没有稳定可监听的分发事件、可复用的内部接口。有就接上去；没有就**先给上游提一个薄钩子**，而不是自己另造存储。

自己造的后果很具体：模型用 `schedule_create` 建的任务和 app 建的任务会变成**两份清单、两套生命周期**，而用户完全不知道为什么手机上看不到自己刚让 agent 定的提醒。上游还处理了时区、重启恢复、分叉不继承这些细节，重写一遍等于重新踩一遍。

**依赖推送。**没有推送，定时跑完了你还是不知道，与现状无异。因此**排在推送之后，不并行**。

两者合起来是「每天早上 9 点让 agent 跑一件事，跑完推到锁屏上」——调研中 15 个有牵引力的产品，没有一个做到。

---

## 12. 待建：多 agent

当前钉死 dsh 0.2 的私有接口，而且是原样透传：**深度上赢，可移植性上输**。

ACP（Agent Client Protocol）是长尾项目的事实标准，registry 有 38 个已验证 agent。但排名前三的产品都不用它——ACP 抹平差异的同时也抹掉了各家 harness 的独有能力。**dsh 目前不在 ACP registry 里。**

### 结论与落点

**不追求"一套吃所有"，而是保留接第二个后端的能力。**

```
bridle/src/agents/
  types.ts        AgentClient interface（§4.1）
  dsh/            现有实现
  acp/            以后
```

app 侧需要一个能力协商：ACP 后端缺少 dsh 的事件日志、projection、`$events` 审批等，UI 必须明确标出"这个后端不支持 X"，而不是静默降级。

**这不是现在的问题。**先做深度，等 dsh 热度回落或用户真的要切 agent 再说。

---

## 13. 待建：trace

webui 的轨迹是**横向甘特图**（Turn / Request #N / TOOL 逐行铺开，可拖时间轴）。那是给宽屏做的，塞进 393pt 只会变成一坨。

**不照抄形态，只取信息。**手机上做成纵向一列：每个 turn 一张卡，展开看它的每次请求和工具调用，各带耗时与 token 速率。

数据来源：`sessionStats` + `tokenUsage` projection（§3.2，白拿）+ 事件日志里的 `step/start` `step/end` `request/header`。**不需要新 API。**

---

## 14. 版本兼容

app 和 Bridle 各自更新，不保证同步。上架之后这不是例外而是常态：商店审核有延迟、用户不升级、Bridle 有插件和独立二进制两种形态可各自更新。

### 14.1 之前的设计是错的

原设计把隧道版本混进 Noise prologue（形如 `rowel-tunnel/v1`，而非现在的 `rowel-tunnel`），版本不匹配则握手失败，并声称此时发 `fault{reason:"version"}` 让 app 提示"更新较旧的那一端"。

**这句话做不到。**prologue 不同会让响应方在解密握手消息一时就失败——此时安全通道还没建立，任何拒绝都发不出去，也无法被认证。客户端只能看到"握手失败"，无法区分三种完全不同的情况：版本偏斜、连错了机器、被中间人篡改。

而且"不做向后兼容"在一个会上架的产品上等价于：**任何一次版本推进都硬断一批用户，且他们看不到原因。**

### 14.2 版本移出 prologue，进握手载荷

```
prologue = "rowel-tunnel"        ← 稳定的协议族标识，永不变
```

版本改为在**握手载荷里协商**。这行得通的原因是一个不对称性：响应方**总能**解密消息一（prologue 一致即可），因此总能读到发起方声明的版本，也总能用消息二发回一个**已认证的**拒绝。

```
消息一载荷   { versions: [2, 1], name, client, token? }   发起方支持的版本，偏好在前
消息二载荷   { ok: true,  version: 2, machine, bridle }    响应方选定的共同版本
             { ok: false, reason: "version", supported: [3, 4] }   无交集时
```

选定规则：响应方取**双方都支持的最高版本**。之后双方都按该版本讲话。

无交集时的拒绝是可读的，app 因此能说出**具体哪一端旧了**——比较 `supported` 与自己的列表即可。

### 14.3 兼容窗口

- **原则：至少同时支持当前版与上一版**（N 与 N−1）
- 推新版的顺序固定：**先发能接受双版本的 Bridle，再灰度 app**
- 只有当旧版本占比降到阈值以下，才移除对它的支持
- 每次版本推进必须跑新旧双向互通测试：新 app ↔ 旧 Bridle、旧 app ↔ 新 Bridle

**版本 2 是写明的例外**（`docs/protocol.md` §4.6）：版本 1 是 dsh 0.1 接口的透传，dsh 0.2 删掉了那套接口，owner 决定不保留翻译层，也不做同时对接两代 dsh 的双栈（迁移设计 §0、D6）。所以 Bridle 0.2 只支持 `[2]`，app 1.1 只说 2。只会说版本 1 的一端在握手时收到已认证的 `{ok:false, reason:"version", supported:[2]}`，能据此说出哪一端旧了——这正是 §14.2 的协商机制在起作用。e2e 的 `an app that only speaks version 1 is refused, and told so` 盯着这条。发布顺序避免任何时刻"新 app 配旧 Bridle"成为默认，见迁移设计 D7。

### 14.4 移出 prologue 那一次断（已完成）

把版本移出 prologue 是**破坏性的**：带版本后缀的 prologue 一旦改动，握手必然失败，所有已配对设备需要重新配对——所以这件事必须赶在公开发布之前做完，它也确实在那之前做完了。

这是协议最后一次在没有协商机制的情况下破坏兼容。之后的版本 2 是经协商、可读地拒绝，不是握手失败。

### 14.5 应用层始终向前兼容

未知帧类型、未知事件类型、未知工具，一律容忍（§2、§3.3、`fold.md` §2.2）。这条独立于版本协商：即使版本相同，一端也可能带着另一端不认识的扩展。

对接口变化的另一道防线不在协议里，在 CI：`dsh 0.2.0-rc.2` 契约任务对钉住的版本跑读、写、断线三类契约；`dsh-drift.yml` 每周对 dsh 的 `@latest` 与 `@alpha` 跑同一套，接口变化在进入默认安装之前就被发现（迁移设计 D8）。

---

## 15. 测试策略

```
向量对齐    protocol/scripts/emit-vectors.js → Swift 逐字节
              证明：两份实现是同一个协议
单元        TS（npm test）· iOS（npm run test:ios）
              证明：折叠、解析、加载与重连、限流、地址选择、插件生命周期；
              iOS 的一批喂真 dsh 0.2 的录制（ios/RowelTests/Fixtures/dsh-0.2），
              并按录制核对 app 发出的参数
e2e         起真 Relay + 真 Bridle + 脚本手机
              对真 dsh 0.2（一次性 DSH_HOME、临时 HOME、空环境）：登录、读写契约、
                跟随会话、重连后的新快照；ROWEL_E2E_MODEL=1 时加真实模型回合、
                真实审批（多手机先答者生效、断线重发）、排队/steer/取消、子代理
              对假 agent：审批与提问的完整往返、帧上限、推送
UI          XCUITest，模拟器或真机，连真 Bridle
              证明：点了真的有反应
```

四层各自证明不同的东西，都不可省：

- 没有向量，两端可以各自自洽地跑但互不兼容
- 没有单元测试，折叠的边界情况（重复 seq、乱序 projection、孤儿工具结果、快照替换）无法覆盖
- 没有 e2e，安全属性只是断言而非事实——`the relay only ever sees ciphertext` 必须是可执行的
- 没有 UI 测试，"能编译"和"能用"之间还有一整个鸿沟

**为什么大部分审批测试用假 agent。**审批只在模型决定要做需要批准的事时发生，等它发生不是测试而是碰运气。`e2e/src/fake-agent.ts` 实现 §4.1 那个接口，`$events` 的行为照 dsh 0.2（每个新客户端一个 `ready` 加所有仍在等待的请求、先答者生效、迟到的回答无害），让测试能在选定的时刻抛出一个审批——它上面的一切（隧道、流映射、回传路径）都是真的。真实模型下的审批另有 `e2e/tests/model.test.js`（只读档位下让模型写文件，约 6 秒触发），要花模型额度，默认跳过。

这同时是**接缝为真的证据**：如果 `AgentClient` 偷偷多长出一个要求，这个文件编译不过。

> 早期文档声称 e2e 已经覆盖审批。它没有——一条都没有，"代码存在"顶替了"链路能用"。这是 deep review 抓到的，也是四层测试本该在 e2e 层抓到却漏掉的。

**UI 测试与单元测试分属两个 scheme**（`Rowel` / `RowelUI`）：单元测试到处都能跑、几秒钟；UI 测试需要一台配对好的机器、几分钟。合在一起会让每次 `npm run test:ios` 都等一台可能没开的电脑。

---

## 16. 不变量清单

以下每条都有测试守着。**改动使任何一条失效，就是改错了。**

| # | 不变量 | 守卫 |
|---|---|---|
| 1 | Relay 读不到内容 | e2e `the relay only ever sees ciphertext`（本机有 dsh 时跑，打 Node relay，不在 CI） |
| 2 | 直连监听器不是 web 服务器 | e2e `the direct listener is not a web server` |
| 3 | 配对令牌一次性 | e2e `a stolen pairing token works exactly once` |
| 4 | 吊销在下一次握手生效（已开隧道要重启 bridle 才断） | e2e `a revoked device cannot come back` |
| 5 | 篡改帧撕毁隧道，不被接受 | e2e `a tampered frame tears the tunnel down` |
| 6 | 错误的机器密钥无法完成握手 | e2e `a device believing the wrong machine key…` |
| 7 | 重连后重开得到新快照，回到同一位置 | e2e `after a reconnect, reopening a conversation gives a fresh snapshot of the same place`；iOS `testAReconnectReplacesTheWindowWithAFreshSnapshot` |
| 8 | 两份协议实现逐字节一致 | `ParityTests` |
| 9 | 折叠幂等（同一 seq 不双渲染） | `testDuplicateSequenceIsIgnored` |
| 10 | 未知事件静默，不渲染噪音 | `testUnknownEventIsSilent` |
| 11 | 超过帧上限只失败那一个调用或那一条流，隧道不动 | e2e `an answer too big for the tunnel fails the call instead of the connection`、`a stream item too big for the tunnel ends that stream and nothing else` |
| 12 | 插件 apply 不阻塞、dispose 不抛 | `dsh-plugin/tests/plugin.test.js` |
| 13 | 版本不匹配时拒绝是**已认证且可读**的，不是握手失败 | e2e `an app that only speaks version 1 is refused, and told so`、`a client from the future is refused in a way it can act on` |
| 14 | app 发出的参数与真 dsh 0.2 接受的一致 | iOS 按录制核对（`PresetAndPluginTests` 等）；CI 的 dsh 契约任务 |

---

## 16.5 「比 webui 好用」的验收基准

产品目标写着"体验明显好过 dsh 自带 webui"。没有定义的目标不能被达成，也不能被证伪——所以定义在这里。

**判据不是功能数量，是"离开电脑后能不能把一件事做完"。**逐项对照，每项只能填三种状态之一：支持 / 有移动端替代 / 明确放弃。

| 工作流 | webui | 我们 | 状态 |
|---|---|---|---|
| 看有哪些会话、哪个要我处理 | ✓ | ✓ 且"Needs you"排在最前 | **更好** |
| 打开会话看完整历史 | ✓ | ✓ | 支持 |
| 发消息、看流式回复 | ✓ | ✓ | 支持 |
| 看工具做了什么（diff/终端/搜索） | ✓ | ✓ | 支持 |
| 批准或拒绝一个工具 | ✓ | ✓ | 支持 |
| 回答 agent 的提问 | ✓ | ✓ | 支持 |
| 中断跑飞的任务 | ✓ | ✓ | 支持 |
| 换模型 | ✓ | ✓ 且能设新会话默认 | **更好** |
| 新建会话并选目录 | ✓ | ✓ | 支持 |
| **切换访问模式** | ✓ | ✓ 会话级，Session ▸ Access | 支持 |
| **斜杠命令** | ✓ | ✓ `commands/list` + `commands/execute` | 支持 |
| **看 subagent** | ✓ | ✓ 只读，经父会话地址读 | 支持（干预明确不做） |
| **失败诊断（trace）** | ✓ 甘特图 | ✗ | 缺口，形态要重做（§13） |
| 上下文占用明细 | ✓ | 只有百分比 | 部分 |
| 推理等级 | ✓ | ✓ 随模型选择 | 支持 |
| 分叉 / 归档会话 | ✓ | ✓ | 支持 |
| 工作区增删改 | ✓ | ✗ | **明确放弃**（§17） |
| 插件管理、改设置、写 API key | ✓ | ✗ | **明确放弃**（§17） |

**首发门槛**：斜杠命令、subagent 已补齐——它们是"离开电脑后完成一次完整任务"的必要条件。trace 不是，它是诊断而非操作。访问模式的补法值得记下来：切换一个会话的模式走的是 dsh 的 `/permission` 命令（`commands/execute`，参数 `{agentId, line, submittedAttachments}`），**不是** `settings/update {ns: permission}`——后者只改新会话的默认值，改不动已经在跑的会话，早期正因为只试了这条路径才误判成"会话创建后不可改"。

**我们已经更好的地方**（这才是产品理由，不是功能对等）：

- 「Needs you」把等待你的会话顶到最前，webui 要自己翻
- 中继是兜底不是路径，webui 没有这个概念
- 新会话默认模型，webui 没有
- 推送（已做）——webui 根本不可能有

---

## 17. 明确不做

| 不做 | 理由 |
|---|---|
| 工作区排序（`workspace/insertBefore` / `insertSessionBefore`） | 手机端按活跃度排序，Mac 的手排顺序在这里不可见；后者也搬不动会话（§9.3） |
| 插件管理 | 同上；且在手机上装插件是奇怪的动作 |
| `settings/*`（新会话默认访问模式除外）/ `credentials/*` | 写 API key、改 provider 的能力延伸到手机，等于把管理面搬上手机；不做白名单（§5.4）不等于 app 要去调它们 |
| 点赞点踩 | 反馈遥测，对自用无价值 |
| 横向甘特图 trace | 见 §13 |
| P2P 打洞 | 见 §7 |
| Android | 不是不做，是现在不做。协议与折叠逻辑可移植，UI 不可 |
| 一机一配对 + dsh 实例多路复用 | 考虑过并否决（`docs/one-pair-per-mac.md`）：多 dsh 是罕见场景，已由第二 `ROWEL_HOME` 身份覆盖（锁/后缀/工具俱全）；为它新建协议字段与引擎层是给罕见场景买优雅，维护面不划算 |

**把电脑的管理面搬到手机上，只会让界面变成 webui 的缩小版**——那正是要避免的。

---

## 18. 已知代价

诚实清单。每一条都是主动选择，不是疏忽。

1. **配对设备 = dsh 完整权限**（§5.4）。无细粒度授权，因为 dsh 无此概念。
2. **Relay 知道 device token ↔ 机器的关联**（§10.4）。推送落地后不可消除。
3. **同时只连一台机器**（§9.1）。换电池换来的。
4. **绑定 dsh**（§12）。深度换可移植性。
5. **折叠成本在客户端**。大会话首次加载仍然重；快照只取 25 条消息、超限减半，缓解但没消除。
6. **版本 2 不兼容版本 1**（§14.3）。dsh 0.1 与 0.2 之间不做双栈，旧组合由不再改动的 Bridle 0.1.x 覆盖。
7. **dsh 改接口时修复要靠 app 发版**（§2）。透传换来的是 Bridle 不必跟着 dsh 发版，代价是 App Store 审核的那几天；CI 每周跑 `@alpha` 是为了把这几天提前。
8. **iOS 独占**。

### 什么时候重新评估

主动选择的边界必须有复评触发条件，否则"现在不做"会静默变成永久结论。

| 边界 | 复评触发 |
|---|---|
| iOS 独占 | 候补名单里安卓占比 > 30%，或有人明确因此放弃 |
| 绑定 dsh | dsh 的 star 增速转负，或 ≥3 个用户要求接别的 agent |
| 同时只连一台机器 | 有用户报告频繁切换机器 |
| 不做 trace | 出现 ≥3 次"任务失败了但看不出为什么"的反馈 |
| 不做工作区管理 | 有人真的在手机上需要建工作区（我预期不会） |

**这些数字是拍的，但有数字才能被证伪。**没有候补名单就先建一个——不建就永远没有数据，"以后再说"就成了默认答案。

9. ~~**推送依赖付费 Apple 账号**（§10.6）~~。已解决：2026-08 开通 Developer Program，推送、TestFlight、上架都已走通。
10. ~~**版本移出 prologue 会破坏现有配对一次**（§14.4）~~。已在公开发布前完成。
11. **Relay 会持有 APNs 私钥**（§10.4）。它从"只搬密文的哑管道"变成"还持有一份对外发送凭据"，这是推送带来的、不可避免的信任面扩大。

---

## 附：新功能该往哪放

| 想加什么 | 改哪 | 大概规模 |
|---|---|---|
| 调一个新的 dsh 端点 | `Harness.swift` 加函数（参数名照 dsh 声明）+ 调用它的视图；先用 `capture-fixtures.mjs` 录一份回答 | 几十行 |
| 显示一个新 projection | `Conversation.applyProjection` 一个 case + 视图 | 几十行 |
| 支持一种新工具卡片 | `callPresentation`/`resultPresentation` + `ToolCardView` | 上百行 |
| 访问模式切换 | `permissions` projection（读）+ `commands/execute` 跑 `/permission`（写）+ Session 面板 | 已做 |
| 斜杠命令 | 已做：`commands/list` 进输入框菜单 + 命中命令走 `commands/execute`（**不是** `session/prompt`——斜杠开头的文本会被当成消息发给模型），结果由 `command/run|done` 折叠成一行 |
| subagent | 已做（只读）：父会话的 `subagentCatalog` + 列表行定父子，经 subagent 地址 follow/page | — |
| 推送 | §10 六处 | 已做 |
| 定时任务 | §11 三处 | 一到两天，依赖推送 |
| 第二个 agent 后端 | §12，先提 interface | 数天 |
