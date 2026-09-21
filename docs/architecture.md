# Rowel 技术架构

本文档描述 Rowel 的整体设计、每个接缝的契约、以及新功能应该落在哪里。它同时是一份**扩展指南**——未做的功能（推送、定时任务、多 agent、trace）在这里有明确的落点，实施时不需要重新设计。

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
- 版本协商（**已修订**）：§14
- 版本兼容：§14
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

- **Relay 不理解内容**——它只有密文，连方法名都看不到。
- **Bridle 只解释被明确列出的控制语义**——转发方法调用和事件帧时不看内容。允许它读的只有两处，各自有界：§3.4 的历史瘦身（丢弃冗余，不解释语义），以及 §10 的通知判定（识别审批/提问/turn 结束，产出告警——这确实是业务语义，所以它属于 dsh 适配层而不是隧道层）。

  > 早期版本称瘦身是"唯一的例外"，同时又在 §10、§11 要求 Bridle 识别审批与调度事件。deep review 指出这是自相矛盾。原则改写成上面这句：**例外必须被列出，而不是被称为不存在。**
- **只有 app 折叠**——`Conversation` 是唯一知道 `assistant/chunk` 该拼进哪个气泡的地方。

### 为什么这样是对的

**折叠是纯函数。**`items = fold(events)`。这带来三个白拿的性质：

1. **断线重连只要补上缺的事件**，不需要重新同步状态——重放收敛到同一个结果。
2. **历史分页和实时流用同一条代码路径**，`seq` 去重，一页历史盖住实时流的一段不会双渲染。
3. **可测**——51 个 iOS 单元测试里大半是喂事件、断言 `items`，不需要网络也不需要 UI。

**中间层不理解内容，所以中间层不需要跟着功能升级。**dsh 加一个事件类型、一种工具卡片、一个 projection，Bridle 和 Relay 一行都不用改。这是本项目最重要的可维护性性质，§3 把它具体化成三个扩展点。

### 代价

- **app 必须容忍未知**。不认识的事件类型静默丢弃（`Conversation.apply` 的 `default` 分支），不认识的工具卡片降级成 `.generic`。写死枚举会让插件生态每装一个东西就崩一次。
- **折叠成本在客户端**。一个流式密集的会话，50 条消息可能对应 12 万条事件。§3.4 是对这个代价的直接回应。

---

## 3. 三个扩展点

**大多数**功能待办会落在这三个口子之一，改动是局部的。但不是全部——下面 §3.5 列出落不进去的那几类，那是真实的结构性工作，不该被这套说辞粉饰成增量。

> 早期版本这里写的是"每一项都只会落在这三个口子之一"，以及"改三个以上文件即接缝错误"。deep review 用待办清单压测后证伪了：定时任务要服务端作业、subagent 是独立会话树、trace 要跨事件聚合，三者都不属于"透传方法 / 折叠 projection / 渲染意图"。断言已删除。

### 3.1 新方法：透传，零改动

dsh 有 44 个客户端方法。app 调用其中任意一个，只需要在 `ios/Rowel/Net/Harness.swift` 加一个函数：

```swift
public func fork(sessionId: String) async throws -> String {
    try await tunnel.call("session.fork", .object(["sessionId": .string(sessionId)]))
        ["sessionId"]?.stringValue ?? ""
}
```

Bridle 的 `handleRequest` 是完全泛型的——`method` 是字符串，`payload` 是不透明值。**Bridle 不需要知道 `session.fork` 存在。**

> 唯一的例外是 `session.export`（要处理二进制 zip → base64）和 `session.history`（瘦身）。两个特判都写在 `bridle/src/tunnel/session.ts` 的一处 switch 里，看得见。

### 3.2 新 projection：一个 case

dsh 每个会话带 13 个 projection，我们目前折叠了 4 个。加一个是 `Conversation.applyProjection` 里的一个 case：

```swift
case "permissions":
    permissions = PermissionState(value)
```

**projection 的传输是白拿的**——它们已经在历史页的 `projections` 基线块里，也已经通过 `session/projection` 帧实时下发。不需要新请求，不需要碰 Bridle。

现有 13 个：

| projection | 用了吗 | 内容 |
|---|---|---|
| `title` `todos` `contextPressure` `plan` | ✓ | 标题、清单、上下文占用、计划模式 |
| `permissions` | — | `{options[], currentValue}`，访问模式 |
| `sessionStats` | — | turns / steps / llmMs / toolMs / ttftMs / decodeTokens |
| `contextBreakdown` | — | 系统提示词 / 工具 / 消息 各占多少 token |
| `tokenUsage` | — | 缓存命中、输入输出 |
| `subagent` `subagentTiming` | — | 子 agent 状态与耗时 |
| `goal` | — | 长任务目标 |
| `sessionListMetadata` `imageLimits` | — | 列表元数据、图片上限 |

### 3.3 新工具卡片：一个 case

dsh 在事件旁边附一份**渲染意图**（`view`），host 已经算好了这个工具该怎么画。app 把它翻译成 `ToolPresentation` 的一个 case：

```
generic · terminal · diff · search · read
```

新增一种卡片 = `Conversation.callPresentation` / `resultPresentation` 各加一个 case，`ToolCardView` 加一个分支。

**关键性质：app 永远不需要知道某个具体工具是干什么的。**`bash`、`read`、某个插件自定义的工具，都只是"带着渲染意图的一次调用"。不认识的意图降级成 `.generic`，显示标题和原始输入——退化，不是崩溃。

### 3.4 反向扩展点：Bridle 的瘦身钩子

三个扩展点都是"加东西"，还有一个"减东西"的位置值得单独说，因为它是本项目唯一允许 Bridle 碰内容的地方。

`bridle/src/tunnel/history.ts` 的 `thinHistory` 剥掉已提交消息的 `assistant/chunk`。实测：一页 50 条消息 = 120,397 事件 / 22 MB，剥完剩 305 条。

**为什么这不违反"中间层不理解内容"**：它丢弃的是**同一信息的冗余表示**——committed 消息的完整内容已经在 `assistant/message` 里，chunk 只对还没提交的那条有意义。规则一行话："同一个 `turn.step` 已有 message，就丢掉它的 chunk"。它不解释语义，只去重。

**边界**：任何需要理解"这条消息说了什么"才能做的裁剪，都不属于这里，属于 app。

### 3.5 落不进三个口子的那几类

| 扩展类型 | 例子 | 状态归谁 | 上下行 | 断线恢复 | 为什么不是前三类 |
|---|---|---|---|---|---|
| **请求命令** | `session.fork` `workspace.archiveSession` | 无（一次性） | `req`/`res` | 重试即可 | ← §3.1 |
| **复制状态** | 访问模式、上下文明细、统计 | agent，app 只读 | projection 帧 | 重放收敛 | ← §3.2 |
| **渲染提示** | terminal / diff / search 卡片 | 事件旁的 `view` | 随事件 | 重放收敛 | ← §3.3 |
| **读写状态** | 切换访问模式 | agent | projection 读 + 方法写 | 写要幂等 | 读是 §3.2，**写不是**——要处理并发修改与失败回滚 |
| **会话图** | subagent | agent，**独立会话树** | `subagent.*` 四个方法 + 各自的事件流 | 每棵树各自重放 | 不是当前会话的派生状态，是**另一批会话** |
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
                 │  TunnelSession  握手 / 帧循环          │
                 │  BridleCore     身份 / 事件日志 / 状态 │
                 │  AgentClient    ← 唯一的 agent 适配面  │
                 └──────────────┬───────────────────────┘
                                │  loopback HTTP + WS
                                ▼
                          dsh (127.0.0.1:3080)
```

**依赖只向下。**`Views` 不 import `Net`，`Net` 不知道 `Views` 存在。Bridle 的 `TunnelSession` 通过 `BridleCore` 拿 agent，不直接构造。

### 4.1 agent 适配面

这是可扩展性最重要的一条边。整个 agent 侧的接触面是**五个方法**：

```ts
interface AgentClient {
  call(method: string, payload: unknown, signal?: AbortSignal): Promise<AgentResult>
  respond(message: unknown): Promise<unknown>
  health(): Promise<AgentHealth>
  pump(stream: 'mux' | 'host', onFrame, onState, signal): void
  export(sessionId: string, includeDescendants: boolean): Promise<Response>
}
```

`BridleCore` 已经写成可注入：`constructor(state, overrides: { dsh?: AgentClient })`。

接口现在真的存在（`bridle/src/agents/types.ts`），`DshClient` 声明实现它，`BridleCore` 只认接口。`e2e/src/fake-agent.ts` 是第二个实现，它编译得过这件事本身就是接缝为真的证明。

> **但接口存在 ≠ 第二个 agent 快做完。**这五个方法仍然带着 dsh 的形状：`pump` 点名了 dsh 的两条下行流，`respond` 收的是 dsh 的 `client-response` 信封，`pump` 吐出来的帧是 dsh 的 `server-request` 原样。app 侧的 projection、渲染意图、审批批次也一样。**第二个后端需要的是这个接口之上的一层归一化，而不是这个接口的另一个实现。**早期文档说"20 行重构、不改任何调用方"，那是低估。见 §12。

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
| 手机推送私钥（X25519） | Keychain 共享组，`afterFirstUnlockThisDeviceOnly` | 长期，可轮换；app 与通知扩展共用 |
| 配对令牌 | 状态文件，带过期 | **一次性**，用掉即废 |

**密钥不复用。**签名用 Ed25519，DH 用 X25519，对称加密用握手派生的传输密钥——三者独立。把一个 32 字节秘密同时当 SecretBox key、Ed25519 seed 和 X25519 私钥用，是明确的密码学异味。

### 5.3 配对的两条路

**二维码**（默认）：配对码直接带着机器的静态公钥，手机在第一个字节之前就知道对方是谁。恶意 Relay 无法介入。

**短码**（扫不了码时）：手机从 Relay 换取配对载荷，而 Relay 可能撒谎。所以握手完成后**两端各显示一个 6 位数字**，从 handshake hash 派生：

```
digits = BE_uint32(sha256("rowel-confirm" ‖ handshakeHash)[0..4]) mod 10^6
```

数字相同 ⇒ 两端的握手记录一致 ⇒ 没有中间人。这是 Bluetooth 数字比对的同一套逻辑。

### 5.4 dsh 没有认证层，这是设计的中心事实

dsh 的安全模型是「只绑 loopback + Host 头信任栅栏」。Bridle 与它同机，请求源是回环、`Host: 127.0.0.1:3080`，天然通过栅栏——**dsh 端零配置，不需要 `--trusted-host`**。

**因此 Bridle 不能是哑转发器。**`socat` 把 `0.0.0.0:3080 → 127.0.0.1:3080` 一转，就等于把一个无认证的远程代码执行接口暴露给整个网段。

Bridle 补回了 dsh 故意不做的认证：

- 监听器**只讲 Noise 隧道**，非 WebSocket upgrade 一律 `426`，不吐一个字节的 API（`direct-server.ts`）
- 未配对设备完不成 IK 握手
- e2e 测试 `the direct listener is not a web server` 盯着这条

**推论也要说清楚：配对进来的设备 = dsh 的完整权限。**Bridle 不做细粒度授权，因为 dsh 本身没有这个概念。`bridle revoke` 是唯一的**收回**手段。这是产品必须诚实告知用户的事。

### 5.5 手机丢了怎么办

上面那条推论有个直接后果：一部**已解锁**的已配对手机，就是一个不再需要任何凭证的远程 shell。系统锁屏挡不住这个场景——手机被递出去、在餐桌上被顺走、放在工位上没锁——它本来就是解锁状态。

app 自己那把锁（`ios/Rowel/Store/AppLock.swift`）不解决这件事，它只给这个窗口设一个上限：

| 机制 | 做什么 | 为什么是这个选择 |
|---|---|---|
| 冷启动即锁 | 从外部进来一次就要认证一次 | 启动是唯一能确定"刚才不在手里"的时刻 |
| 闲置超时 | 可配：立即 / 1 / 5 / 15 分钟 / 1 小时，默认 1 分钟 | 默认要短到有意义，又不能让"切出去看条消息"都要刷脸 |
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

单条隧道复用全部流量，手机只持有一个 socket。

| 帧 | 方向 | 语义 |
|---|---|---|
| `req {id, method, payload}` | app→bridle | 一元调用 |
| `res {id, result}` | bridle→app | 应答 |
| `cancel {id}` | app→bridle | 放弃在途请求 |
| `respond {id, message}` | app→bridle | 回答审批/提问 |
| `ev {seq, stream, frame}` | bridle→app | 下行事件，带隧道级序号 |
| `resume {since}` | app→bridle | 重连后补齐 |
| `resync {from}` | bridle→app | 缓冲不够了，重新拉状态 |
| `ready` `status` `ping` `pong` `fault` | 双向 | 生命周期 |

### 6.1 无损重连

Bridle 持有一个环形缓冲（`tunnel/event-log.ts`），事件带单调递增 `seq`。重连时 app 发 `resume{since}`，Bridle 重放缺口。

**缓冲不够时不静默丢弃，而是发 `resync{from}`。**app 收到后重新拉取**屏幕上正在显示的**会话历史，而不是全部。

> 这一条是刻意的：调研显示"重连丢东西 / 静默挂死"是整个品类的第一痛点。静默丢帧会让折叠结果与真相不一致，而且永远不会自愈。显式告知虽然更吵，但可自愈。

### 6.2 字节级对齐

协议在 TS 和 Swift 里各实现一遍。**"我自己写的服务器能连上我自己写的客户端"证明不了任何事**，所以：

`protocol/scripts/emit-vectors.js` 用固定密钥、固定临时密钥跑出确定性向量，Swift 侧逐字节比对握手消息、handshake hash、确认数、传输层密文、配对链接、帧编码。

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
- **升级到局域网就是一次重连**，不是第二条隧道。关掉当前 socket，重连的竞速自然偏好本地，`resume` 按序号补齐。曾经为"无缝切换"写过一百五十行含代际计数器的机器，删了。

> **为什么不用 ICE**：[RFC 8445](https://datatracker.ietf.org/doc/html/rfc8445) 是这个问题的通解，但它的候选收集、优先级公式、controlling/controlled 角色和 nomination 全部服务于 NAT 穿透——规范自己写明动机是"双方都在 NAT 后面时直连大概率失败"。我们不打洞，Relay 是永远能通的交会点而非最后手段，候选只有两类，没有可协商的东西。IPv4/IPv6 那一层的竞速 URLSession 已经在做。

> **P2P 是否值得做**：能把 Relay 从数据通道缩成信令（每次连接几百字节），但仍需信令点，且约 10-20% 对称 NAT 需要 TURN 兜底——而 TURN 就是中继。鉴于层 1-3 已经覆盖了绝大多数场景且成本为零，**P2P 的边际收益低于实现复杂度，暂不做**。

---

## 8. 两个入口，一份核心

Bridle 有两种装法，共享同一个 `BridleCore`：

| 形态 | 命令 | 适合 |
|---|---|---|
| 独立进程 | `bridle` | 需要独立托管，或以后指向别的 agent |
| dsh 插件 | 见下方 | 常见场景：跟着 dsh 起停，不必单独托管 |

`@rowel/bridle-plugin` **尚未发布到 npm**，所以 `dsh plugin add @rowel/bridle-plugin`
今天会以 404 结束。在发布之前，插件按本地路径挂载——在 dsh profile 的
`cordis.patch.yml` 里插一行，`name` 写 `dsh-plugin/lib/index.js` 的绝对路径：

```yaml
- insert:
    - id: rowel-bridle
      name: /absolute/path/to/rowel/dsh-plugin/lib/index.js
      config:
        directPort: 61000
```

`directPort` 钉死而不是交给系统分配：手机的配对包记着它收到的直连地址，端口每次重启
都换的话，等于悄悄退掉每一台已配对手机的局域网快路，把它们全赶到 relay 上。

**插件仍然走 loopback HTTP 连它自己所在的那个 dsh。**看起来浪费，实际不是：调用不出机器，与独立二进制同一条路径、同一套测试覆盖，**两者不会漂移**。插件文件因此是生命周期包装（约 100 行），不是第二份实现。

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

新会话仍会写一次账本（`session.create` 幂等重入），只为让 Mac 自己的侧边栏跟上；手机端的分组不依赖这次写入。

写入之前还要有东西可写：目录还没有 workspace 时，`joinWorkspace` 先 `workspace.create` 把目录认下来，再写账本。因为账本只进不补，会话一旦生在还没有 workspace 的目录里，Mac 侧边栏就永远少这一行——`~/workspace/rowel` 那条正是 workspace 比会话晚两分钟建出来的结果。代价是 Mac 上会多出用户没在那里手工建过的分组：一行可删的分组，磁盘上什么都没有。机器从没回答过 `workspace.list`（或目录取的是 Mac 默认值、手机侧叫不出路径）时不动手，那里既没有可加入的组，也没有可建的组。这条只治将来：已经错位的历史行没有任何公开调用能补录。

---

## 10. 推送

**已实现并在真机跑通**（2026-08-20）。app 被挂起后隧道即断，此后 agent 每次停下来提问都落在一台没人告知的机器上——而"人在别处"正是这个产品的前提，所以这是常态而非边缘情况。

### 10.1 实际做法

```
app 拿到 APNs token → 经 Noise 隧道发 wake 帧给 Bridle，每次 ready 重发
Bridle 存进 PairedPeer.push
dsh 发 approval/requested 或 question/requested → core.onWaiting 触发
Bridle 检查 core.attached === 0（两种传输都没人）→ MuxType.Wake 让 Relay 振铃
Relay 用 APNs 密钥签 ES256 JWT，发一条固定文案的 alert 推送
手机醒来 → 自己开隧道 → 取内容 → 发本地通知
```

横幅上的字是 `relay-worker/src/apns.ts` 里的常量。`WakeRequest` 结构里**没有**可以放正文的字段——这不是"Relay 承诺不看"，是**没有东西可看**。

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

**所以这是一个真实的、不可消除的元数据泄露，必须写进隐私说明。**Relay 知道：谁在线、谁连谁、搬了多少字节、振铃时哪个 token 属于哪台机器。它不知道：任何内容。

Relay **不持久化** token——只在振铃那一刻从 Bridle 手里拿到，用完即弃。

### 10.5 三个反直觉的决定

| 决定 | 为什么 |
|---|---|
| 帧里不带 APNs 环境 | token 由沙盒还是生产主机签发，是苹果自己会回答的问题（错主机回 `BadDeviceToken`）。早期让 app 读自己描述文件里的 `aps-environment` 再逐层传下来——那是把猜测当事实，而且猜错时推送静默不到达 |
| 只有 410 `Unregistered` 才算 token 死了 | 早先把所有非 200 都当失效回传，于是一次限流、一次苹果 5xx、一个填错的 topic，都会让 Bridle 永久删掉一个好地址 |
| 欠下的振铃要记账 | `onWaiting` 只触发一次，之后请求就被去重了。Relay 离线时直接丢弃 = 那个问题永远不会有人被通知 |

### 10.6 落点

| 位置 | 做什么 |
|---|---|
| `protocol/src/frames.ts` | `wake` 帧（app→Bridle） |
| `protocol/src/mux.ts` | `MuxType.Wake`（双向：请求振铃 / 回传失效 token） |
| `ios/Rowel/App/Push.swift` | 每次启动和回前台向 iOS 要 token |
| `ios/Rowel/Net/Tunnel.swift` | 每次 `ready` 重发 token |
| `bridle/src/core.ts` | `onWaiting` 钩子、接入计数 |
| `bridle/src/relay-client.ts` | 判断无人接入、按 token 去重、欠账补发 |
| `relay-worker/src/apns.ts` | ES256 签名、生产→沙盒回退、错误分类 |
| `ios/Rowel/Rowel.entitlements` | `aps-environment`（付费会员才签得下来） |

配置见 `docs/deployment.md` 的 APNs 一节：四条 `ROWEL_APNS_*` secret，缺一个则 Relay 不振铃任何人，其余功能不受影响。

---

## 11. 待建：定时任务

dsh **有**调度能力（`@deepseek-ai/dsh-schedule`），但有三个限制：

1. 只有**模型**能调（`schedule_create` / `list` / `delete` 是会话内工具），44 个客户端方法里没有 `schedule.*`
2. `deliveryMode: "session-local"`——到点只是在那个会话里塞一轮，不通知任何人
3. 分叉不继承提醒

所以 webui 上没有入口，任何客户端都没有。**这是一个真空。**

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

当前钉死 dsh 的 44 方法私有 API：**深度上赢，可移植性上输**。

ACP（Agent Client Protocol）是长尾项目的事实标准，registry 有 38 个已验证 agent。但排名前三的产品都不用它——ACP 抹平差异的同时也抹掉了各家 harness 的独有能力。**dsh 目前不在 ACP registry 里。**

### 结论与落点

**不追求"一套吃所有"，而是保留接第二个后端的能力。**

```
bridle/src/agents/
  types.ts        AgentClient interface（§4.1 的五个方法）
  dsh/            现有实现
  acp/            以后
```

app 侧需要一个能力协商：ACP 后端缺少工具渲染意图、projection、审批批次等，UI 必须明确标出"这个后端不支持 X"，而不是静默降级。

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

- **至少同时支持当前版与上一版**（N 与 N−1）
- 推新版的顺序固定：**先发能接受双版本的 Bridle，再灰度 app**
- 只有当旧版本占比降到阈值以下，才移除对它的支持
- 每次版本推进必须跑新旧双向互通测试：新 app ↔ 旧 Bridle、旧 app ↔ 新 Bridle

### 14.4 这次改动本身会断一次

把版本移出 prologue 是**破坏性的**：带版本后缀的 prologue 一旦改动，握手必然失败，所有已配对设备需要重新配对——所以这件事必须赶在公开发布之前做完。

**因此这件事必须在公开发布之前做完。**当前只有一台已配对设备（开发者自己的手机），代价是一次重新配对；上架之后再做，代价是全部用户。

这是协议最后一次在没有协商机制的情况下破坏兼容。

### 14.5 应用层始终向前兼容

未知帧类型、未知事件类型、未知渲染意图，一律容忍（§2、§3.3、`fold.md` §2.2）。这条独立于版本协商：即使版本相同，一端也可能带着另一端不认识的扩展。

历史瘦身是可选优化，app 仍然传 `maxMessages`，所以对着没更新的 Bridle 也不会被 22MB 打死。

---

## 15. 测试策略

```
向量对齐    protocol/scripts/emit-vectors.js → Swift 逐字节
              证明：两份实现是同一个协议
单元        TS 80 · iOS 51
              证明：折叠、解析、限流、地址选择、插件生命周期
e2e         27（起真 Relay + 真 Bridle + 脚本手机）
              对真 dsh：配对、真实模型回复、重连重放、各种拒绝、版本协商
              对假 agent：审批与提问的完整往返（见下）
UI          7（XCUITest，真机或模拟器，连真 Bridle）
              证明：点了真的有反应
```

四层各自证明不同的东西，都不可省：

- 没有向量，两端可以各自自洽地跑但互不兼容
- 没有单元测试，折叠的边界情况（重复 seq、乱序 projection、孤儿工具结果）无法覆盖
- 没有 e2e，安全属性只是断言而非事实——`the relay only ever sees ciphertext` 必须是可执行的
- 没有 UI 测试，"能编译"和"能用"之间还有一整个鸿沟

**为什么审批测试用假 agent。**审批只在模型决定要做需要批准的事时发生，等它发生不是测试而是碰运气。`e2e/src/fake-agent.ts` 实现 §4.1 那个五方法接缝，让测试能在选定的时刻抛出一个审批——它上面的一切（隧道、帧、rpcId 关联、回传路径）都是真的。

这同时是**接缝为真的唯一证据**：如果 `AgentClient` 偷偷多长出第六个要求，这个文件编译不过。

> 早期文档声称 e2e 已经覆盖审批。它没有——一条都没有，"代码存在"顶替了"链路能用"。这是 deep review 抓到的，也是四层测试本该在 e2e 层抓到却漏掉的。

**UI 测试与单元测试分属两个 scheme**（`Rowel` / `RowelUI`）：单元测试到处都能跑、几秒钟；UI 测试需要一台配对好的机器、几分钟。合在一起会让每次 `npm run test:ios` 都等一台可能没开的电脑。

---

## 16. 不变量清单

以下每条都有测试守着。**改动使任何一条失效，就是改错了。**

| # | 不变量 | 守卫 |
|---|---|---|
| 1 | Relay 只见密文 | e2e `the relay only ever sees ciphertext` |
| 2 | 直连监听器不是 web 服务器 | e2e `the direct listener is not a web server` |
| 3 | 配对令牌一次性 | e2e `a stolen pairing token works exactly once` |
| 4 | 吊销立即生效 | e2e `a revoked device cannot come back` |
| 5 | 篡改帧撕毁隧道，不被接受 | e2e `a tampered frame tears the tunnel down` |
| 6 | 错误的机器密钥无法完成握手 | e2e `a device believing the wrong machine key…` |
| 7 | 重放无损，不够时显式告知 | e2e `replay is gapless… and honest when it cannot be` |
| 8 | 两份协议实现逐字节一致 | `ParityTests`（16 项） |
| 9 | 折叠幂等（同一 seq 不双渲染） | `testDuplicateSequenceIsIgnored` |
| 10 | 未知事件静默，不渲染噪音 | `testUnknownEventIsSilent` |
| 11 | 历史瘦身不丢未提交内容 | `chunks of the in-progress message are kept` |
| 12 | 插件 apply 不阻塞、dispose 不抛 | `dsh-plugin/tests/plugin.test.js` |
| 13 | 版本不匹配时拒绝是**已认证且可读**的，不是握手失败 | 待补：新旧双向互通测试（§14.3） |
| 14 | 至少同时支持当前版与上一版 | 待补：同上 |
| 15 | 推送密钥独立于隧道密钥，且在 app 挂起后仍可解密 | 待补：真机验收矩阵（§10.6） |

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
| **斜杠命令** | ✓ | ✗ | **缺口** |
| **看/干预 subagent** | ✓ | ✗ 当前被整个过滤掉 | **缺口** |
| **失败诊断（trace）** | ✓ 甘特图 | ✗ | 缺口，形态要重做（§13） |
| 上下文占用明细 | ✓ | 只有百分比 | 部分 |
| 推理等级 | ✓ | ✗ | 缺口 |
| 分叉 / 归档会话 | ✓ | ✗ | 缺口 |
| 工作区增删改 | ✓ | ✗ | **明确放弃**（§17） |
| 插件管理、改设置、写 API key | ✓ | ✗ | **明确放弃**（§17） |

**首发门槛**：加粗的四个缺口里，**斜杠命令、subagent 必须补齐**——它们是"离开电脑后完成一次完整任务"的必要条件。trace 不是，它是诊断而非操作。访问模式已经补齐，而且补的方式值得记下来：切换一个会话的模式走的是 dsh 的 `/permission` 命令（`commands/execute`，参数 `{agentId, line}`），**不是** `settings.update {ns: permission}`——后者只改新会话的默认值，改不动已经在跑的会话，早期正因为只试了这条路径才误判成"会话创建后不可改"。

**我们已经更好的地方**（这才是产品理由，不是功能对等）：

- 「Needs you」把等待你的会话顶到最前，webui 要自己翻
- 中继是兜底不是路径，webui 没有这个概念
- 新会话默认模型，webui 没有
- 推送（未建）——webui 根本不可能有

---

## 17. 明确不做

| 不做 | 理由 |
|---|---|
| 工作区排序（`workspace.insertBefore` / `insertSessionBefore`） | 手机端按活跃度排序，Mac 的手排顺序在这里不可见；后者也搬不动会话（§9.3） |
| 插件管理 | 同上；且在手机上装插件是奇怪的动作 |
| `settings.*` / `credentials.*` | dsh 钉死 loopback 的特权方法。把写 API key 的能力延伸到手机，等于扩大了配对设备的权限边界 |
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
5. **折叠成本在客户端**。大会话首次加载仍然重，瘦身缓解但没消除。
6. **协议不向后兼容**（§14）。版本不匹配直接拒绝，不做双版本支持。
7. **iOS 独占**。
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

8. **推送依赖付费 Apple 账号**（§10.6）。硬阻塞，且它同时卡着 TestFlight 与上架——是**一个决策卡三件事**。
9. **版本移出 prologue 会破坏现有配对一次**（§14.4）。必须在公开发布前做完。
10. **Relay 会持有 APNs 私钥**（§10.5）。它从"只搬密文的哑管道"变成"还持有一份对外发送凭据"，这是推送带来的、不可避免的信任面扩大。

---

## 附：新功能该往哪放

| 想加什么 | 改哪 | 大概规模 |
|---|---|---|
| 调一个新的 dsh 方法 | `Harness.swift` 加函数 + 调用它的视图 | 几十行 |
| 显示一个新 projection | `Conversation.applyProjection` 一个 case + 视图 | 几十行 |
| 支持一种新工具卡片 | `callPresentation`/`resultPresentation` + `ToolCardView` | 上百行 |
| 访问模式切换 | `permissions` projection（读）+ `commands/execute` 跑 `/permission`（写）+ Session 面板 | 已做 |
| 斜杠命令 | 已做：`commands/list` 进输入框菜单 + 命中命令走 `commands/execute`（**不是** `session.prompt`——斜杠开头的文本会被当成消息发给模型），结果由 `command/run|done` 折叠成一行 |
| subagent | `subagent.*` 四个方法 + 取消列表过滤 | 数百行 |
| 推送 | §10 六处 | 一天，卡付费账号 |
| 定时任务 | §11 三处 | 一到两天，依赖推送 |
| 第二个 agent 后端 | §12，先提 interface | 数天 |
