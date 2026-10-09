# Rowel 线上协议规范

本文档精确到字节。目标是：**一个人（或一个模型）只读这份文档，就能写出与现有实现互通的第三方客户端**，不需要读源码。

规范性用词：**必须**（MUST）、**禁止**（MUST NOT）、**应当**（SHOULD）、**可以**（MAY）。

一致性检验的唯一权威是 `protocol/scripts/emit-vectors.js` 生成的测试向量（`ios/RowelTests/Fixtures/protocol-vectors.json`）。**本文档与向量冲突时，以向量为准**，并且这属于文档 bug，须修正。

- 术语与总览：§1
- 配对载荷：§2
- Noise 通道：§3
- 隧道帧：§4
- Relay 线上格式：§5
- Relay HTTP 接口：§6
- 直连接口：§7
- 错误码：§8
- 测试向量：§9

---

## 1. 术语与总览

| 术语 | 含义 |
|---|---|
| **App** | 发起方（Noise initiator）。手机。 |
| **Bridle** | 响应方（Noise responder）。与 agent 同机。 |
| **Relay** | 内容盲交换机。只按 circuit 转发不透明字节。 |
| **carrier** | 承载 Noise 消息的传输。当前有两种：Relay WebSocket、局域网直连 WebSocket。 |
| **circuit** | Relay 上一条 App↔Bridle 的通路，u32 标识。 |
| **tunnel frame** | Noise 密文**内部**的应用层帧，JSON。 |

三层嵌套，从外到内：

```
WebSocket 二进制消息
  └─ [Relay 路径] mux 帧：u8 type | u32 circuit | payload      ← 仅 Bridle↔Relay 段
       └─ Noise 消息（握手消息 或 传输密文）
            └─ 隧道帧（JSON, UTF-8）
```

**直连路径没有 mux 层**：WebSocket 消息直接就是 Noise 消息。

所有多字节整数**必须**为大端序，除 Noise nonce 外（§3.4）。

---

## 2. 配对载荷

### 2.1 结构

配对码承载一个 JSON 对象。字段顺序**必须**如下（`JSON.stringify` 的插入顺序；向量逐字节比对）：

| 字段 | 类型 | 必需 | 含义 |
|---|---|---|---|
| `v` | number | 是 | 载荷版本。当前恒为 `1`。 |
| `relay` | string | 是 | Relay 基址，如 `wss://rowel-relay.novabox.ai`。 |
| `direct` | string[] | 否 | 直连候选，`ws://host:port`，**最优在前**。字段为 `undefined` 时整个键省略。 |
| `device` | string | 是 | 设备 id，见 §2.3。 |
| `key` | string | 是 | Bridle 的 X25519 静态**公钥**，32 字节，base64url 无填充。 |
| `token` | string | 是 | 一次性配对令牌，base64url 无填充。已配对设备重连时为空串。 |
| `name` | string | 是 | 机器显示名。 |

序列化规则：

- **必须**为紧凑 JSON（无空格、无换行）
- **禁止**转义斜杠（`/` 原样输出，不写 `\/`）
- 顶层键顺序**必须**为上表顺序

> 实现注记：Foundation 的 `JSONEncoder` 用字典承载 keyed container，**不保证键顺序**，且顺序在不同进程间不稳定。Swift 侧因此不能用 `Codable` 合成编码，须显式声明顺序。

### 2.2 深链

```
rowel://pair#<base64url(JSON)>
```

载荷在 **fragment** 里，因此即使被粘进浏览器也不会发给任何服务器。

解码方**必须**：

1. 校验前缀为 `rowel://pair`
2. 取第一个 `#` 之后的全部内容
3. base64url 解码（接受无填充；解码前按需补 `=`）
4. JSON 解析
5. 校验 `relay`、`device`、`token` 非空，且 `key` 解码后恰为 32 字节

任一步失败**必须**拒绝，**禁止**部分接受。

### 2.3 设备 id

```
device = base64url( sha256("rowel-device" ‖ ed25519_signing_public_key)[0..16] )
```

取 SHA-256 前 **16 字节**，base64url 无填充（22 字符）。

**注意**：派生自 **Ed25519 签名公钥**，不是 X25519 静态公钥。二者是不同密钥（§3.2）。因此**仅凭配对载荷无法验证 `device` 与 `key` 的对应关系**——这个绑定由 Relay 在注册时验证（§6.1），以及由握手本身验证（连错机器则握手失败）。

### 2.4 短码

给扫不了码的场景。

- 字母表：`BCDFGHJKMNPQRSTVWXYZ23456789`（28 字符，**无元音**，**无** `0 O 1 I L`）
- 长度：**8** 个字符
- 显示形式：`XXXX-XXXX`（中间一个连字符）
- 生成：每字符取一个随机字节，`ALPHABET[byte % 28]`

> 取模引入的偏置：256 mod 28 = 4，前 4 个字符每个概率约 3.9%，其余约 3.6%（高约 11%）。8 字符的熵约 38.5 bit，短码最长 10 分钟有效（Relay 最多持有 15 分钟）且一次性（§6.2），此偏置不构成实际风险。

**归一化**（比较前必须执行）：

1. 转大写
2. 删除所有非 ASCII 字母数字字符
3. 若结果恰为 8 字符，在第 4 与第 5 字符间插入 `-`；否则原样返回

**完整性判定**：去格式化后**恰为 8 字符**，且每个字符都在字母表内。

> 陷阱：判定**必须**基于去格式化后的字符串。基于归一化结果判断长度是错的——9 个字符的输入归一化后仍是 9 个字符，与"8 字符 + 连字符"同长，会被误判为合法。

### 2.5 确认数（未使用）

`confirmationNumber`（`digits = BE_uint32(sha256("rowel-confirm" ‖ handshake_hash)[0..4]) mod 1000000`，左侧补零至 6 位）保留在 `protocol/src/pairing.ts`，但**不属于任何配对流程**：Mac 端从未实现它。短码路径的防线是 Mac 端对手机密钥指纹的人工确认（§3.3 第 5 步）。

### 2.6 密钥指纹

给人核对用：`bridle pair --code` 显示申请手机的指纹，与 app 等待时显示的一致；`bridle status` 显示本机指纹，与 app 设置页一致。

```
hex = uppercase( hex( sha256("rowel-identity" ‖ public_key) ) )
fingerprint = hex[0:4] "-" hex[4:8] "-" hex[8:12] "-" hex[12:16]
```

即前 8 字节，4 组 4 个十六进制字符，连字符分隔。例：`125B-8CAC-3F65-7256`。

---

## 3. Noise 通道

### 3.1 参数

| 项 | 值 |
|---|---|
| 协议名 | `Noise_IK_25519_ChaChaPoly_SHA256` |
| DH | X25519 |
| 加密 | ChaCha20-Poly1305 |
| 哈希 | SHA-256 |
| 密钥长度 | 32 字节 |
| 认证标签 | 16 字节 |
| prologue | UTF-8 `"rowel-tunnel"` |

prologue 是**稳定的协议族标识，不含版本**。版本在握手载荷里协商（§3.3、§4.6）。

> 早期设计把版本写进 prologue（形如 `rowel-tunnel/v1`）。那是错的：版本不同会让响应方在解密消息一时就失败，此时安全通道尚未建立，任何拒绝都发不出去也无法被认证，客户端无法区分版本偏斜、连错机器、被篡改三种情况。

遵循 Noise 规范的标准初始化：`h = SHA256(protocol_name)`（协议名恰好 32 字节则直接用），`ck = h`，随后 `MixHash(prologue)`。

### 3.2 密钥角色

| 密钥 | 属于 | 用途 |
|---|---|---|
| X25519 静态密钥对 | 双方各一 | Noise 身份 |
| X25519 临时密钥对 | 双方各一，每连接新生成 | 前向保密 |
| Ed25519 签名密钥对 | 仅 Bridle | 向 Relay 证明身份（§6.1），派生 `device` |

**禁止**跨用途复用任何密钥材料。

### 3.3 握手（IK 模式）

**消息一，App → Bridle**：`e, es, s, ss`

```
e                                     32 字节临时公钥，明文
MixHash(e)
MixKey(DH(e, rs))                     rs = Bridle 静态公钥，来自配对码
EncryptAndHash(s)                     32 + 16 = 48 字节，App 静态公钥密文
MixKey(DH(s, rs))
EncryptAndHash(payload)               握手载荷密文
```

线上：`e ‖ enc(s) ‖ enc(payload)`，即 `32 + 48 + (len(payload) + 16)` 字节。

**消息一载荷**（JSON，键序如下）：

| 字段 | 类型 | 必需 | 含义 |
|---|---|---|---|
| `versions` | number[] | 是 | 发起方支持的隧道版本，**偏好在前**，如 `[2, 1]` |
| `name` | string | 是 | 设备显示名 |
| `client` | string | 是 | 客户端构建标识，如 `rowel-ios/1.0 (1)` |
| `token` | string | 否 | 一次性配对令牌。**已知设备必须省略此键**（不是发 `null`） |

省略 vs `null` 的区别是语义性的：省略表示"我已被认识"，`null` 会被当作"要兑换一个空令牌"。

`versions` **必须**非空。响应方遇到空数组或缺失该键时按 `[1]` 处理（兼容最早的客户端）。

**消息二，Bridle → App**：`e, ee, se`

```
e                                     32 字节临时公钥，明文
MixHash(e)
MixKey(DH(e, re))
MixKey(DH(e, rs))                     rs = App 静态公钥，消息一中获得
EncryptAndHash(payload)
```

线上：`e ‖ enc(payload)`。

**消息二载荷**：

| 字段 | 类型 | 必需 | 含义 |
|---|---|---|---|
| `ok` | boolean | 是 | 是否接受 |
| `version` | number | `ok=true` 时必需 | **选定的**隧道版本，双方此后都按它讲话 |
| `reason` | string | `ok=false` 时必需 | `version` / `unpaired` / `internal` / `pending`。`pending` 是唯一**不是终态**的拒绝：短码申请等 Mac 上的人确认，客户端应显示本机指纹并隔几秒重拨（§3.3 第 5 步） |
| `supported` | number[] | `reason=="version"` 时必需 | 响应方支持的版本，供客户端说出**哪一端旧了** |
| `machine` | string | `ok=true` 时应当 | 机器名 |
| `bridle` | string | `ok=true` 时应当 | Bridle 版本 |

`ok=false` 后 Bridle **必须**关闭连接。

**版本选择规则**：响应方取 `versions` 与自己支持集合的交集中**最大**的一个。交集为空时回 `{ok:false, reason:"version", supported:[…]}`。

这个拒绝是**已认证的**——它走消息二，发起方能验证它确实来自持有目标静态私钥的那台机器，而不是任何人都能伪造的一条错误。这正是把版本移出 prologue 换来的东西。

**Bridle 侧接受判定**（顺序不可换）：

1. 取 `versions`（缺失或空则视为 `[1]`），与自己支持的集合求交；交集为空 → `refuse("version", supported)`。否则选交集中最大者。
2. **重新读取状态文件**（`bridle pair` / `bridle revoke` 在别的进程里跑，必须在**本次握手**生效，而不是下次重启）
3. 静态公钥在已配对列表中 → 接受，更新 last-seen
4. 否则 `token` 匹配未过期 offer 的**二维码 token**（`offer.token`，只出现在二维码里，从不发给 Relay）→ 接受并记录设备，**offer 立即作废**
5. 否则 `token` 匹配 offer 的**短码 token**（`offer.codeToken`，随短码载荷交给 Relay）→ 把该设备记为 `offer.claimant`（只留最新一个），`refuse("pending")`。`pending` **不是终态**：App 应显示本机密钥指纹并每隔几秒重拨；Mac 上的人在 `bridle pair --code` 里比对指纹后接受，设备进入已配对列表，下一次握手按第 3 步通过；拒绝或过期则 offer 作废，之后按第 6 步拒绝
6. 否则 → `refuse("unpaired")`

**握手完成后**双方各得两个方向密钥：`(k_initiator→responder, k_responder→initiator)`，以及 `handshake_hash = h`。

### 3.4 传输层

每方向一个独立的 64 位计数器，从 **0** 开始，每加密一条消息 **+1**。

**Nonce 构造**（12 字节）：

```
nonce[0..4]  = 0x00 0x00 0x00 0x00
nonce[4..12] = counter，小端序 u64
```

> 这是 Noise 规范的 nonce 布局：前 4 字节恒零，后 8 字节小端计数器。**这是全协议唯一的小端序**。

密文 = `ChaCha20-Poly1305(key, nonce, plaintext, aad = 空)`，标签附在末尾。

**接收方必须**用自己期望的计数器解密，成功后 +1。解密失败（篡改、乱序、重放）**必须**立即撕毁隧道，**禁止**重同步计数器后继续——能静默重同步的流是可伪造的。

**禁止**在同一密钥下重用计数器。

---

## 4. 隧道帧

Noise 明文即一个 JSON 对象，UTF-8 编码。所有帧有字符串字段 `t` 作为判别式。

编码规则：

- 紧凑 JSON
- **禁止**转义斜杠（端点名如 `session/follow` 必须原样）
- 整数**必须**不带小数点（`8`，不是 `8.0`）
- 顶层键顺序**必须**与下表一致

**版本 2 就是 dsh 0.2 自己的接口，原样透传**（设计见 `docs/dsh-0.2-migration.md` D3）。一元调用 `call` 对应 `POST /api/<endpoint>`，`args` 就是 dsh 的 `payload.args`；流 `open` 对应 dsh `/api/remote.mux` 上的一条逻辑流，`item` / `end` / `cancel` / `error` 与 dsh 的帧一一对应（dsh 的协议见 `docs/dsh-0.2-protocol.md` §2–§5）。Bridle 负责登录 dsh、维持一条到 dsh 的连接、映射流 id，不解读任何端点的含义——dsh 加了新端点，只改 App。

### 4.1 App → Bridle

**`call`** — 调用一个 dsh 一元端点

| 键 | 类型 | 说明 |
|---|---|---|
| `t` | `"call"` | |
| `id` | string | App 铸造的关联 id，本隧道内唯一 |
| `endpoint` | string | dsh 端点 `<命名空间>/<方法>`，如 `session/list` |
| `args` | any | 端点参数，即 dsh 的 `payload.args`；参数名**必须**与 dsh 声明的完全一致 |

唯一由 Bridle 自己回答的端点是 **`$export`**（`args: { sessionId, includeDescendants? }`）：dsh 把会话归档作为普通下载提供（`GET /api/session.export`），不是一元端点，Bridle 取回后以 `{ filename, contentType, base64 }` 作为 `result.value` 返回；归档超过帧上限时回 `too-large`，且**不会**先整份读进内存。

**`abort`** — 放弃在途的 `call`

| `t` = `"abort"` | `id` = 要放弃的调用 id |

Bridle **必须**中止对应的上游请求。未知 id **必须**静默忽略。

**`open`** — 打开一条 dsh 流

| 键 | 类型 | 说明 |
|---|---|---|
| `t` | `"open"` | |
| `sid` | string | App 铸造的流 id，在本隧道**仍打开**的流中唯一 |
| `endpoint` | string | dsh 流端点，如 `session/follow`、`workspace/follow`，或内置的 `$events` |
| `args` | any | 端点参数，同 `call` |

对仍打开的 `sid` 再发 `open`，Bridle 以 `error`（`bad-request`）拒绝这一次，**禁止**关闭隧道（dsh 对同样的情况会关掉整个 socket，Bridle 不把这个代价转嫁给其他流）。

**`item`** — 上行数据

| `t` = `"item"` | `sid` | `value` = 任意 JSON |

大多数 dsh 流不读上行（dsh 协议参考 §3.4）。对未知或已结束的 `sid` **必须**静默丢弃。

**`end`** — 半关闭上行

| `t` = `"end"` | `sid` |

**`cancel`** — 停止一条流

| `t` = `"cancel"` | `sid` |

此后 Bridle **不再**为这条流发送任何帧，包括终止帧。

**`hello`** — 重新要一份 `ready`

| 键 | 类型 | 说明 |
|---|---|---|
| `t` | `"hello"` | |
| `version` | number | app 期望的隧道版本 |
| `client` | string | 客户端构建串，`bridle status` 里显示 |

同样的内容握手载荷里已经带过一次（§3.3）。这里再发一次，是为了让重连的 app 不必区分"新隧道"和"复用的隧道" —— 两种情况都以收到 `ready` 结束。Bridle 收到后**必须**重发 `ready`，**禁止**因此关闭已打开的流。

**`wake`** — 告诉机器：我不在线时往哪儿敲

| 键 | 类型 | 说明 |
|---|---|---|
| `t` | `"wake"` | |
| `token` | string \| null | APNs device token（小写 hex）。`null` = 别再叫我 |

App **应当**在每次 `ready` 之后重发一次：token 存在机器上，而机器会被重装、被还原、被换掉。Bridle 对无变化的重发**必须**静默丢弃。

帧里**没有** APNs 环境字段。token 由沙盒还是生产主机签发，是苹果自己会回答的问题（错主机返回 `BadDeviceToken`），Relay 先试生产再退沙盒。早期版本让 app 读自己描述文件里的 `aps-environment` 再逐层传下来 —— 那是把猜测当事实，而且猜错时推送静默不到达、没有任何报错。

**`pong`** — 存活应答

| `t` = `"pong"` | `nonce` = 原样回送 |

App **必须**应答 Bridle 的每个 `ping`。Bridle 连续 2.5 个 ping 周期（62.5 秒）没收到对端任何帧，就判定手机已离开并关闭这条隧道——否则一个没发 FIN 就消失的手机会一直被算作"有人接入"，推送因此被压住。

### 4.2 Bridle → App

**`ready`** — 连接就绪，**必须**是握手后的第一帧

| 键 | 类型 | 说明 |
|---|---|---|
| `t` | `"ready"` | |
| `version` | number | 隧道版本 |
| `bridle` | string | Bridle 版本 |
| `machine` | string | 机器名 |
| `dshReachable` | boolean | Bridle 当前是否持有一条已登录的 dsh 连接 |
| `detail` | string，可选 | 不可达的原因，给人看（如"dsh 要求登录，运行 `bridle plugin install`"） |
| `dsh` | string，可选 | dsh 版本，已知时 |
| `harness` | object，可选 | `{ url, home }`：此身份指向的 dsh 地址与 `ROWEL_HOME` 实际路径。一台机器可以跑多个 Bridle，app 靠它区分实例并在急救指引里带上正确目录 |
| `host` | object，可选 | `{ home }`：本机账户的主目录。dsh 0.2 删除了 `host.describe`，app 的目录选择器以此为起点 |
| `direct` | string[]，可选 | 本机当前可直连的地址，优先在前。空数组表示直连监听已关（app 应清掉存量地址） |

**`result`** — `call` 的结果

```
{ "t": "result", "id": "...", "result": { "ok": true, "value": ... } }
{ "t": "result", "id": "...", "result": { "ok": false, "error": { "code", "message", "details" } } }
```

`result` 原样是 dsh 的 `server-response.result`，或 Bridle 自己产生的失败（§8.1）。

**`item`** — 下行数据

| `t` = `"item"` | `sid` | `value` = dsh 的 item，原样 |

**`end`** — 流正常结束

| `t` = `"end"` | `sid` |

**`error`** — 流失败并结束

| `t` = `"error"` | `sid` | `error` = `{ code, message, details }` |

每条流最多一个终止帧（`end` 或 `error`）。`error` 是 dsh 的原样错误，或 Bridle 产生的：`upstream-lost`（Bridle 到 dsh 的连接断了）、`too-large`、`slow-consumer`、`busy`、`bad-request`（§8.1）。

**`status`** — dsh 连接起落

| `t` = `"status"` | `dshReachable` = boolean | `detail` = 不可达原因，可选 |

**`ping`** — 存活探测，间隔 **25 秒**

| `t` = `"ping"` | `nonce` = 任意字符串 |

**`fault`** — 协议级拒绝，之后连接关闭

| `t` = `"fault"` | `code` = `version`\|`unpaired`\|`internal`\|`busy` | `message` = 人类可读 |

### 4.3 未知帧

收到未知 `t` 的一方**必须**忽略该帧并继续。**禁止**因此关闭连接。这是向前兼容的基础。

### 4.4 并发上限

Bridle **必须**限制单条隧道的在途 `call` 与同时打开的流。当前实现为在途调用 **64**、同时打开的流 **64**；超出时立即以 `busy` 应答（`call` 回 `result`，`open` 回 `error`），**禁止**排队。

### 4.5 流的归属、重连与背压

- **归属**：每条流属于打开它的那条隧道，只有这条隧道收得到它的帧。隧道关闭时，Bridle **必须**取消它名下的全部流，不在 dsh 上留下孤儿流。
- **重连**：dsh 没有流级别的续传（dsh 协议参考 §3.6）。Bridle 与 dsh 之间的连接断开时，所有流以 `upstream-lost` 结束；App 重新 `open`，拿到新的基线（`session/follow` 的快照、`workspace/follow` 的 `baseline`、`$events` 的 `ready` 与重发的未决审批和提问）。隧道本身断开重连同理。Bridle **不**缓存、**不**重放任何事件。
- **帧上限**：单帧超过 32 MiB 时，`result` 变成 `too-large` 失败；流的 `item` 使 Bridle 取消这条流并回 `error`（`too-large`）。只失败这一个调用或这一条流，**禁止**关闭隧道。
- **背压**：dsh 下行不做流控。手机跟不上、承载的写缓冲超过 8 MiB 时，Bridle 取消正在写的那条流并回 `error`（`slow-consumer`），App 可以重新打开。

### 4.6 版本策略

版本在握手载荷里协商（§3.3），不在 prologue 里。

- **至少同时支持当前版与上一版**（N 与 N−1）。实现**必须**声明自己的支持集合而不是单个值。
- **推新版的顺序固定**：先发能接受双版本的 Bridle，再灰度 app。反过来会让先升级的 app 连不上还没升级的 Bridle。
- 只有当旧版本占比降到阈值以下，才移除对它的支持。
- 每次版本推进**必须**跑新旧双向互通测试：新 app ↔ 旧 Bridle、旧 app ↔ 新 Bridle。

应用层则**必须**向前兼容，且这条独立于版本协商：未知帧类型、未知事件类型、未知渲染意图一律容忍。即使版本相同，一端也可能带着另一端不认识的扩展。

> **例外：版本 2 不兼容版本 1。** 版本 1 是 dsh 0.1 的接口透传，dsh 0.2 删除了这套接口，owner 决定不保留翻译层（`docs/dsh-0.2-migration.md` §0、D6）。所以支持版本 2 的 Bridle 只支持 `[2]`。只会说版本 1 的 App 在握手时收到 `{ok:false, reason:"version", supported:[2]}`，它本来就会据此提示"哪一端旧了"。新 App 连上只会说版本 1 的旧 Bridle 同理。发布顺序见迁移设计 D7。

> **一次性破坏**：把版本移出 prologue 本身是破坏性的——prologue 一旦带上版本后缀，此后任何改动都会让握手直接失败。**这必须在公开发布之前完成**，那时代价是重新配对少数几台设备；上架之后再做，代价是全部用户。这是协议最后一次在没有协商机制的情况下破坏兼容。

---

## 5. Relay 线上格式

仅存在于 **Bridle ↔ Relay** 段。App ↔ Relay 段的 WebSocket 消息直接是 Noise 消息。

```
u8  type
u32 circuit （大端）
    payload
```

头长 **5** 字节。

| type | 值 | 方向 | payload |
|---|---|---|---|
| `Open` | `0x01` | Relay→Bridle | JSON `CircuitInfo`，宣告一部手机接入 |
| `Data` | `0x02` | 双向 | 一条 carrier 消息，原样 |
| `Close` | `0x03` | 双向 | UTF-8 原因文本，可为空 |
| `Wake` | `0x04` | Bridle→Relay | JSON `WakeRequest`，叫醒一部没接入的手机 |
| `Wake` | `0x04` | Relay→Bridle | JSON `{ token, dead: true }`，APNs 说这个 token 已失效 |

`Wake` 的 circuit 恒为 `0` —— 没有 circuit 正是发它的原因。

```
WakeRequest = { token: string, machine?: string }
```

Relay 收到 `Wake` 后向 APNs 发一条**固定文案**的通知。文案是 Relay 代码里的常量加机器名：Relay 只读 `token` 和 `machine`（截到 64 字符），其余字段忽略。推送不会运行 app；用户点开后 app 重连隧道，才显示机器上的真实请求。

`machine` 不是新泄露的信息：Relay 的目录里本来就存着机器名（`GET /v1/machine/:id` 就是答它）。

Relay 没配 APNs 密钥时，`Wake` **必须**是 no-op，**禁止**因此断开机器。

反向的 `{ token, dead: true }` **只在**苹果明确说设备已消失时发送（HTTP 410 `Unregistered`，或两个主机都回 `BadDeviceToken`），以及 token 本地格式就不合法时。限流、鉴权失败、苹果 5xx、配置不全 —— 一律**禁止**回传 `dead`：Bridle 收到就会删 token，而那些都是临时故障，删掉的是一个好地址。

Bridle **禁止**在注册完成前发送 `Wake`：Relay 对注册前的二进制帧的处理是断开连接。振铃时机若不满足，**应当**记住并在注册完成后补发 —— Bridle 从待处理请求列表推导欠下的振铃（`dueForRing`），注册完成时补发，不能靠一次性的事件。

未知 type **必须**拒绝（而非忽略）——这一层是二进制且长度定死，未知类型意味着解析错位。

Relay **禁止**解析 `Data` 的 payload。

---

## 6. Relay HTTP 接口

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/healthz` | 存活与粗粒度计数 |
| `GET` | `/install` | 安装脚本（`curl \| sh`），文本。仅 Node relay 且配置了 `ROWEL_INSTALL_SCRIPT` 时；线上 Worker 回 404 |
| `GET` | `/v1/machine/<deviceId>` | 该机器是否在线 |
| `POST` | `/v1/pair/offer` | Bridle 挂一个短码邀请 |
| `GET` | `/v1/pair/claim?code=` | App 用短码换配对载荷，**一次性** |
| `WS` | `/v1/bridle` | Bridle 常连 |
| `WS` | `/v1/app?device=` | App 接入为一条 circuit |

### 6.1 Bridle 注册

连上 `/v1/bridle` 后，Relay 发一个随机 nonce，Bridle **必须**在 **15 秒**内回签名：

```
signature = Ed25519_sign( "rowel-relay-registration/v1" ‖ "\n" ‖ nonce )
```

Relay 验签，并校验 `deviceId == base64url(sha256("rowel-device" ‖ signing_public_key)[0..16])`。**这是 `device` 与签名密钥绑定的唯一强制点。**

同一 deviceId 重复注册时，**新连接顶掉旧连接**。

### 6.2 短码邀请

`POST /v1/pair/offer`：

```json
{ "code", "device", "key", "signature", "bundle", "expiresAt" }
```

`signature = Ed25519_sign("rowel-pair-offer/v1" ‖ "\n" ‖ code)`。

两个域分隔符（`rowel-relay-registration/v1` / `rowel-pair-offer/v1`）不同，因此一个签名**不能**被当作另一个用途重放。

Relay 侧限制（硬编码，非配置项）：

| 限制 | 值 |
|---|---|
| 单帧最大 | 32 MiB |
| 注册超时 | 15 秒 |
| 心跳 | 25 秒（Node relay；Worker 没有 relay 侧心跳，靠 Bridle 侧 62.5 秒无应答自断） |
| 每机器并发 circuit | 8 |
| 每设备待领短码 | 3 |
| 短码有效期上限 | 15 分钟（请求更长会被截断） |
| `Wake`（Worker） | 每台机器突发 5 次、之后约每 6 秒 1 次；`machine` 截断到 64 字符 |

`GET /v1/pair/claim` **必须**在成功返回后立即作废该短码。

---

## 7. 直连接口

Bridle 监听 `0.0.0.0:<port>`（`--direct-port`，`0` 表示由系统分配）。

- 路径：`/v1/tunnel`（`DIRECT_PATH`）
- **非 WebSocket upgrade 的请求必须返回 `426`**（路径不对的 upgrade 回 `400`），且**禁止**返回任何 API 内容
- WebSocket 消息直接是 Noise 消息，**无 mux 头**
- 单条消息上限与隧道一致：32 MiB（`MAX_FRAME_BYTES`）
- 未完成握手的连接同时最多 **8** 条，从 TCP 建连起计数；超出的在 **TCP 层直接断开**（WebSocket 升级之前，客户端看到的是连接重置，没有关闭码）。连接总数上限 **16**（8 条未认证 + 8 台已配对手机）。HTTP 升级请求和 Noise 握手都须在 **10 秒**内完成，否则断开。这个端口对同一网络上的任何人开放，而 Relay 那条路有每机 8 条线路的上限，这里原来没有

广播给配对码的地址由网卡枚举得出：

- 排除 internal（loopback）与非 IPv4
- 排除 `169.254/16`（DHCP 失败的自赋地址，永不可路由）
- 排序：`192.168/16` → `10/8` → `100.64/10`（tailnet）→ `172.16/12` → 其他
- `--advertise` 指定的地址**排在最前**（机器无法自行发现的隧道域名）

---

## 8. 错误码

### 8.1 隧道层（`result.error.code`、流的 `error.code` 与 `fault.code`）

| code | 含义 | 可重试 |
|---|---|---|
| `disconnected` | 隧道不在 | 是 |
| `timeout` | 上游未在期限内应答（当前 120 秒） | 是 |
| `busy` | 在途调用或打开的流超过上限 | 是 |
| `internal` | Bridle 内部故障 | 是 |
| `upstream-lost` | Bridle 到 dsh 的连接断了（或此刻未连上）；流以此结束，重新 `open` 即可 | 是 |
| `slow-consumer` | 手机跟不上这条流，Bridle 取消了它；重新 `open` 即可 | 是 |
| `version` | 隧道版本不匹配 | 否 |
| `unpaired` | 设备未被认识 | 否 |
| `bad-request` | 载荷不合法，或重复的流 id | 否 |
| `too-large` | 结果或流的一项超过 32 MiB 帧上限，Bridle 自己产生 | 否 |

其余错误码由 dsh 定义（如 `gateway/arguments-invalid`），Bridle **必须**原样透传，**禁止**改写。

### 8.2 判定可重试

`disconnected` / `timeout` / `internal` / `busy` / `upstream-lost` / `slow-consumer` 视为暂时性；其余视为终态。客户端**应当**只对暂时性错误自动重试。握手拒绝里的 `pending`（§3.2）同样是暂时性的。

---

## 9. 测试向量

```sh
npm run vectors      # 生成 ios/RowelTests/Fixtures/protocol-vectors.json
```

固定静态密钥与固定临时密钥，使整个握手确定。覆盖：

| 向量 | 断言 |
|---|---|
| `protocolName` `prologue` | 常量一致 |
| `handshake.messageOne` | 逐字节相同（覆盖哈希链、两次 DH、两次 AEAD） |
| `handshake.messageTwo` | 响应方能恢复发起方身份与载荷，且产出相同 |
| `handshake.handshakeHash` | 双方派生一致 |
| `handshake.confirmationNumber` | 确认数一致 |
| `transport.*` | **多条**帧的密文逐字节一致（一条帧无法暴露计数器不递增） |
| `pairing.link` | 编解码逐字节往返 |
| `pairing.fingerprint` | 指纹一致 |
| `pairing.shortCodeInputs` | 归一化一致 |
| `frames[]` | 帧编码逐字节一致 |

新实现**应当**先跑通全部向量，再接真实 Bridle。

**已知不可自验的项**：`deviceId` 派生自 Ed25519 签名公钥，而配对载荷只带 X25519 静态公钥，因此客户端无法凭载荷验证 `device` 字段（§2.3）。向量刻意不断言这一项。
