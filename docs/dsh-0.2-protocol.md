# dsh 0.2 线协议参考（Rowel / Bridle 迁移用）

对象版本：`@deepseek-ai/dsh@0.2.0-rc.2`（所有 `@deepseek-ai/*` 依赖同为 `0.2.0-rc.2`，cordis 系为 `~4.0.4` 等）。

本文是参考，不是设计。所有结论都有出处：

- 源码引用格式 `包名/文件:行`，根目录统一为 `@deepseek-ai/`（下文省略这个前缀；CLI 本体在 `lib/`）。
- 包的运行时入口是打包后的 `lib/index.js` / `lib/client.js`。部分包（`dsh-api-gateway`、`dsh-api-remotes`）在 `lib/types/*.js` 里还有一份未打包的同源代码，更好读，引用时优先用它；内容和 `lib/index.js` 一致。
- **[live]** 表示在隔离的一次性实例上实测过：`dsh 0.2.0-rc.2`，`DSH_HOME=/tmp/dshref/home`，端口 3092，模型 `commandcode / deepseek/deepseek-v4.1-flash`。实测样本里的 sessionId、token 都是那个一次性实例的，已销毁。
- 没标 [live] 的条目来自源码阅读。

0.1.1 的旧 API 见 `docs/dsh-api-inventory.md`。下面凡是说"和 0.1 不同"都以那份文档为准。

---

## 0. 一页摘要（和 0.1 的根本差异）

| 方面 | 0.1.1 | 0.2.0-rc.2 |
|---|---|---|
| 认证 | 无，loopback + Host 栅栏 | **所有 `/api` 请求和 WS 都要 cookie**（launch token 换 HMAC 签名 cookie）。loopback 不豁免 |
| 一元调用 | `POST /api/session.list` 等点号方法，`payload` 直接是参数 | `POST /api/<ns>/<method>`（斜杠两段），`payload` 必须是 `{ args: { <精确参数名>: ... } }` |
| 下行流 | `WS /api/events.mux` + `WS /api/events.host`，只收不发 | **单一** `WS /api/remote.mux`，多路复用逻辑流，客户端**要发** `open/item/end/cancel` 帧 |
| 会话历史 | `session.history` 分页 + mux 推 `session/event` | `session/follow`（流：快照 + 增量 + 可选 assistant 流帧）+ `session/page`（向前翻页） |
| 审批/提问 | `approval/requested` / `question/requested` 帧，`POST /api/respond` 回 rpcId | `$events` 流里的 `waterfall` 帧，`POST /api/$events/result` 回 `{clientId, eventId, outcome}` |
| 主机事件 | `events.host` 的 `host/session-added` 等 | `$events` 流里的 `emit` 帧：`api-session/added|removed|status|activity|error` 等 |
| 工作区/归档/置顶 | `workspace.*` 一元 + host 帧 | `workspace/*` 一元 + `workspace/follow` 流（baseline + 增量） |
| 投影 | mux `session/projection` | `session/control` 流（baseline + `projection` 帧），以及 follow 快照、list 行里的投影块 |

---

## 1. 认证（BrowserAuth）

### 1.1 请求进入 `/api` 的完整判定顺序

`/api` 是一个前缀路由，由 `dsh-client-connection` 注册（`dsh-client-connection/lib/index.js:829-843`）。每个请求依次经过：

1. **Host/Origin 栅栏** `isTrustedApiRequest`（`dsh-client-connection/lib/index.js:205-219`）：
   - 必须有 `Host` 头，且主机名是 loopback（`localhost`、`[::1]`、`127.0.0.0/8` 任意地址，`:121-125`）或命中 `trustedHosts`（`:192-198`：带端口的条目精确匹配 `host:port`，不带端口的条目匹配任意端口）。
   - `sec-fetch-site: cross-site` 一律拒。
   - 带 `Origin` 时其 host 必须等于 `Host`。不带 `Origin` 放行（非浏览器客户端就是这种情况）。
   - 失败 → **403**，响应体 `forbidden`。
2. **cookie 认证** `BrowserAuth.isAuthenticated`（`:433-443`）。失败 → **401**，响应体 `unauthorized`（`:834-838`，`requestRejection` 在 `:586-589`）。
3. 通过后进入 `connection/request` waterfall（Desktop 用它在安装插件时锁住新请求），再进 HTTP 桥。

WebSocket 升级 `/api/remote.mux` 用同一个 `connection.admit()`（`dsh-api-gateway/lib/types/index.js:93-100`）。拒绝时直接在 socket 上写 `HTTP/1.1 401 Unauthorized` 或 `403 Forbidden`（`dsh-api-gateway/lib/types/stream-server.js:380-391`）。

**没有 loopback 豁免**。README 原文："Every Host RPC method and WebSocket stream requires one browser session; there is no method-specific loopback tier."（`dsh-client-connection/README.md` "Browser authentication and request trust" 一节）。0.1 的"特权方法钉死 loopback"这一层已经没有了，换成全部都要认证。

[live] 无 cookie `POST /api/session/list` → 401 `unauthorized`；`Host: evil.com` → 403；带签名 cookie 但 `Host: localhost:3092`（cookie 是给 `127.0.0.1:3092` 签的）→ 401；WS 无 cookie → 401；WS 带 `Origin: http://evil.com` → 403。

### 1.2 launch token

- 每个进程一个，32 字节随机数，base64url 编码（43 字符，无 padding）。按 `ctx.root` 存在进程内 `WeakMap`，Connection 插件重载也不变（`dsh-client-connection/lib/index.js:231,244-250`）。
- **不落盘**。[live] 在 `$DSH_HOME` 下 grep 当前 token，无结果。
- 进程重启后旧 token 失效。[live] 重启后用上一进程的 token 访问 `/?token=` → 401。
- 进程生命周期内**可重复使用**（不是一次性）。[live] 同一 token 连续两次 `GET /?token=` 都是 303。
- 只在 `GET /` 上被接受，且 query 里必须恰好一个 `token`（`:391-394`）。`/index.html?token=` → 401 [live]；`POST /?token=` → 405（静态服务只接受 GET/HEAD）[live]；`/api/*?token=` 和 `Authorization: Bearer` 都不认 → 401 [live]。README 原文："The HTTP carrier accepts no query token outside the root exchange and no Authorization-header token."

### 1.3 token 如何被分发

唯一官方出口是 `dsh-web-app` 在 Loader 全部就绪后打印一行到 **stdout**（`dsh-web-app/lib/index.js:194-218`，打印在 `:203`）：

```
dsh web: http://127.0.0.1:<port>/?token=<token>
```

如果绑定 `0.0.0.0`，同一行后面追加 ` (LAN: http://<ip>:<port>/?token=<token>)`。没加 `--no-open` 时还会多打一行 `dsh web: opening the default browser; pass --no-open to disable`，并把带 token 的 URL 交给系统浏览器（`:204-209`）。URL 的 host 永远是 `127.0.0.1`（`localWebUrl`，`:95-99`）。

[live] `--no-open` 时 stdout 只有一行：`dsh web: http://127.0.0.1:3092/?token=-75uZst7Vwi1CgB-E94rVs_Wtenamq8intrytWUES-s`。

注意 agent shell 里的 `DSH_WEB_URL` 环境变量是**不带 token** 的干净 URL（`dsh-web-app/lib/index.js:40,186-192`），不能用来认证。

### 1.4 `GET /?token=` → cookie

`BrowserAuth.authorizeIndex`（`dsh-client-connection/lib/index.js:388-427`）。token 正确时：

```
HTTP/1.1 303 See Other
cache-control: no-store
location: ./
referrer-policy: no-referrer
set-cookie: dsh-auth-<NAME>=v1.<BODY>.<SIG>; Max-Age=2592000; Path=/; Expires=<UTC>; HttpOnly; SameSite=Strict
```

[live] 实测：

```
set-cookie: dsh-auth-ycVJGZyChAvlZRdcgHwJTDS2cj_7FBKaNcaHXjHouiw=v1.eyJ2ZXJzaW9uIjoxLCJhdXRob3JpdHkiOiIxMjcuMC4wLjE6MzA5MiIsImlzc3VlZEF0IjoxNzkxMDIyMDI4NjkxLCJleHBpcmVzQXQiOjE3OTM2MTQwMjg2OTF9.zDZVffads_qs_vO9XARDa-ivpRuD4dGQsv4bHvw6CaI; Max-Age=2592000; Path=/; Expires=Mon, 02 Nov 2026 10:07:08 GMT; HttpOnly; SameSite=Strict
```

格式细节：

- **cookie 名** = `dsh-auth-` + base64url(SHA-256(authority))，authority 是 `new URL('http://'+Host).host` 规范化后的 `host:port`（`:257-265, 284-286`）。[live] `127.0.0.1:3092` 算出来正是 `dsh-auth-ycVJGZyChAvlZRdcgHwJTDS2cj_7FBKaNcaHXjHouiw`。所以同一个 dsh，用 `localhost:3092` 和 `127.0.0.1:3092` 访问是两个不同的 cookie，互不通用。
- **cookie 值** = `v1.` + base64url(JSON) + `.` + base64url(HMAC-SHA256(secret, base64url(JSON)))（`:302-305`）。JSON 是 `{"version":1,"authority":"127.0.0.1:3092","issuedAt":<ms>,"expiresAt":<ms>}`。
- **校验**（`:306-324, 433-443`）：签名正确、`authority` 等于本次请求的 Host、`issuedAt <= now < expiresAt`、`expiresAt - issuedAt <= cookieMaxAgeDays`。
- **寿命**：默认 30 天，配置项 `cookieMaxAgeDays`（Connection 行的 config，`:799-804`）。绝对过期，没有续期，没有登出接口。
- 没有 `Secure` 属性（因为 loopback 是明文 HTTP）。
- token 错误或缺 cookie 的 index 请求返回 401，`text/plain`，正文 `dsh web authentication required; reopen the URL printed by dsh web.`（`:444-450`）。[live]
- 静态资源（非 index 的文件）不需要认证（`dsh-host-frontend-static/lib/index.js:49-75`）。

### 1.5 签名密钥在哪

- 记录键 `client-connection/browser-session`（`dsh-client-connection/lib/index.js:223`），kind `grant`，payload `{ version: 1, secret: <32 字节 base64url> }`。Connection 激活时如果没有就创建（`:325-342`）。
- 本地 provider 写在 **`$DSH_HOME/.credentials.yaml`**（README 原文）。[live] 文件权限 `-rw-------`，内容形如：

```yaml
version: 1
records:
  client-connection/browser-session:
    kind: grant
    payload:
      version: 1
      secret: <redacted>
```

- 密钥跨进程重启保持不变，所以**已签发的 cookie 在 dsh 重启后仍然有效**。[live] 重启后，第一个进程签发的 cookie 访问新进程 → 200。
- 删除或替换这条记录、再重启 dsh，会吊销所有 cookie（README "Known Limitations"）。

### 1.6 `--trusted-host` 与 LAN

- `dsh web --trusted-host <authority...>`（`dsh-web-app/lib/startup.js:22`）只往 Host 栅栏加白名单，**不绕过认证**。README 原文："These checks defend DNS rebinding and cross-site browser requests; they never establish identity."
- CLI 拒绝 `--host 0.0.0.0`（`dsh-web-app/lib/startup.js:40`，报错 "intentionally not supported yet for safety"）。通过 profile patch 把 `webserver.host` 设成 `0.0.0.0` 是可以的，这时会自动把本机所有非内部 IPv4 地址作为不带端口的条目加入 `trustedHosts`（`dsh-web-app/lib/index.js:83-89`），并在打印行里附上 LAN URL。
- `trustedHosts` 条目必须是规范的裸 authority，否则插件加载失败（`dsh-client-connection/lib/index.js:169-173`）。

### 1.7 非浏览器的本地进程如何合法拿到认证

#### (a) 作为 dsh 插件（官方 API）[live]

插件声明 `inject: ['connection', 'webServer']` 即可读到：

- `ctx.webServer.port: number`：实际监听端口，端口配成 0 时是系统分配的值（`dsh-host-webserver/lib/types/index.d.ts:80-81`）。
- `ctx.webServer.host: '127.0.0.1' | '0.0.0.0'`（`:82-83`）。
- `ctx.connection.authenticatedUrl(baseUrl: string): string`：返回把本进程 token 加到 baseUrl 上的 URL（`dsh-client-connection/lib/types/rpc-host.d.ts`；实现 `lib/index.js:374-378, 600-602`）。
- 还有 `ctx.connection.admit(request)`、`ctx.connection.operator`、`ctx.connection.fetch.register(...)`（注册 `/api/<path>` 精确路由）、`ctx.connection.rpc.handle(channel, handler)`（注册独立通道），这些都在 `rpc-host.d.ts` 里，挂在它们上面的路由同样要经过认证。

实测插件（ESM，一个文件就够）：

```js
// /tmp/dshref/bridle-probe/index.mjs
import { writeFileSync } from 'node:fs'
export const name = 'bridle-probe'
export const inject = ['connection', 'webServer']
export function apply(ctx) {
  const port = ctx.webServer.port
  const url = ctx.connection.authenticatedUrl(`http://127.0.0.1:${port}`)
  writeFileSync('/tmp/dshref/plugin-url.txt',
    JSON.stringify({ port, url, host: ctx.webServer.host }) + '\n', { mode: 0o600 })
}
```

加载方式：在 `$DSH_HOME/profiles/web/cordis.patch.yml` 末尾加

```yaml
- insert:
    - id: bridle-probe
      name: /tmp/dshref/bridle-probe/index.mjs
```

[live] 重启后文件内容为 `{"port":3092,"url":"http://127.0.0.1:3092/?token=EjvdKx…","host":"127.0.0.1"}`，和 stdout 打印的 URL 完全一致；拿这个 token 去 `GET /?token=` → 303 + cookie。
（模块名用绝对路径能被 loader 直接 `import()`，`cordis-plugin-loader/lib/index.js:214-225`。正式分发应走 `dsh plugin --profile web add <package>`，见 `lib/bin.js:115-127`。）

限制：插件只能在用户的 dsh 进程里运行，必须由用户把它装进自己的 profile；dsh 进程重启后插件会重新执行，拿到新 token。

#### (b) 自己启动 dsh 并捕获 token [live]

启动 `dsh web --no-open ...`，读 stdout，匹配 `^dsh web: (\S+)`，取 URL 里的 `token`。注意现在 Bridle 的 `ensureDsh` 用的是 `stdio: 'ignore'`（`bridle/src/dsh/discovery.ts:180`），在 0.2 上拿不到 token。

#### (c) 其他方式

- **用已签发的 cookie**：cookie 30 天有效、跨重启有效（1.5）。只要拿到过一次 token（用户粘贴一次 URL，或 a/b 任一方式），完成交换后保存 cookie 即可长期使用，直到过期或密钥被换。这是官方机制的正常用法，没有越权。
- **读 `$DSH_HOME/.credentials.yaml` 的 secret 自己签 cookie**：[live] 用 Node 按 1.4 的格式计算，直接访问 `/api/*` 和 WS 都成功。**这不是官方接口**，README 只说明了 secret 的存放位置和吊销方式，没有承诺格式稳定；等价于持有该用户的全部 dsh 权限，文件权限是 0600，同用户进程可读。
- 环境变量：没有。`DSH_WEB_URL` 不含 token（1.3）。
- 文件：token 不落盘（1.2）。
- CLI 参数：没有 `--token` 之类的参数（`dsh-web-app/lib/startup.js:22` 的参数只有 `--host --port --trusted-host --no-open`）。

**结论：对于一个用户自己启动的、正在运行的 `dsh web`，没有官方途径让另一个本地进程拿到 token**。可选路径只有：用户把打印的 URL 交给它（或之前交换过的 cookie 还在有效期内）；装一个插件；或读 credentials 文件自签（非官方）。

### 1.8 Desktop（profile `desktop`）

本机没有安装 Desktop app，以下全部来自源码，未实测。

- `desktop` profile 由 Electron 独占：`dsh --profile desktop` 被 CLI 拒绝（`lib/bin.js:35-37`）；`dsh plugin --profile desktop ...` 要求 app 已初始化并退出（`lib/plugin-BGnVfe_D.js:10-11`）。
- Desktop 页面由壳提供 `window.__DSH_TRANSPORT__`（类型 `ClientTransportHooks`，`dsh-client-connection/lib/types/client/index.d.ts:43-70`），其中 `streamBaseUrl` 是"壳拥有的 Host 的 HTTP 源"，WS 连到 `new URL('api/remote.mux', streamBaseUrl)`（`dsh-api-gateway/lib/client.js:730`）。README 原文："The desktop carrier owns authentication; setting the origin alone grants no access."
- Gateway README 末尾："The ./stream-protocol export supplies the shared Remote stream framing and parser to native Desktop callers. These callers use the same authenticated WebSocket endpoint as the browser client."
- 端口：webserver 支持 `port: 0`（系统分配）（`dsh-host-webserver/lib/types/index.d.ts:51-52`）。Desktop 用哪个端口、怎么把凭证交给页面，这段代码在 Electron 壳里，不在本包内。
- 仅在 desktop profile 启用的行：产品遥测、`product-analytics`、浏览器侧边栏（`dsh-web-app/cordis.patch.yml:45-63, 277-280`）。

**开放问题**：Desktop 是否也打印 token、Bridle 能否发现它的端口和凭证，需要拿到 Electron 壳源码或装上 app 再确认。

---

## 2. 一元调用 `POST /api/<ns>/<method>`

### 2.1 请求

```http
POST /api/session/list HTTP/1.1
Host: 127.0.0.1:3092
Cookie: dsh-auth-…=v1.….…
Content-Type: application/json

{"type":"client-request","rpcId":"r1","method":"session/list","payload":{"args":{"_request":{}}}}
```

- `Content-Type` 的主类型必须是 `application/json`，否则 **415** `content type must be application/json`（`dsh-client-connection/lib/index.js:679`）。[live]
- 必须是 POST；其他方法 → 404（`:678`）。[live] GET → 404。
- 信封由 zod 校验：`type: 'client-request'`、`rpcId: string`、`method: string`、`payload: unknown`（`:504-509`）。`rpcId` 是任意字符串，由客户端生成，只用于回显。
- `method` 必须等于 URL 里 `/api/` 之后的部分，否则返回 `gateway/bad-request`（`:689-693`）。
- 路径段只允许 `[A-Za-z0-9_$.-]`（`:550, 711-716`）。
- `payload` 必须**恰好**是 `{ args: <普通对象> }`，没有别的键（`dsh-api-gateway/lib/types/index.js:817-832`）。
- `args` 的键必须**精确**等于方法描述符的参数线名（`assertExactArguments`，`:1128-1154`）：多了报 `unexpected`，少了报 `missing`。生成描述符里标注可省略的 JSON 参数可以不传；lookup 参数（如 `agentId`）永远不能省。
- 请求体上限默认 300 MiB（`maxRequestBodyBytes`，`dsh-client-connection/lib/index.js:25, 803`），超过 → 413。
- 未被任何方法认领的端点 → **404** `not found`（不是 JSON）（`:620`）。[live] `foo/bar` 和 0.1 的 `session.list` 都是 404。

参数线名的权威来源是各包 `lib/typert.host.js` 里的 `TYPERT.invocations[].parameters[].wire`。提取的完整列表见 `/tmp/dsh02.dfd2/sigs.txt`（格式 `方法 (线名,…)`，`:lookup` 表示 lookup 参数，`[stream]` 表示流方法）。Rowel 关心的方法：

| 端点 | `args` 键 | 备注 |
|---|---|---|
| `session/list` | `_request`（`{}` 或 `{cursor?}`） | 线名就是带下划线的 `_request`（`dsh-api-session-controller/lib/typert.host.js:1119`），`cursor` 目前被忽略 |
| `session/search` | `request: {query}` | |
| `session/create` | `request: {workspaceId?, cwd?, sessionId?, agentPreset?}` | |
| `session/prompt` | `request: {requestId, sessionId, mode, content, clientTimeZone?}` | 见 §7 |
| `session/cancel` | `request: {sessionId}` | |
| `session/updateQueue` | `request: {sessionId, itemId, action}` | |
| `session/page` | `request: {address, throughSeq, beforeSeq?, maxMessages?, turnWindow?}` | |
| `session/projections` | `request: {sessionId}` | |
| `session/rename` | `request: {sessionId, title}` | |
| `session/fork` | `request: {sessionId, atSeq?}` | |
| `session/selectModel` | `request: {sessionId, provider, model, reasoningEffort?}` | |
| `session/modelCatalog` | `{}` | |
| `session/attachment` | `request: {sessionId, attachmentId}` | |
| `skills/list` | `request: {sessionId}` | |
| `commands/list` | `agentId` | lookup，值为 sessionId |
| `commands/execute` | `agentId, line, submittedAttachments` | |
| `fileUploads/upload` | `agentId, request: {data, name?}` | |
| `userQuestions/answer` | `agentId, callId, answer` | |
| `permissionPresets/catalog` | `{}` | |
| `workspace/*` | `request: {...}`（`workspace/follow` 是流，`{}`） | |
| `$events/result` | `clientId, eventId, outcome` | Gateway 内置，见 §5 |

`agentId` 这个 lookup 参数的线类型是 `SessionId`（`dsh-api-session-controller/lib/typert.host.js:896-916`），就是会话 id。

### 2.2 响应

业务成功和业务失败都是 **HTTP 200** + JSON：

```json
{"type":"server-response","rpcId":"r1","result":{"ok":true,"value":{"items":[]}}}
{"type":"server-response","rpcId":"h","result":{"ok":false,"error":{"code":"session/not-found","message":"session \"nope\" not found","details":{"sessionId":"nope"}}}}
```

- 返回 `void` 的方法没有 `value` 字段：`{"ok":true}`（`dsh-api-gateway/lib/types/index.js:477-489`）。[live] `$events/result`、未知斜杠命令都是 `{"ok":true}`。
- 错误码：抛出的 `RemoteError` 原样传出 `code/message/details`；其他异常一律折叠成 `gateway/internal`，`details: {}`（`rpcFailure`，`:1046-1059`）。
- 处理函数自己抛异常（不是返回失败）→ HTTP 500 `handler failure: ...`（`dsh-client-connection/lib/index.js:697-699`）。
- 载体层错误是非 200 且非 JSON（401/403/404/405/413/415/500）。

[live] 实测的错误形状：

| 场景 | 结果 |
|---|---|
| 多传参数 | `gateway/arguments-invalid`，`message: "typert gateway: session/list: args fields do not match the descriptor: unexpected \"x\""`，`details: {"endpoint":"session/list"}` |
| 少传参数 | 同上，`missing \"_request\"` |
| `payload` 没有 `args` | `gateway/internal`，`"Remote payload must contain exactly one plain-object args field"`，`details: {}` |
| `method` 与 URL 不符 | `gateway/bad-request`，`details: {"issues":[]}` |
| 信封非法 | `gateway/bad-request`，`"invalid client-request message"`，`details.issues` 是 zod issue 数组；`rpcId` 回显原值，取不到时为 `"invalid-request"`（`dsh-client-connection/lib/index.js:548, 703-710`） |
| 参数值不合 schema | `gateway/input-invalid`，`details: {"endpoint":"session/page","field":"request"}` |
| 对一元方法开流 | 流上 `error` 帧，`gateway/signature-invalid` |
| 业务错误 | 如 `session/not-found`、`session/model-unavailable`、`session/invalid-time-zone`、`gateway/bad-request`（prompt 内容为空） |

Gateway 自有错误码（`TypertGatewayError`，`dsh-api-gateway/lib/types/index.js:29-47` 及各抛出点）：`gateway/arguments-invalid`、`gateway/input-invalid`、`gateway/signature-invalid`、`gateway/result-invalid`、`gateway/service-unavailable`、`gateway/method-unavailable`、`gateway/definition-unavailable`、`gateway/invocation-unavailable`、`gateway/ambiguous-endpoint`、`gateway/binding-invalid`、`gateway/context-*`、`gateway/lookup-*`、`gateway/provider-mismatch`、`gateway/cancelled`、`gateway/uplink-overflow`、`gateway/protocol`、`gateway/internal`、`gateway/bad-request`。Session 域错误码和 details 形状见 `dsh-api-session-controller/lib/types/types.d.ts:180-239`；工作区域见 `dsh-api-workspace-controller/lib/types/types.d.ts:26-69`。

取消：一元请求的 HTTP 连接断开会中止方法的 `AbortSignal`（`dsh-client-connection/lib/index.js:35-38`），有 `signal` 参数的方法会以 `gateway/cancelled` 结束（`dsh-api-gateway/lib/types/index.js:897-899`）。

### 2.3 结果可以是二进制 [live]

方法结果里含 `Uint8Array` 时，响应变成 `multipart/form-data`（`dsh-client-connection/lib/index.js:723-754`；Gateway 侧抽取在 `dsh-api-gateway/lib/types/index.js:695-761`）：

- 每段字节是一个 part，名为 `bytes-<n>`；
- `metadata` part 是 JSON 信封，字节原位置填 `null`，另加 `attachments: [{path, codec:"bytes", part}]`。

[live] `workspaceFiles/readBytes` 实测：

```
content-type: multipart/form-data; boundary=----formdata-undici-081974892969
--…  name="bytes-0"; filename="blob"  →  alpha
--…  name="metadata"  →
{"type":"server-response","rpcId":"rb1","result":{"ok":true,"value":{"absolutePath":"/private/tmp/dshref/ws2/a.txt","version":"…","bytes":5,"offset":0,"data":null,"eof":true}},"attachments":[{"path":["data"],"codec":"bytes","part":"bytes-0"}]}
```

失败结果永远是 JSON。参数、事件、流结果都不支持二进制（README）。`session/attachment` 返回的是 base64 字符串，不走 multipart。

另外 webserver 默认开 gzip（阈值 1024 字节，`dsh-web-app/cordis.patch.yml:169-177`），发了 `Accept-Encoding: gzip` 就会收到压缩响应。

### 2.4 非 RPC 的精确路由（同样需要 cookie）

| 路由 | 方法 | 用途 | 出处 |
|---|---|---|---|
| `/api/session/uploadFileBinary?sessionId=&name=` | POST，`Content-Type: application/octet-stream`，流式请求体 | 上传文件，返回 `{ok, value:{receiptId, file}}` JSON | `dsh-client-file-upload/lib/index.js:13-56, 73` |
| `/api/file?path=<绝对路径>` | GET/HEAD | 读主机任意文件（上限 `maxImageBytes`，20 MiB），`private, no-store` + 沙箱 CSP | `dsh-api-session-controller/lib/index.js:2397` 附近；README "Session media references" |
| `/api/session.export?sessionId=&includeDescendants=` | GET/HEAD | 会话日志 ZIP（**路径和 0.1 相同**） | `dsh-session-log-export/lib/index.js:488, 518-561` |
| `/api/changes.summary?sessionId=&seq=` | GET | `workspace/changes` 事件对应的变更摘要 | `dsh-client-ui-deliverables/lib/index.js:4, 170-185` |
| `/api/changes.diff?sessionId=&seq=&index=` | GET | 单文件 diff | 同上 `:6, 188-212` |
| `/api/changes.open`、`/api/present.open`、`/api/present.host` | GET/POST | 在主机桌面打开文件（需要 desktop 可用） | 同上 `:8-17, 27-75` |

[live] `changes.summary` → `{"turn":1,"files":[{"path":"a.txt","display":"a.txt","added":1,"deleted":0}],"total":1,"added":1,"deleted":0}`；`changes.diff` → `{"kind":"text","path":"a.txt","display":"a.txt","before":false,"after":true,"hunks":[{"oldStart":1,"oldLines":0,"newStart":1,"newLines":1,"lines":["+alpha"]}],"coarse":false}`；`/api/file` → 200 `text/plain` `alpha`；`session.export` → 200 `application/zip`。

---

## 3. 流：`WS /api/remote.mux`

### 3.1 连接

- 路径 `/api/remote.mux`（`dsh-api-gateway/lib/types/stream-protocol.js:4`）。普通 GET（不升级）→ 404 [live]。
- 认证同 §1；非浏览器客户端在升级请求里带 `Cookie`、合法 `Host`，不要带跨站 `Origin`。
- 只有应用启动完成（`appReady`）后才注册升级路由；在此之前连接会失败，由客户端重试（`dsh-api-gateway/lib/types/index.js:105-119`）。
- 所有消息都是 **JSON 文本帧**。发二进制帧 → 服务端以 **1003** `text messages required` 关闭（`stream-server.js:113-117`）。[live]

### 3.2 客户端 → 服务端帧（`parseRemoteStreamClientMessage`，`stream-protocol.js:148-170`）

键集必须**精确**匹配，多一个键都算非法：

```json
{"type":"open","streamId":"f1","endpoint":"session/follow","payload":{"args":{"request":{…}}}}
{"type":"item","streamId":"f1","value":<JSON>}        // 上行数据；value 可省略（表示 undefined）
{"type":"end","streamId":"f1"}                         // 上行半关闭
{"type":"cancel","streamId":"f1"}                      // 取消整个逻辑流
```

- `streamId`：客户端生成的非空字符串，在**同一 socket** 内唯一。
- `endpoint`：`<ns>/<method>`，或内置的 `$events`。`payload` 规则同一元调用（`{args:{…}}`）。
- 任何解析失败 → socket 以 **1008** `invalid Remote stream request` 关闭（`stream-server.js:118-123`）。
- 对**还在活动**的 streamId 再发 `open` → 1008 关闭（`:164-167`）。[live]
- 对已结束或不存在的 streamId 发 `item/end/cancel` → 静默丢弃（`:138-156`）。[live] 对不存在的 id 发 `item`，socket 仍然 OPEN。

### 3.3 服务端 → 客户端帧（`parseRemoteStreamServerMessage`，`stream-protocol.js:176-198`）

```json
{"type":"item","streamId":"f1","value":<JSON>}
{"type":"end","streamId":"f1"}
{"type":"error","streamId":"f1","error":{"code":"…","message":"…","details":{…}}}
```

- 每个逻辑流最多一个终止帧（`end` 或 `error`）（`pump`，`stream-server.js:187-221`）。
- 客户端 `cancel` 之后，服务端**不发**任何终止帧（`:201-210`：中止原因不是 RemoteError 时直接返回）。[live] cancel `workspace/follow` 后没有后续帧。
- 例外：如果中止原因是 RemoteError（上行溢出、`end` 后又发 `item`、上行项校验失败），服务端会发 `error` 帧（`:204-208`）。
- 打开阶段失败（参数错、找不到会话等）也以 `error` 帧报告，不关 socket。[live]：

```json
{"type":"error","streamId":"bad","error":{"code":"gateway/arguments-invalid","message":"typert gateway: session/follow: args fields do not match the descriptor: missing \"request\"","details":{"endpoint":"session/follow"}}}
```

- 终止帧无法编码或写出时，socket 以 **1011** 关闭（`:222-233`）。

### 3.4 背压与上行限额

- **下行没有应用层流控**。服务端按顺序 `await socket.send` 写出（`stream-server.js:234-256`），慢客户端只会让服务端写缓冲变大。
- 上行每个逻辑流最多缓存 `streamInboxBytes`（默认 262144）字节的帧，超过 → `gateway/uplink-overflow`；`end` 之后再发 `item` → `gateway/protocol`。两种都只失败这个逻辑流，不关 socket（`stream-server.js:265-353`；默认值 `dsh-api-gateway/lib/types/index.js:18, 55-59`）。
- 绝大多数 Rowel 用到的流（follow、control、workspace/follow、$events）不读上行。`$events` 打开时就释放上行，发过来的 `item` 直接丢弃（`index.js:271-276`）。

### 3.5 心跳

- 服务端每 `websocketHeartbeatIntervalMs`（默认 2000 ms）发 WebSocket **Ping 控制帧**；客户端协议层自动回 Pong（`stream-server.js:73-94`）。[live] 第一次 ping 在连接后约 2005 ms。
- 每次 Ping 计一次未应答，收到 Pong 清零；累计 `MAX_MISSED_HEARTBEATS = 2` 次未应答就 `terminate()`（`:6, 80-89`）。实际含义：大约 4–6 秒不回 Pong 会被断开。
- 应用层没有心跳帧。

### 3.6 断线

- socket 关闭时，服务端停止这个 socket 上的所有逻辑流（`stream-server.js:126-130`）。
- 连接认证所属的 Peer（operator）被释放时，socket 以 **1001** `peer left` 关闭（`:359-367`）。
- **没有任何流级别的续传**。重连 = 新 socket + 重新 `open` 每个流。各个领域自己负责基线：
  - `session/follow`：重新打开拿新快照（§4.4）。
  - `session/control`、`workspace/follow`：每次打开先发完整 `baseline`。
  - `$events`：新 `clientId`；**仍在等待的 waterfall（审批、提问）会重发给新客户端，eventId 不变**；普通 `emit` 通知不补发（§5.4）。
- 官方浏览器客户端的重连节奏（只是参考，不是协议要求）：50%–100% 抖动，上限依次 500 ms、1 s、2 s、4 s、8 s、10 s，之后一直 10 s；`$events` 的 `ready` 3 s 未到告警，15 s 超时重来（`dsh-client-connection/README.md` "Connection generation"；默认值 `lib/index.js:768-774`）。

### 3.7 示例 [live]

同一 socket 上开 5 个流（`$events`、`workspace/follow`、`session/control`、一个参数错的 follow、一个对一元方法开流），收到的帧：

```
{"type":"item","streamId":"e1","value":{"type":"ready","clientId":"7089645d-…","host":{"home":"/Users/alpha"}}}
{"type":"item","streamId":"w1","value":{"type":"baseline","value":{"items":[],"archivedSessionIds":[],"pinnedSessionIds":[]}}}
{"type":"error","streamId":"bad","error":{"code":"gateway/arguments-invalid",…}}
{"type":"error","streamId":"u1","error":{"code":"gateway/signature-invalid","message":"typert gateway: session/list: unary Remote methods cannot be opened through the stream carrier",…}}
{"type":"item","streamId":"c1","value":{"type":"baseline","value":{"projections":{}}}}
(ping @2005ms)
(对 e1 重复 open) → close 1008 "invalid Remote stream request"
```

注意 `ready.host.home` 是 dsh 进程的 `os.homedir()`，不是 `DSH_HOME`（`dsh-api-remotes/lib/index.js:133-135`）。

---

## 4. 会话同步：`session/follow` + `session/page`

### 4.1 `session/follow`（流）

请求（`SessionFollowRequest`，`dsh-api-session-controller/lib/types/types.d.ts:459-463`）：

```json
{"type":"open","streamId":"f","endpoint":"session/follow","payload":{"args":{"request":{
  "address":{"kind":"session","sessionId":"session-…"},
  "assistantStream":true,
  "maxMessages":50,
  "turnWindow":{"minMessages":50,"minTurns":2}
}}}}
```

- `address`（`types.d.ts:386-394`）：`{kind:'session', sessionId}`，或子代理 `{kind:'subagent', parentSessionId, childSessionId, mode:'one-shot'|'continuable'|'unknown'}`。子代理会话**必须**用 subagent 地址，用 session 地址会得到 `session/agent-busy`，`details.reason: "use subagent delivery for this child session"`（`lib/index.js` `validateAddress`）。[live]
- `assistantStream: true`：额外推送进程内的流式 token 帧。不传则只有持久事件。
- `maxMessages` / `turnWindow`：决定快照尾页大小，规则同 `session/page`（4.3）。
- **follow 没有"从某个 seq 之后开始"的参数**。每次打开都从当前 cursor 拿一个尾页快照。
- 打开 follow 不会激活 Agent；如果会话是冷的，快照发出后才把它提升为普通会话（`lib/index.js:1521-1528`）。

帧序列（`SessionFollowFrame`，`types.d.ts:516-527`；实现 `lib/index.js:1445-1560`）：

1. 第一帧永远是 **snapshot**：

```ts
{ type: 'snapshot',
  header: { version, id, createdAt, cwd?, parentSession?, isSeeded, origin?, delegationDepth?, agentPreset? },
  cursor: number,            // 快照截止的最后一个 seq（含），空日志为 -1
  records: { type:'event', event: SessionWireEvent }[],   // 尾页，连续，最后一条 seq == cursor
  hasMore: boolean,          // 尾页之前还有更早的事件
  projections: { asOfSeq: number, values: { <key>: JSON } },
  assistantStream?: { revision: number, activeAttempt?: {
      attemptId, startedAfterSeq, turn, step, nextIndex, stream: AssistantStreamRecord[] } } }
```

2. 之后按 seq 严格递增、无缺口地推送持久事件：`{ type:'event', event }`。服务端内部会丢弃 `seq <= cursor` 的重复，发现跳号时以 `gateway/internal` "session event stream skipped seq N" 失败（`lib/index.js:1545-1551`）。
3. `assistantStream:true` 时穿插 `{ type:'assistant-stream', frame }`（4.2）。快照之前已缓冲的流式帧会按到达序号截掉，不重复（`:1508, 1539-1544`）。

[live] 新建会话打开 follow 的快照（截断）：

```json
{"type":"snapshot",
 "header":{"version":4,"id":"session-522162a9-…","createdAt":1791022176025,"cwd":"/tmp/dshref/ws","isSeeded":false,"agentPreset":"standard"},
 "cursor":2,
 "records":[
  {"type":"event","event":{"type":"permission/preset","seq":0,"time":1791022176028,"data":{"preset":"workspace-write"}}},
  {"type":"event","event":{"type":"sandbox/mode","seq":1,"time":1791022176029,"data":{"mode":"workspace-write"}}},
  {"type":"event","event":{"type":"approval/policy","seq":2,"time":1791022176029,"data":{"policy":"ask"}}}],
 "hasMore":false,
 "projections":{"asOfSeq":2,"values":{"title":null,"goal":null,"tokenUsage":{…},"contextPressure":{},"inbox":{"next-turn":[],"next-step":[]},"sessionStats":{…},"turnOutline":[],"agentPreset":"standard","userQuestions":{"active":[],"settled":[]},"subagentCatalog":[],"subagent":null,"permissions":{"currentValue":"workspace-write"},"todos":null,"plan":{"active":false,"pending":false},"modelSelection":{…},"sessionListMetadata":{…},"imageLimits":{…}}},
 "assistantStream":{"revision":0}}
```

[live] 一次简单回答的增量（省略 system/request 事件）：

```
{"type":"event","event":{"type":"agent/inbox/spliced","seq":3,…,"data":{"target":"next-turn","start":0,"inserted":[{"content":[{"type":"text","text":"Reply with exactly: hello there…"}],"source":{"kind":"user","rpcId":"req-1"},"role":"user","id":"d21e37f8-…"}]}}}
{"type":"event","event":{"type":"turn/start","seq":4,…,"data":{"turn":1}}}
{"type":"event","event":{"type":"agent/inbox/spliced","seq":5,…,"data":{"target":"next-turn","start":0,"removedCount":1,"inserted":[]}}}
{"type":"event","event":{"type":"step/start","seq":7,…,"data":{"turn":1,"step":1}}}
{"type":"event","event":{"type":"system/message","seq":8,…}}
{"type":"event","event":{"type":"user/message","seq":9,…,"data":{"content":[…],"source":{"kind":"user","rpcId":"req-1"},"role":"user","id":"d21e37f8-…"},"surfaceOp":"append"}}
{"type":"event","event":{"type":"user/message","seq":10,…,"data":{…,"source":{"kind":"runtime-context","form":"snapshot","sections":[…]}},"surfaceOp":…}}
{"type":"event","event":{"type":"request/header","seq":11,…}}
{"type":"event","event":{"type":"request/context","seq":12,…,"data":{"provider":"commandcode","model":"deepseek/deepseek-v4.1-flash","contextWindow":1000000}}}
{"type":"assistant-stream","frame":{"type":"start","attemptId":"session-522162a9-…:1","revision":1,"turn":1,"step":1,"startedAfterSeq":12}}
{"type":"event","event":{"type":"session/title","seq":13,…,"data":{"title":"Reply with exactly: hello there.","messageSeqs":[9],"source":{"kind":"fallback"}}}}
{"type":"assistant-stream","frame":{"type":"chunk",…,"revision":2,"index":0,"time":…,"chunk":{"type":"block-start","index":0,"blockType":"text"}}}
{"type":"assistant-stream","frame":{"type":"chunk",…,"revision":3,"index":1,"chunk":{"type":"text-delta","index":0,"text":"hello there."}}}
{"type":"assistant-stream","frame":{"type":"chunk",…,"revision":4,"index":2,"chunk":{"type":"block-end","index":0,"block":{"type":"text","text":"hello there."}}}}
{"type":"assistant-stream","frame":{"type":"chunk",…,"revision":5,"index":3,"chunk":{"type":"usage","usage":{"inputTokens":6573,"outputTokens":4,"totalTokens":6577}}}}
{"type":"assistant-stream","frame":{"type":"chunk",…,"revision":6,"index":4,"chunk":{"type":"finish","reason":{"kind":"stop"},"replayState":{…}}}}
{"type":"event","event":{"type":"assistant/message","seq":15,…,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"hello there."}],"source":{"kind":"model",…},"id":"4a1edfbe-…"},"usage":{…},"stream":[…]},"surfaceOp":"append"}}
{"type":"assistant-stream","frame":{"type":"end",…,"revision":7,"index":5,"outcome":{"kind":"committed","eventType":"assistant/message","seq":15}}}
{"type":"event","event":{"type":"step/end","seq":16,…}}
{"type":"event","event":{"type":"turn/end","seq":17,…,"data":{"turn":1,"reason":{"kind":"completed"}}}}
```

### 4.2 assistant 流帧

类型（`types.d.ts:465-509`）：

```ts
{ type:'start', attemptId, revision, startedAfterSeq, turn, step }
{ type:'chunk', attemptId, revision, index, time, chunk: StreamChunk }
{ type:'end',   attemptId, revision, index /* chunk 总数 */,
  outcome: {kind:'committed', eventType:'assistant/message'|'assistant/attempt', seq} | {kind:'abandoned'} }
```

- `revision`：每个会话一个计数器，每帧 +1，跨 attempt 连续。官方客户端要求严格 +1，跳号就当载体故障重开 follow（`dsh-api-session-controller/lib/client.js:451-454`）。替换的 Agent 可能从 1 重新计数（README）。
- `index`：attempt 内 chunk 的稠密序号，从 0 开始；`end.index` 等于 chunk 总数。
- `startedAfterSeq`：attempt 开始时最后一个持久 seq。
- `attemptId` 实测形如 `<sessionId>:<n>`。[live]
- 提交顺序：`assistant/message`（或 `assistant/attempt`）持久事件**先于**对应的 `end` 帧到达。[live] 见上例 seq 15 在 `end` 之前。
- `abandoned`：没有持久事件，客户端应直接丢掉这段临时内容。
- 快照里的 `assistantStream.activeAttempt` 是重连时正在进行的 attempt：`stream` 是到快照为止的紧凑流（格式同持久事件里的 `stream`），`nextIndex` 是下一个 chunk 帧的 index。[live] 中途打开 follow：

```json
"assistantStream":{"revision":171,"activeAttempt":{"attemptId":"session-f8db…:5","startedAfterSeq":46,"turn":2,"step":1,"nextIndex":28,"stream":[{"type":"chunk","time":…,"chunk":{"type":"block-start","index":0,"blockType":"reasoning"}},{"type":"reasoning-chunks","time0":…,"index":0,"dt":[1,0,99,…],"texts":["The"," user",…]},…]}}
```

紧接着的第一帧是 `{"type":"chunk",…,"revision":172,"index":28,…}`。[live]

StreamChunk 类型（`dsh-llm/lib/types/types.d.ts:418-445`）：`block-start {index, blockType}`、`text-delta {index, text}`、`reasoning-delta {index, text}`、`tool-call-delta {index, id, name, argumentsDelta}`、`block-end {index, block}`、`usage {usage}`、`finish {reason, replayState}`。

### 4.3 `session/page`（一元）

请求（`types.d.ts:444-457`）：

```ts
{ address, throughSeq: number, beforeSeq?: number, maxMessages?: number,
  turnWindow?: { minMessages: number, minTurns: number } }
```

语义（`lib/index.js:1410-1441` 和 `paginate` `:1652-1683`）：

- 返回 `{ records, hasMore }`，`records` 是一段**连续**事件 `[cut, end)`，其中 `end = min(throughSeq + 1, beforeSeq ?? throughSeq + 1)`。
- `throughSeq`：读取窗口的上界，应该用 follow 快照给的 `cursor`（或之后已经应用到的 seq）。`throughSeq > 当前日志末尾` → `gateway/bad-request` "session page through seq N is past cursor M"。[live] `throughSeq: -1` 返回空页。
- `beforeSeq`：向更早翻页时传当前窗口第一条的 seq，返回的都是 `< beforeSeq` 的事件。
- 方向只有一个：从 `end` 往回数。
- 计数规则：只数 `surfaceOp` 为 append 的 `user/message` 和 `assistant/message`。数到 `maxMessages`（默认 **50**，`:1373`）时，在这条消息的分组起点截断（分组起点 = 自身 seq 与其 `sourceEventSeqs` 里的最小值）。中间的其他事件随页附带，不计数。
- 有 `turnWindow` 时，往回遇到 `turn/start` 就计一个 turn；当消息数 ≥ `minMessages` **且** turn 数 ≥ `minTurns` 时，在这个 `turn/start` 处截断；否则直到 `maxMessages` 或日志开头。
- 校验（`:1610-1622`）：`throughSeq` 是 ≥ -1 的安全整数；`beforeSeq` ≥ 0；`maxMessages` > 0；`turnWindow.minMessages` 必须 ≤ `maxMessages`（未传时按 50 算），`minTurns` > 0。
- `hasMore = cut > 0`。
- 不激活 Agent，冷会话也能读。
- 官方 Web 客户端的参数：follow 和 `loadOlder` 用 `maxMessages: 500, turnWindow: {minMessages: 50, minTurns: 2}`；跳转加载用 `minMessages: 200`（`dsh-api-session-controller/lib/client.js:1552-1565`）。

[live] 对一个 74 条事件的会话：

- `throughSeq:70, maxMessages:3` → seq 59–70，`hasMore:true`
- 再以 `beforeSeq:59` → seq 41–58，`hasMore:true`
- `throughSeq:70, turnWindow:{minMessages:1,minTurns:2}` → seq 37–70（截在倒数第二个 turn 的 `turn/start`）
- `throughSeq:99999` → `gateway/bad-request`

### 4.4 组合成"打开会话 → 先显示尾部 → 滚动加载更早 → 重连不丢不重"

官方实现（`RemoteJournalStream`，`dsh-api-gateway/lib/types/client/journal-stream.js`；会话适配 `dsh-api-session-controller/lib/client.js:400-485`）的做法：

1. **打开**：开 `session/follow`（带 `assistantStream:true` 和 turnWindow）。快照的 `records` 就是尾部，`cursor` 是窗口的末尾，直接整体显示（`replace`）。
2. **增量**：每个 `event` 帧的 seq 必须等于 `lastSeq + 1`；`seq <= lastSeq` 的直接丢弃（完全重复）；跳号则做缺口修复：用 `session/page {throughSeq: 收到的 seq, …}` 读一页替换窗口（`journal-stream.js:186-243`）。
3. **加载更早**：`session/page {address, throughSeq: lastSeq, beforeSeq: firstSeq, maxMessages, turnWindow}`，把返回的记录拼到前面。要求页末尾正好接上 `firstSeq - 1`，否则视为不连续（`:80-106`）。
4. **重连**：重新打开 follow，拿到新快照。新 `cursor` 不能小于已应用的最后 seq（否则协议错误，`:162-165`）。官方做法是**用新快照整体替换窗口**，而不是把新旧窗口拼起来（`replaceFromOpening`，`:171-185`）。之前加载过的更早页丢弃，需要时重新翻。
5. **流式内容**：快照的 `activeAttempt.stream` 作为临时内容先展示；后续 `chunk` 帧追加；对应的持久 `assistant/message`/`assistant/attempt` 到达后替换临时内容；`end` 帧确认。`revision` 不连续时重开 follow。

如果客户端想保留旧窗口、只补缺口（官方没有这么做）：重连后新快照的第一条 seq 为 S，客户端已有到 L 的事件。若 `S <= L + 1`，直接合并去重；否则循环 `session/page {throughSeq: 新 cursor, beforeSeq: S}` 往回补，直到页首 ≤ L + 1。这一条是根据 page 语义推出来的，**没有实测**。

注意：follow 快照之后的 `event` 帧是"快照 cursor 之后的所有事件"，服务端保证不跳号（内部缓冲 `session/event` 并检查连续性）。

---

## 5. 审批与提问

### 5.1 `$events` 流

打开：

```json
{"type":"open","streamId":"ev","endpoint":"$events","payload":{"args":{}}}
```

`args` 必须是空对象，否则 `gateway/arguments-invalid`（`dsh-api-gateway/lib/types/index.js:292-301`）。

服务端下发的 `value` 有四种（`index.js:292-352, 381-390, 463-468`）：

```ts
{ type:'ready', clientId: string, host: { home: string } }       // 第一项，必有
{ type:'emit', event: string, args: JSON[] }                      // 普通通知
{ type:'waterfall', event: string, eventId: string, agentId: string, request: JSON }  // 需要应答
{ type:'cancel', eventId: string }                                // 该 waterfall 已结束（别的客户端答了、或被取消）
```

- `clientId` 在每次打开 `$events` 时新生成（UUID），标识"这一代连接"。
- 转发哪些事件由白名单决定（`dsh-api-remotes/lib/types/remote-events.js:12-40`）。waterfall 只有两个：`approval/request` 和 `user-questions/request`。emit 有：`agent-preset/selected`、`api-session/activity|added|error|removed|status`、`commands/change`、`deepseek-account/session-expired|model-sign-in-required`、`credentials/record-updated|reference-updated`、`goal/activation-changed`、`cordis/*`（6 个）、`llm/adapters-updated`、`permission-presets/catalog-changed`、`plugin-manager/changed|install-log|install-state`、`settings/document-updated`、`schedule/changed`。
- waterfall 的 `request` 去掉了 `agent` 和 `signal` 字段，只保留 JSON 字段（`dsh-api-gateway/lib/types/stream-protocol.js:61-86`）。`agentId` 是 `agent.id`；对普通会话，它等于 sessionId。[live]

### 5.2 `approval/request`

`request` 字段（`ApprovalRequestEvent`，`dsh-user-approval/lib/types/types.d.ts:55-71`）：`toolName: string`、`callId?: string`、`reason?: string`、`displayReason?: {en: string, [locale]: string}`。

[live]

```json
{"type":"waterfall","event":"approval/request","eventId":"3824b6e1-71ca-4462-bc64-ab7aa98e8b9c","agentId":"session-8a915b6f-…","request":{"toolName":"bash","callId":"call_00_43jk9exuu76uznsuc7wvypqf","reason":"escalate sandbox to danger-full-access: protocol test","displayReason":{"en":"Allow this operation with danger-full-access permissions: protocol test","zh":"允许本次操作使用 danger-full-access 权限：protocol test"}}}
```

应答值是 `ApprovalOutcome`（`types.d.ts:26`）：`'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`。UI 实际只该发 `allowed-once` 或 `rejected`。

会话日志里同时出现审计事件 `approval/asked {id, toolName, callId?, reason?}` 和 `approval/decided {id, outcome}`（`types.d.ts:37-51`）。**`approval/asked.id` 和 waterfall 的 `eventId` 是两个不同的 id**，两者只能用 `callId` 对上。[live] eventId `8460bf20-…` 对应的审计 id 是 `7b80ceb6-…`。

[live] 拒绝后的日志：

```
{"type":"approval/asked","seq":67,…,"data":{"id":"8b19cae0-…","toolName":"bash","callId":"call_00_43jk…","reason":"escalate sandbox to danger-full-access: protocol test"}}
{"type":"approval/decided","seq":68,…,"data":{"id":"8b19cae0-…","outcome":"rejected"}}
{"type":"tool/result","seq":69,…,"data":{…,"content":[{"type":"text","text":"Error: the user rejected escalating this command to \"danger-full-access\"; it stays denied, so stop and explain instead of working around it"}],"isError":true,…},"sourceEventSeqs":[66],"surfaceOp":"append"}
```

触发条件（实测）：`workspace-write` 预设下沙箱拒绝了操作，模型用 `sandbox_permissions` 重试，才会弹审批。approval policy 为 `never` 时（`danger-full-access` 预设）直接拒绝，不弹。

### 5.3 `user-questions/request`

`request` 字段（`AskUserQuestionRequestEvent`，`dsh-user-questions/lib/types/types.d.ts:118-135`）：

```ts
{ questions: { id, question, detail?, header?, options?: {label, description?}[], multiSelect?,
               intent?: { kind:'plan-review', approve: string, callId? } }[],
  wait?: { callId, timed?: true } }
```

[live]

```json
{"type":"waterfall","event":"user-questions/request","eventId":"579cda7e-…","agentId":"session-8a915b6f-…","request":{"questions":[{"id":"color","question":"Pick a color","header":"Pick a color","options":[{"label":"Red"},{"label":"Blue"}]}]}}
```

应答值是 `AskUserQuestionAnswer`（`types.d.ts:58-61`）：`{ answers: [{ id, selected: string[], custom?: string }] }`。单选题有 `custom` 时 `selected` 为空；多选题 `custom` 可以和 `selected` 并存；跳过的题可以发 `{id, selected: []}`（README）。

[live] 回答后工具结果：`{"answers":[{"id":"color","selected":["Blue"]}]}`。

默认的 `ask_user_question` 是阻塞的 legacy 模式；带倒计时的 timed 模式要在配置里开（`dsh-tool-ask-user/lib/index.js:212-219`，`mode: 'legacy' | 'timed'`，默认 legacy）。timed 模式下：

- `wait.timed: true` 时，答题 UI 应先打开流 `userQuestions/attachWait {agentId, callId}` 占住等待，服务端回一项 `{remainingMs}`，流关闭即释放占用（`dsh-user-questions/lib/index.js:297-370, 596-600`）。
- 没有客户端占住时，服务端到期后释放模型，问题变成 `continued` 状态（`askTimed`，`:613-650`）。
- 客户端倒计时结束时可以用 `outcome: {kind:'rejected', error:{name:'UserQuestionError', message:'…', code:'ASK_TIMED_OUT'}}` 结束这次等待，服务端把它映射成 pending 结果。
- `continued` 的问题出现在 `userQuestions` 投影的 `active` 里，用 **`userQuestions/answer {agentId, callId, answer}`** 作答：答案作为 `user-question-reply` 消息 steer 进 agent（`:552-594`）。答案必须恰好覆盖该调用的每道题，否则 `BAD_ANSWER`；已有回复在排队时报 `REPLY_QUEUED`；问题不是 continued 时返回 `false`。

timed 模式未实测。

### 5.4 应答：`POST /api/$events/result`

```json
{"type":"client-request","rpcId":"r4","method":"$events/result","payload":{"args":{
  "clientId":"<ready 帧里的 clientId>",
  "eventId":"<waterfall 帧里的 eventId>",
  "outcome":{"kind":"result","value":"allowed-once"}
}}}
```

`outcome` 三种（`dsh-api-gateway/lib/types/stream-protocol.js:18-54`），键集必须精确：

- `{kind:'result', value?: JSON}`：给出答案。
- `{kind:'next'}`：本客户端不处理，交给下一个监听者。
- `{kind:'rejected', error:{name, message, code?, details?}}`：以错误结束这次 waterfall。

返回成功时是 `{"ok":true}`，无 value。[live]

多客户端语义（`index.js:353-469`）：

- waterfall 发给所有当前连接的 `$events` 客户端，eventId 相同。[live] A、B 都收到同一个 eventId。
- **先到的 `result` 获胜**。服务端结束 waterfall，并给其余仍持有它的客户端发 `{type:'cancel', eventId}`。[live] B 回答问题后 A 收到 cancel；C 回答审批后 B 收到 cancel。回答者自己不会收到 cancel。
- `rejected` 也会立即结束（并 cancel 其他客户端）。
- `next` 只有在**所有**持有者都回了 `next` 后才交给下一个监听者（`:432-434`）。
- 迟到的结果（waterfall 已结束，或这个客户端已不在持有者里）是**幂等的空操作**，仍然返回 `{"ok":true}`（`:416-421`）。[live] B 在 C 之后回答 → `{"ok":true}`；不存在的 eventId → `{"ok":true}`。
- `clientId` 不是任何活动 `$events` 流 → `gateway/internal` "Remote event result identifies no active event stream"。[live]
- `outcome` 格式非法 → `gateway/internal` "api gateway: invalid Remote event result"。[live]
- 客户端断开时，它持有的 waterfall 只是移除这一个持有者，不结束（`:440-445`）。
- **新客户端连上时，所有仍在等待的 waterfall 重发给它，eventId 不变**（`:317-318`）。[live] 后来打开的 C 立即收到 `ready` 和同一个 `approval/request`。
- **没有任何客户端时，waterfall 一直等**，不会自动失败；Agent 卡在这次工具调用上，直到有客户端回答或 turn 被取消。[live] 无客户端 25 秒后再连，审批照样重发，回答后正常继续。
- turn 被取消时 waterfall 的 signal 中止，服务端给持有者发 `cancel`（`:374-402`）。

---

## 6. 会话列表与工作区

### 6.1 `session/list`

`args: {_request: {}}`。返回 `{ items: SessionSummary[] }`，按活跃度排序（`dsh-api-session-controller/lib/index.js:2954-2956`）。没有分页，`cursor` 被忽略。只读存储的 header 和投影缓存，不打开冷会话日志（README）。

`SessionSummary`（`types.d.ts:159-170`）：

```ts
{ agentAvailable: boolean, sessionId, updatedAt: number, running: boolean, blank: boolean,
  parentSessionId?: string, origin?: 'subagent', cwd?: string,
  projections?: { kind: 'cached'|'sequenced', asOfSeq: number, values: {…} } }
```

- `kind: 'sequenced'`：会话已挂载，`asOfSeq` 可以和同一连接上的快照、投影帧比较。`'cached'`：来自持久化投影缓存，`asOfSeq` 不能和活会话的值比较（`types.d.ts:51-64`）。
- **子代理会话也在列表里**，带 `origin: 'subagent'` 和 `parentSessionId`。[live] 子代理 sessionId 是裸 UUID（`3c0e4ed8-…`），普通会话是 `session-<uuid>`。
- fork 出来的会话有 `parentSessionId` 但没有 `origin`。[live]

[live] 一行（截断）：

```json
{"sessionId":"session-8a915b6f-…","updatedAt":1791022410573,"agentAvailable":true,"running":false,"blank":false,"cwd":"/tmp/dshref/ws",
 "projections":{"kind":"sequenced","asOfSeq":74,"values":{"title":"Bash tool approval protocol test","turnOutline":[{"turn":1,"seq":4,"prompt":"This is a protocol test. Call the bash tool exact…","response":"done One deviation…"},…],"sessionListMetadata":{"blank":false,"lastPromptAt":1791022410573},…}}}
```

### 6.2 标题

- 标题是投影键 `title`（`string | null`），出现在 list 行、follow 快照、`session/projections`、`session/control` 帧里。
- 持久事件 `session/title {title, messageSeqs, source}`。`source.kind` 实测有 `fallback`（首条提示截断）、`provider`（LLM 生成，带 `provider` 和 `model`）、`user`（重命名）。[live]
- `session/rename {sessionId, title}` → `{title, seq}`，并追加一条 `source: {kind:'user'}` 的 `session/title`。[live] 标题非法 → `session/title-invalid`。

### 6.3 `api-session/*` 主机事件（`$events` 的 emit）

签名（`types.d.ts:546-583`），`args` 是位置参数数组：

| event | args |
|---|---|
| `api-session/added` | `[SessionSummary]`，会话出现或 Agent 创建/销毁时；按 upsert 处理 |
| `api-session/removed` | `[sessionId]` |
| `api-session/status` | `[sessionId, running: boolean]` |
| `api-session/activity` | `[sessionId, updatedAt]`，用户消息推进了排序时间 |
| `api-session/error` | `[sessionId, message]` |

[live]：

```json
{"type":"emit","event":"api-session/status","args":["session-522162a9-…",true]}
{"type":"emit","event":"api-session/activity","args":["session-522162a9-…",1791022178122]}
{"type":"emit","event":"api-session/added","args":[{"sessionId":"3c0e4ed8-…","updatedAt":…,"agentAvailable":true,"running":false,"blank":true,"parentSessionId":"session-f8db…","origin":"subagent","cwd":"/tmp/dshref/ws2","projections":{…}}]}
```

观察到的细节：同一个 `api-session/added` 常常连发两次 [live]，消费端必须按 upsert 去重。`api-session/status false` 可能比 follow 流上的最后几条事件先到 [live]，两条流之间没有顺序保证。

### 6.4 `session/control`（流）

`args: {}`。帧（`types.d.ts:529-545`；实现 `lib/index.js:1156-1185`）：

```ts
{ type:'baseline', value: { projections: { [sessionId]: { asOfSeq, values } } } }   // 每次打开第一帧
{ type:'projection', sessionId, key, value: JSON, seq }                                // 之后逐键推送
```

- baseline 只包含**当前挂载**的会话（`ctx.sessions.list()`）。[live] 新实例上 baseline 是 `{"projections":{}}`。
- 每次重连都是完整 baseline，应替换而不是累加；同一代内用 `seq` 判断新旧（README）。
- [live] 帧样例：`{"type":"projection","sessionId":"session-522162a9-…","key":"inbox","value":{"next-turn":[…],"next-step":[]},"seq":28}`。实测出现过的 key：`inbox`、`turnOutline`、`subagentTiming`、`sessionStats`、`contextPressure`、`contextBreakdown`、`sessionListMetadata`、`plan`、`modelSelection`、`tokenUsage`、`permissions`。

### 6.5 工作区

一元方法（`dsh-api-workspace-controller/lib/types/types.d.ts:70-141`，都是 `args: {request: …}`）：

| 方法 | request | 返回 |
|---|---|---|
| `workspace/create` | `{path}` | `{workspace: WorkspaceView, created}` |
| `workspace/rename` | `{workspaceId, title}` | `{workspace}` |
| `workspace/delete` | `{workspaceId}` | `{deleted: true}` |
| `workspace/insertBefore` | `{workspaceId, beforeWorkspaceId?}` | `{workspaceIds}` |
| `workspace/insertSessionBefore` | `{workspaceId, sessionId, beforeSessionId?}` | — |
| `workspace/archiveSession` | `{sessionId, stopActivity?}` | `{archivedSessionIds}` |
| `workspace/unarchiveSession` | `{sessionId}` | `{archivedSessionIds}` |
| `workspace/pinSession` | `{sessionId}` | `{pinnedSessionIds}`（最近置顶的在前） |
| `workspace/unpinSession` | `{sessionId}` | `{pinnedSessionIds}` |

`WorkspaceView = {workspaceId, path, title, sessionIds, createdAt, updatedAt}`（时间是 ISO 字符串）。

- 归档有运行中工作时拒绝，`workspace/session-active`，`details.activity` 列出要先停的东西；`stopActivity: true` 改为请求停止后归档（`types.d.ts:111-121`）。
- 归档会话的 Agent 不能再开始新 step（`ArchivedSessionGate`，README）。
- [live] `workspace/create {path:'/tmp/dshref/ws'}` 返回的 `path` 是解析后的 `/private/tmp/dshref/ws`。**用 `cwd` 创建的会话不会自动加入同目录的工作区**，`sessionIds` 仍为空；用 `session/create {request:{workspaceId}}` 创建的才会加入。

`workspace/follow`（流，`args: {}`）帧（`types.d.ts:143-170`）：

```ts
{ type:'baseline', value: { items: WorkspaceView[], archivedSessionIds, pinnedSessionIds } }
{ type:'upsert', workspace } | { type:'remove', workspaceId } | { type:'order', workspaceIds }
| { type:'archived', archivedSessionIds } | { type:'pinned', pinnedSessionIds }
```

[live] 置顶/归档/取消归档/取消置顶/重命名/在工作区里建会话，依次收到 `pinned`、`archived`、`archived`、`pinned`、`upsert`、`upsert`（sessionIds 增加新会话）。

---

## 7. 发送

### 7.1 `session/prompt`

```ts
request: { requestId: string, sessionId, mode: 'queue' | 'steer',
           content: PromptContentPart[], clientTimeZone?: string }
PromptContentPart = { type:'text', text }
                  | { type:'image', mediaType: 'image/png'|'image/jpeg'|'image/webp'|'image/gif', data: <base64>, name? }
                  | { type:'file', receiptId }
```

（`types.d.ts:78-89, 319-327`；实现 `lib/index.js:850-897`）

- 返回 `{accepted: true}`：表示消息进了 Agent inbox，不代表执行完。
- 内容必须有非空白文本或附件，否则 `gateway/bad-request`。[live]
- `clientTimeZone` 必须是 `UTC` 或合法的 IANA `Area/Location`，否则 `session/invalid-time-zone`。[live]
- `requestId` 写进持久用户消息的 `source.rpcId`（`source: {kind:'user', rpcId, clientTimeZone?}`，`types.d.ts:375-384`）。[live]
- 去重：相同 `requestId` 的请求如果在 inbox 里或已经有 `user/message`，直接返回 `{accepted:true}` 不重复插入（`hasPromptRequest`，`lib/index.js:1063-1076`）。**存在竞态窗口**：turn 开始时消息先从 inbox 移除（`agent/inbox/spliced removedCount:1`），稍后才写 `user/message`；这之间到达的重试检查不到，会插入第二条。[live] 立即重发同一 `requestId`，结果产生了两个 turn（seq 5 移除、seq 6 重复插入、seq 9 写出第一条）。
- 冷会话会被恢复（resume）。被别的进程持有写锁 → `session/writer-held`。
- 图片在服务端转成持久引用：`{type:'image', attachment:{attachmentId:'sha256:…', mediaType, width, height, bytes, name}}`。[live]
- 模型不支持图片输入 → `session/attachment-invalid`，`reason: MODEL_DOES_NOT_SUPPORT_IMAGES`。
- 图片限制在投影 `imageLimits` 里：[live] `{"maxImageBytes":20971520,"maxImagesPerMessage":20,"maxMessageImageBytes":209715200,"maxImagePixels":64000000,"maxImageDimension":8192,"mediaTypes":["image/png","image/jpeg","image/webp","image/gif"]}`。
- 原始字节读取：`session/attachment {sessionId, attachmentId}` → `{attachment, data: <base64>}`；只能读该会话日志引用过的图片（`lib/index.js:911-930`）。[live]

### 7.2 文件上传

两种方式，都返回 `FileUploadValue = {receiptId, file: {attachmentId, name, bytes}}`（`dsh-client-file-upload/lib/types/types.d.ts`）：

- 流式：`POST /api/session/uploadFileBinary?sessionId=<id>&name=<name>`，`Content-Type: application/octet-stream`，请求体是原始字节。响应不是 RPC 信封，是 `{ok, value}` 或 `{ok:false, error}` JSON（`dsh-client-file-upload/lib/index.js:13-56`）。[live] `{"ok":true,"value":{"receiptId":"e34ec813-…","file":{"attachmentId":"sha256:702b…","name":"note.txt","bytes":11}}}`
- 一元：`fileUploads/upload {agentId, request: {data: <base64>, name?}}`。[live]

然后在 prompt 里引用 `{type:'file', receiptId}`。receipt 只在同一会话（同一 Agent 实例）内有效；没上传过 → `session/attachment-invalid`，`reason: FILE_NOT_STAGED`。子代理会话不接受上传。持久化后的形状是 `{type:'file', attachment:{attachmentId, name, bytes}}`。[live]

### 7.3 排队、steer、取消

- `mode:'queue'`：进 `next-turn` 队列。`mode:'steer'`：进 `next-step`，插进当前 turn。
- 待处理消息在投影 `inbox`：`{'next-turn': UserMessage[], 'next-step': UserMessage[]}`，每条有 `id` 和 `source.rpcId`。
- `session/updateQueue {sessionId, itemId, action}`（`lib/index.js:937-993`），`action`（`types.d.ts:149-157`）：
  - `{kind:'edit', content: TextBlock[]}`：只能是非空文本。[live] **编辑会替换整条消息的 content，原来的文件附件会丢失**（实测把带文件的那条改成了纯文本）。
  - `{kind:'remove'}`
  - `{kind:'steer'}`：只对 `next-turn` 里的项、且 Agent 正在运行时可用，否则 `session/steer-unavailable`。
  - 找不到 → `session/queue-item-not-found`。
- `session/cancel {sessionId}` → `{accepted:true}`：取消当前 turn，保留 inbox（`lib/index.js:994-1000`）。会话没挂载 → `session/not-found`。[live] 结果：`tool/result` 带 `error:{name:'AbortError', code:'ABORTED'}`，`turn/end` 的 `reason` 为 `{kind:'aborted', reason:{kind:'user'}}`。空闲时取消也返回 `{accepted:true}`。

### 7.4 斜杠命令

`session/prompt` 不再解析斜杠命令（和 0.1 不同），命令走：

- `commands/list {agentId}` → `CommandDescriptor[]`：`{definitionId?, name, description, input?: {hint, attachments?}}`。[live] 标准预设下有 `compact`、`export`、`feedback`、`goal`、`permission`、`plan`。
- `commands/execute {agentId, line, submittedAttachments}`（`dsh-commands/lib/types/index.d.ts:142`）：
  - `line` 是完整命令行，如 `"/permission read-only"`。
  - `submittedAttachments: ({type:'image', mediaType, data, name?} | {type:'file', receiptId})[]`，没有就传 `[]`（`dsh-commands/lib/types/types.d.ts:13-18`）。命令没声明 `input.attachments: true` 时带附件会被拒。
  - 返回 `{commandId, result: {kind:'success', text?, sourceEventSeq?} | {kind:'error', text}}`。[live] `{"commandId":"cmd-f45f9484-1","result":{"kind":"success","text":"preset read-only"}}`
  - 命令名不存在或不是命令语法 → `{"ok":true}`，没有 value。[live]
  - 日志里出现 `command/run {commandId, name, args?, source}` 和 `command/done {commandId, kind, text?, sourceEventSeq?}`。[live]
- `commands/change` emit 通知命令目录变化。

### 7.5 技能

`skills/list {request:{sessionId}}` → `{skills: [{path?, name, description, whenToUse?, modelInvocable}]}`（`types.d.ts:241-260`）。冷会话也不会激活 Agent。[live] 测试实例返回 `{"skills":[]}`。

### 7.6 模型

- `session/modelCatalog {}` → `{default: {provider, model, reasoningEffort?}, routableProviders: string[], groups: [{id, name, models: [{id, name, description?, reasoning?: {efforts: [{id, name, description?}], defaultEffort?}}]}], failures: [{id, name, message}]}`（`types.d.ts:110-147`）。[live]
- `session/selectModel {sessionId, provider, model, reasoningEffort?}` → `{selected}`。必须是目录里可用的模型，否则 `session/model-unavailable`，`details: {provider, model}`。[live] 成功后日志写 `model/selection {provider, model, reasoningEffort?}`。[live] 默认值在后台保存，失败只记日志。
- 投影 `modelSelection: {lastUsed, next}`：`next` 是下一次请求会用的选择。[live]
- `session/initializeDefaultModel {}`：登录后无 API key 时选第一个账号模型。
- `llm/adapters-updated` emit 表示目录可能变了。

### 7.7 权限预设

- `permissionPresets/catalog {}` → [live] `{"options":[{"value":"read-only","name":"read-only"},{"value":"workspace-write","name":"workspace-write"},{"value":"danger-full-access","name":"danger-full-access"}],"defaultOptions":[…],"defaultPreset":"workspace-write"}`。
- 切换没有专门的 RPC，走命令 `commands/execute {line: "/permission <preset>"}`。[live] 日志依次是 `command/run`、`permission/preset {preset}`、`sandbox/mode {mode}`、`command/done`；投影 `permissions: {currentValue}` 更新。
- `danger-full-access` 会把 approval policy 设成 `never`，并在下一个 turn 注入一条 `source: {kind:'user-approval'}` 的说明消息。[live]
- `permission-presets/catalog-changed` emit 通知目录变化。

### 7.8 其他

- `session/create {request: {cwd?, workspaceId?, sessionId?, agentPreset?}}` → `{sessionId, agentPreset?}`。[live] `{"sessionId":"session-522162a9-…","agentPreset":"standard"}`
- `session/fork {sessionId, atSeq?}` → `{sessionId}`。[live]
- `agentPresets/list {}` → [live] `{"presets":[{"id":"standard","order":1,"isDefault":true},{"id":"ptc",…},{"id":"minimal",…},{"id":"cordis",…}]}`。
- `session/search {request:{query}}`：Web profile 默认关闭全文检索，返回 `gateway/internal` "session search is disabled …"。[live]

---

## 8. 会话日志事件类型（渲染器要用的）

### 8.1 通用信封（`SessionWireEvent`，`types.d.ts:432-442`）

```ts
{ type: string, seq: number, time: number /* ms */, data: JSON,
  ignorable?: true, sourceEventSeqs?: number[], surfaceOp?: 'append' | {op:'replace', startSeq, endSeq} }
```

- `surfaceOp` 只出现在"可见面"事件上：`user/message`、`assistant/message`、`tool/result`、`system/message` 等。`append` 是追加；`replace` 替换之前的一段。
- `sourceEventSeqs`：`tool/result` 指向对应 `tool/call` 的 seq。[live] `"sourceEventSeqs":[16]`。
- 事件类型可扩展，渲染器必须容忍未知类型。

### 8.2 核心事件（`dsh-session/lib/types/types.d.ts:255+`，`dsh-agent/lib/types/types.d.ts:80-95`）

| type | data | 备注 |
|---|---|---|
| `turn/start` | `{turn}` | |
| `turn/end` | `{turn, reason}` | `reason.kind`：`completed`、`aborted {reason: {kind:'user'…}}`、`blocked`、`error {error}`、`max-tokens`、`interrupted`、`forked`（`types.d.ts:165-210`） |
| `step/start` / `step/end` | `{turn, step}` | |
| `user/message` | `UserMessage {role:'user', id, content, source}` | `source.kind`：`user`（带 `rpcId`）、`runtime-context`（运行时上下文快照，通常不展示）、`user-approval`、`user-question-reply`、目标轮次等 |
| `system/message` | `{turn, step, message}` | 系统提示，不展示 |
| `developer/message` | `{turn, step, message, headerSeq?}` | |
| `assistant/message` | `{turn, step, message: {role:'assistant', id, content, source}, stream, usage?, interrupted?}` | `content` 块：`text`、`reasoning`、`tool-call {id, name, arguments}`；中途取消时 `interrupted: true` |
| `assistant/attempt` | `{turn, step, stream}` | 没有提交成消息的尝试（失败、重试、取消、流错误） |
| `tool/call` | `{turn, step, callId, name, arguments: string}` | `arguments` 是未解析的 JSON 字符串 |
| `tool/result` | `{turn, step, message: {role:'tool', toolCallId, content, isError, id, source}, error?: {name, code, reason?}, meta?}` | `meta` 由工具定义，例如写文件 `{"operation":"create","diffs":[]}`[live] |
| `request/header` / `request/context` | 请求元数据 | 只用于日志，不展示 |
| `agent/inbox/spliced` | `{target:'next-turn'|'next-step', start, removedCount?, inserted: UserMessage[], outcome?:'canceled'}` | inbox 变化 |

`stream` 是紧凑格式（`dsh-llm/lib/types/assistant-stream.d.ts:16-40`）：

```ts
{ type:'text-chunks'|'reasoning-chunks', time0, index, dt: number[], texts: string[] }
{ type:'tool-call-chunks', time0, index, dt: number[], id, name?, args: string[] }
{ type:'chunk', time, chunk: StreamChunk }   // block-start / block-end / usage / finish
```

`dt` 是相邻片段的时间差（ms）。渲染最终内容直接用 `message.content`，`stream` 只在需要时间信息或回放时用。

[live] `tool/call` + `tool/result`（失败）：

```json
{"type":"tool/call","seq":48,…,"data":{"turn":3,"step":2,"callId":"call_00_oi48…","name":"read","arguments":"{\"file_path\":\"/tmp/dshref/ws/nonexistent.txt\"}"}}
{"type":"tool/result","seq":49,…,"data":{"turn":3,"step":2,"message":{"role":"tool","source":{"kind":"tool","callId":"call_00_oi48…"},"toolCallId":"call_00_oi48…","content":[{"type":"text","text":"Error: cannot read \"/tmp/dshref/ws/nonexistent.txt\": not found"}],"isError":true,"id":"2258…"},"error":{"name":"FsError","code":"FS_NOT_FOUND"}},"sourceEventSeqs":[48],"surfaceOp":"append"}
```

注意：0.1 里 host 为 tool 帧计算的 `view`（generic/terminal/diff）在 0.2 的 follow/page 里**没有了**。README 原文："the controller does not resolve a Tool definition, run a presenter, or attach UI data."

### 8.3 扩展事件

| type | data | 出处 / 实测 |
|---|---|---|
| `todo/write` | `{todos: [{content, status}]}` | `dsh-tool-todo/lib/types/types.d.ts:27`；[live] `{"todos":[{"content":"alpha","status":"in_progress"},{"content":"beta","status":"pending"}]}`，紧跟在 `tool/call` 之后、`tool/result` 之前 |
| `approval/asked` / `approval/decided` | 见 §5.2 | [live] |
| `approval/policy` | `{policy:'ask'|'never', source?:'delegation'}` | `dsh-user-approval/lib/types/index.d.ts:25-37` |
| `permission/preset` | `{preset}` | [live] |
| `sandbox/mode` | `{mode, source?}` | [live] |
| `command/run` / `command/done` | 见 §7.4 | `dsh-commands/lib/types/types.d.ts:90+`；[live] |
| `subagent/catalog` | `{version, childId, childCreatedAt, mode:'one-shot'|'continuable', label}` | 父会话日志；`dsh-subagent/lib/types/catalog.d.ts:32`；[live] `{"version":0,"childId":"3c0e4ed8-…","childCreatedAt":1791022734033,"mode":"one-shot","label":"pong probe"}` |
| `subagent/descriptor` | `{version, mode, provider, label}` | 子会话日志；`dsh-subagent/lib/types/descriptor.d.ts:27`；[live] `{"version":3,"mode":"one-shot","provider":"spawn","label":"pong probe"}` |
| `deliverables/presented` | `{turn, callId, files: [{path, description?}]}` | `dsh-tool-present/lib/types/types.d.ts:11`；[live] |
| `workspace/changes` | `{turn}` | 只有 turn，详情要用 `GET /api/changes.summary?sessionId=&seq=<该事件 seq>` 取（§2.4）；`dsh-workspace-changes/lib/types/types.d.ts:104`；[live] 在 turn 的最后、`turn/end` 之前 |
| `compaction/start` | `{compactionId, sourceCommandId?, turn}` | `dsh-compaction/lib/types/types.d.ts:15+`；[live] |
| `compaction/summary` | `{compactionId, summary: ContentBlock[], shadowedRange:{start,end}, shadowedSeqs, shadowedTokenCount, provider, model, …}` | 同上（实测压缩失败，没有拿到这条） |
| `compaction/end` | `{compactionId, sourceCommandId?, turn, error?}` | [live] `"error":"summary is not smaller than the shadowed content (744 estimated framed tokens >= 604)"` |
| `compaction/prune` | `{shadowedRange, shadowedSeqs, shadowedTokenCount}` | 同上 |
| `session/title` | 见 §6.2 | [live] |
| `model/selection` | `{provider, model, reasoningEffort?}` | [live] |
| `plan/mode` | `{active}` | `dsh-plan-mode/lib/types/index.d.ts:38` |
| `goal/change` | `GoalChangeMeta` | `dsh-goal/lib/types/domain.d.ts:47` |
| `llm/retry` / `llm/retry-started` | `LlmRetryEventData` | `dsh-llm-retry/lib/types/types.d.ts:5` |
| `hook/invoked` / `hook/result` | | `dsh-hook-protocol/lib/types/types.d.ts:8` |

0.2 全部事件名清单见 `/tmp/dsh02.dfd2/ev02.txt`（48 个扩展事件名，不含 `dsh-session` 的核心事件）。

子代理会话的日志用 subagent 地址读：`session/page {address:{kind:'subagent', parentSessionId, childSessionId, mode:'unknown'}, throughSeq}`。[live] 读到了子会话的 `sandbox/mode (source:delegation)`、`subagent/descriptor`、`user/message`、`assistant/message` 等。父会话的投影 `subagentCatalog` 列出子代理：[live] `[{"mode":"one-shot","label":"pong probe","id":"3c0e4ed8-…","createdAt":1791022734033}]`。

---

## 9. 版本识别

按代价从低到高：

| 探测 | 0.2.0-rc.2 | 0.1.x |
|---|---|---|
| 无 cookie `POST /api/session.list`（0.1 的方法名） | **401**，正文 `unauthorized` [live] | 200 + `server-response`（依据 `docs/dsh-api-inventory.md`，0.1 无认证；未实测） |
| 无 cookie `GET /` | **401** `text/plain`，`dsh web authentication required; reopen the URL printed by dsh web.` [live] | 200 HTML（依据同上，未实测） |
| 有 cookie `POST /api/session.list` | 404 `not found` [live] | — |
| 有 cookie `POST /api/session/list`（`args:{_request:{}}`） | 200 [live] | 0.1 没有这个两段式 session 方法（0.1 的 typert 端点只有 goals/messageFeedback/pluginInventory/cordisRunner） |
| WebSocket 路径 | `/api/remote.mux`；`/api/events.mux` 普通 GET 返回 404 [live] | `/api/events.mux` 普通 GET 返回 426 |
| 精确版本 | `pluginManager/listBundles {}` → 其中 `@deepseek-ai/dsh-base` 的 `version: "0.2.0-rc.2"` [live] | — |
| CLI | `dsh --version`（`lib/bin.js:105`） | 同 |

注意 `/api/session.export` 在两个版本里路径相同（0.2 实测 200 zip），不能用来区分。

推荐的最小判定：先无 cookie 打一个 `POST /api/session.list`。401 → 0.2+；200 → 0.1。

---

## 10. 和 Bridle 现状相关的其他事实

- **0.2 首次启动会迁移 `$DSH_HOME/settings.yaml`**：重命名为 `settings.yaml.imported`，把各节合并进当前 profile 的 `profiles/<profile>/cordis.patch.yml`（`dsh-settings/lib/index.js:339-361`）。[live] 一次性实例里 `settings.yaml` 变成 `settings.yaml.imported`，`profiles/web/cordis.patch.yml` 从 4 行变成 505 行，原有的 `webserver` 块保留在文件顶部。Bridle 如果读 `~/.dsh/settings.yaml`，升级后会读不到；`dshHomeUrl()` 解析 `webserver` 块的逻辑实测仍然有效。
- `ensureDsh` 当前用 `stdio: 'ignore'` 启动 dsh（`bridle/src/dsh/discovery.ts:180`），0.2 上拿不到 token（§1.7 b）。
- `DshClient` 当前调用 `/api/respond`、`events.mux`、`events.host`、`session.history`（`bridle/src/dsh/client.ts`、`bridle/src/tunnel/*`），这些在 0.2 全部不存在。
- 每次连接一代 `$events` 就是一个新的 `clientId`；回答 waterfall 时必须用**收到该 waterfall 的那一代**的 `clientId`（或任意仍在持有它的活动 clientId）。

---

## 11. 开放问题

1. **已运行的用户 dsh 如何拿 token**：没有官方途径（§1.7）。需要产品决策：要求用户粘贴一次 URL 后长期保存 cookie、装 Bridle 插件，还是读 `.credentials.yaml` 自签（非官方，格式可能变）。
2. **Desktop app**：Electron 壳如何把凭证交给页面、端口如何发现、是否打印 token，本包里没有，未实测（§1.8）。
3. **prompt 去重的竞态**：`requestId` 在 inbox 移除和 `user/message` 写入之间的重试会产生重复消息（§7.1，已实测复现）。弱网重试策略需要考虑这一点。
4. **子代理会话里的审批**：waterfall 的 `agentId` 对子代理是什么、能否被 UI 回答，未实测。`ask_user_question` 明确只允许运行时根 agent 提问（`assertLiveRoot`，`dsh-user-questions/lib/index.js:531-535`）。
5. **timed 问题模式**（`attachWait`、`ASK_TIMED_OUT`、`userQuestions/answer`）只有源码阅读，未实测（默认关闭）。
6. **`compaction/summary`、`assistant/attempt`、`turn/end` 的 `error`/`max-tokens`/`interrupted` 形状**只来自类型声明，未在实测中出现。
7. **重连时保留旧窗口只补缺口**的做法是由 page 语义推出的，官方客户端是整体替换窗口（§4.4），未实测。
8. **follow 的服务端缓冲**：服务端在快照之后用内存队列缓冲所有事件（`lib/index.js:1464-1481`），慢客户端不会丢事件但没有上限说明；长时间不读的影响未测。
9. **`api-session/added` 重复发送、`status` 与 follow 事件的相对顺序**只是观察结果，不是协议保证（§6.3）。
10. **0.1 侧的探测结果**（§9 表格的 0.1 列）没有实测，因为不允许碰用户在 3080 上运行的 dsh。
