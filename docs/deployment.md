# 部署

**两个域名，故意分开的**：

| 域名 | 是什么 |
|---|---|
| `rowel-relay.novabox.ai` | Relay。app 和 Bridle 拨的就是这个，别的什么都没有 |
| `rowel.novabox.ai` | 官网四个页面 + `/install` 重定向。**不承载任何中继路径** |
| `rowel-relay-standby.novabox.ai` | Node relay 的常驻备用地址，见 §1.6 |

它们共用过一天同一个域名，那是个错误：站点是公开营销页，Relay 是基础设施，而 Cloudflare 的每一项控制（缓存规则、WAF 规则、"我正被攻击"开关）都是**按主机名生效的**。一条冲着页面去的规则会连 Relay 一起命中，而 Relay 是不能挂的那一半。共用还意味着任一侧的 Worker 写出 `/*` 路由就能把另一侧整个吞掉。

`e2e/tests/site.test.js` 有一条专门盯这个：站点域名上的 `/healthz`、`/v1/*` 必须是 404。

`novabox.ai` 现状（2026-08-15 查）：

| 项 | 值 |
|---|---|
| 注册商 | GoDaddy |
| DNS | Cloudflare（`cameron.ns.cloudflare.com` / `mina.ns.cloudflare.com`） |
| 邮件 | Cloudflare Email Routing |
| 根域 | 没有 A 记录，没在跑网站 |
| 已用子域 | 没有（www / api / app / relay / docs 全空） |
| 到期 | 2026-10-07 |

三样东西要上线：Relay、DNS 记录、iOS app。**前两样已经上线**（2026-08-15），第三样卡在 Apple 那边。

## 当前生产部署

| 项 | 值 |
|---|---|
| 主机 | 阿里云北京，Ubuntu 26.04，2 核 / 1.5 GB |
| Relay | systemd `rowel-relay`，监听 `127.0.0.1:8787`，**不开公网端口** |
| 源码路径 | `/opt/rowel`，`root:root` 只读，服务账号 `rowel`（nologin） |
| 入口 | Cloudflare Tunnel `rowel-relay`，systemd `cloudflared` |
| 隧道配置 | `/etc/cloudflared/config.yml`（本地管理，不是面板管理） |
| `rowel-relay.novabox.ai` | Cloudflare Worker `rowel-relay`（custom domain），Durable Objects |
| `rowel-relay-standby.novabox.ai` | 北京那台的 Node relay，经隧道 |
| `rowel.novabox.ai` | Worker `rowel-site`（静态资源，无源站）+ `/install` 重定向规则 |

站点那个域名按路径分：

| 路径 | 谁在服务 | 为什么 |
|---|---|---|
| `/`、`/get`、`/help`、`/privacy` | Worker 静态资源，跑在边缘 | 无源站。Relay 挂了隐私页不能跟着挂，App Store 审核会去拉那个链接 |
| `/_/*` | 同上 | 站点自己的静态资源。加 favicon 时不用再加一条路由 |
| `/install` | Cloudflare 重定向规则 → GitHub raw | 中继和安装链路必须是两个信任域 |

**站点 Worker 的路由绝不能写成 `/*`**。虽然 Relay 已经搬走了，`/install` 那条重定向规则仍在这个域名上，一个通配路由会把它吞掉，而四个页面依然返回 200 —— 看起来一切正常。

验证方式是 `e2e/tests/deployed.test.js`，它打的是真实公网地址而不是进程内的 Relay：

```sh
ROWEL_E2E_RELAY_URL=wss://rowel-relay.novabox.ai npm run build && \
  node --test e2e/tests/deployed.test.js

# 或者两套 Relay 一起验，确认随时可切：
npm run conformance:deployed
```

没有这个环境变量它会跳过。**别把它从 CI 里删掉再指望别的测试能替代它**——其余 e2e 全跑在 loopback 上，隧道拒绝 WebSocket 升级、代理把流缓冲成没用、容量上限设错，这几种它们一个都发现不了。

---

## 1. Relay

Relay **没有持久内容，但有连接撮合状态**。它不存数据库、不存明文、没有配置文件，全部配置来自环境变量——但设备、线路、待领短码都在进程内存里（`registry.ts` / `offers.ts`）。

这个区别在部署时是全部：**进程退出会断掉每一条在线连接，并丢掉所有待领短码。**

### 跑起来

```sh
npm install
npm run build
PORT=8787 node relay/lib/main.js
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8787` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `ROWEL_INSTALL_SCRIPT` | 仓库里的 `install.sh` | `/install` 返回哪个文件；设成空字符串就关掉这个路由 |

### 路由

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/healthz` | 健康检查，给负载均衡用 |
| `GET` | `/install` | 安装脚本，**默认关闭**，仅自托管时可开 |
| `GET` | `/v1/machine/<deviceId>` | 这台机器现在在不在线 |
| `POST` | `/v1/pair/offer` | Bridle 挂一个短码邀请 |
| `GET` | `/v1/pair/claim?code=…` | app 用短码换配对载荷 |
| `WS` | `/v1/bridle` | Bridle 的常连 |
| `WS` | `/v1/app` | app 的连接 |

`/install` 这条路由**默认关闭**（`ROWEL_INSTALL_SCRIPT=` 空字符串）。

它存在是给自托管的人用的——自己跑一套时，一个域名一次部署确实省事。但**官方部署不开它**：把安装脚本和公网中继放在同一个部署单元，等于把一次中继入侵放大成对所有新用户的供应链投毒。官方的安装脚本从仓库直接取（§2）。

### 前面要放 TLS

Relay 自己不做 TLS。放在 Caddy / nginx / 云厂商的 LB 后面，证书交给它们。

Caddy 够用，两行：

```
rowel.novabox.ai {
	reverse_proxy 127.0.0.1:8787
}
```

WebSocket 不用额外配置，Caddy 默认透传 upgrade。

### 走 Cloudflare（novabox.ai 已经在上面）

DNS 在 Cloudflare，所以最省事的两条路：

**A. 有公网机器** —— A 记录 `rowel` 指向那台机器，橙云（proxied）打开。Cloudflare 的代理支持 WebSocket，不用额外开关。源站上放 Caddy 或者直接让 Cloudflare 回源到 8787。

**B. Cloudflare Tunnel** —— 现在用的就是这条。理由见下面的备案一节；简单说是：这台机器在中国大陆，备案这条路对 `.ai` 是死的，隧道让执法链条够不着。**注意这是"够不着"，不是"不适用"**——早先这里写的是"不监听公网端口就不构成对外提供服务"，那句话是错的。

```sh
cloudflared tunnel login                      # 浏览器授权，写出 ~/.cloudflared/cert.pem
cloudflared tunnel create rowel-relay
cloudflared tunnel route dns rowel-relay rowel.novabox.ai
sudo cloudflared service install              # 读 /etc/cloudflared/config.yml
```

`config.yml` 里配 ingress（`rowel.novabox.ai` → `http://127.0.0.1:8787`，兜底 `http_status:404`）。

**为什么用本地管理的隧道而不是面板管理的**：面板管理需要写 `PUT /accounts/*/cfd_tunnel/*/configurations`，而 Cloudflare 的 WAF 会拦掉从 dashboard 会话发出的程序化写请求（403 + "Attention Required" 页面），Zero Trust 那套 UI 又要先走 onboarding。`cloudflared tunnel login` 拿到的 `cert.pem` 直接带 DNS 写权限，一条命令建记录，绕开这两处。配置在 `/etc/cloudflared/config.yml` 里也更容易和仓库对上。

两条路都要注意的：

- **心跳 25 秒**，比 Cloudflare 的 WebSocket 空闲超时（100 秒）短得多，连接不会被中途掐掉。
- **单帧上限 32 MiB**，且这不是本机的选择——它是路径上最小的那个天花板（Cloudflare Worker 接收消息的硬限制）。Node relay 本可以更大，但一个 Bridle 不应该因为拨到哪个 relay 而表现不同。
- **超限的表现是断链，不是报错**。每一层 WebSocket 都用 1009 关掉整条连接来执行这个限制，没有可捕获的单请求失败。没有防护的话，结果是隧道掉线→重连→resume→重发同一个大帧→再掉，无限循环，而且哪一层都说不出原因。两层防护：
  1. **`session.history` 自动缩页**。页是按*消息数*分的，而 dsh 明确每页是一段连续的原始事件区间——所以一条消息可以跨几万个 `assistant/chunk`，页的字节数没有上限（实测 25 条消息 = 22 MB）。Bridle 发现瘦身后仍然超限时，把 `maxMessages` 减半重问，直到装得下。这不是绕路，小页正是 `maxMessages` 的用途，调用方本来就会跟着 `hasMore` 继续翻。
  2. **写之前量一次**（`MAX_FRAME_BYTES`），作为兜底。没有分页参数的方法（`session.export` 完全无分页、`session.list` 返回多少是多少）只能走这条：那一个请求答成 `too-large`，隧道不动。
- **不要开 Cloudflare 的缓存规则去缓存 `/v1/*`**。短码是一次性的，缓存住等于把它变成可重放的。`/install` 那条已经自己带了 `max-age=300`。

### 内建的限制

这些是硬编码的，不是配置项——它们是协议的一部分，调松了会让滥用变便宜：

| 限制 | 值 | 为什么 |
|---|---|---|
| 单帧最大 | 32 MiB | 路径上最小的天花板。附件走 base64 涨 4/3，所以原始文件约 24 MiB 以内安全 |
| 注册超时 | 15 秒 | Bridle 连上后必须在这个时间内签名证明身份 |
| 心跳 | 25 秒 | 比常见的 60 秒空闲超时短，穿得过大多数中间设备 |
| 每台机器的并发线路 | 8 | 一个人的几部设备够用，僵尸线路堆不起来 |
| 每设备待领短码 | 3 | 反复 `bridle pair` 不会把短码空间填满 |
| 短码有效期上限 | 15 分钟 | Bridle 请求更长也会被砍到这个值 |

全局上限是**容量而非协议**，所以可配，默认保守：

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `ROWEL_MAX_MACHINES` | 1000 | 机器身份就是一对密钥，谁都能造一万个。没有全局上限，这个免费中继就是别人出钱的通用加密转发器 |
| `ROWEL_MAX_CIRCUITS` | 4000 | 很多机器各开几条时的内存兜底 |

按每连接约 40 KB 估：1000 台机器 + 4000 条线路 ≈ 200 MB，一台 1 GB 的小机器扛得住。**机器更大就往上调，不要留着默认值假装容量更大。**

全局上限是**硬拒绝**而不是软降级：降级的中继让所有人一起变慢，拒绝一台只让一台失败。已连接的机器重连**不受**上限影响——把正在用的人挤掉是错的那一半。

另有按调用方的令牌桶限流（允许一个突发，然后必须等）。

### 容量

一条线路 = 两个 WebSocket + 一个转发循环，没有解析、没有落盘。瓶颈是文件描述符和带宽，不是 CPU。单进程扛几千条线路没问题。

### 升级：排空，不要重启

单实例阶段用双进程切换：

1. 新进程起在另一个端口，`/healthz` 通过
2. 旧进程停止接受新线路（关掉它的 upgrade 处理）
3. 等已有线路自然结束，或到超时上限
4. 切流量，关旧进程

客户端会自动重连并 `resume{since}` 补齐缺口——但**待领短码不会迁移**，升级窗口内正在配对的人要重新拿一个码。这是可接受的，只要升级不在高峰。

**不做这个的后果**：每次部署都在制造这个品类抱怨最多的那件事（重连丢东西）。

### 横向扩展：现在做不到，原因要说清楚

Relay 按 deviceId 在**进程内存**里撮合两条 socket，app 和 Bridle 必须落到同一个进程。

早期文档建议"按 deviceId 做一致性哈希的 L4 分流"。**那行不通**：Bridle 建连时 URL 里没有 deviceId，它在 WebSocket 建立**之后**的注册消息里，四层负载均衡在建连时拿不到。

要真的多实例，得二选一：

- **把路由键放进建连请求**（URL 查询参数或子域名），代理据此分流，Bridle 随后再用签名证明这个键确实是它的
- **共享设备目录**（Redis 之类），实例间转发

两者都是真实工作量。**在有真实负载之前，跑一个实例并把排空做对，比提前分片更诚实。**

### 它拿不到什么

Relay 看不到明文、看不到你的 dsh 地址、看不到会话内容。它知道的全部是：哪个 deviceId 在线、谁连了谁、搬了多少字节。

这不是承诺，是结构上做不到——加密在 Bridle 和 app 之间，Relay 只有密文。`e2e/tests/security.test.js` 里的 `the relay only ever sees ciphertext` 盯着这一条。

---

## 1.5 ICP 备案：现状是"违规但够不着"，不是"不适用"

这一节存在的原因是**上一版文档在这里写错了**，而错的方式很典型：把云厂商帮助文档的口径当成了法规口径。留着这段，是因为下一个人多半会犯同一个错。

### 法条怎么说

《非经营性互联网信息服务备案管理办法》（信产部令 33 号）第五条的触发要件是：

> **在中华人民共和国境内的组织或个人**，利用通过互联网域名访问的网站……提供非经营性互联网信息服务

要件是**境内主体 + 域名可访问的网站 + 提供信息服务**。条文里**没有"服务器在境内"这几个字**。域名在境内主体名下、站点公网可达，字面上就落进去了——机器监听哪个地址不改变这一点。

阿里云帮助文档里那句"域名解析至中国内地服务器并开通 Web 访问"是**云厂商自己的判定口径**，用来决定它要不要替你阻断，不是法规的构成要件。把两者当成一回事是上一版的错误。

### 为什么 `.ai` 让备案变成不可能

不是"麻烦"，是路径根本不存在：

- `.ai` 不在工信部批复的可备案顶级域清单里（工信部「中国互联网域名体系」只列 CN 体系；阿里云核验要求附录也不含 `.ai`）
- 依据是工信部信管〔2017〕264 号：2018-01-01 起新增备案的顶级域必须经批复
- 另一道锁：注册商也须是工信部批复机构，GoDaddy 不在列

### 为什么现在没事

备案的强制执行靠**境内接入服务提供者代为核查与阻断**（264 号文），而阻断作用在**入站** HTTP Host / TLS SNI 上。这套机制看不见当前架构：域名解析到 Cloudflare 的 Anycast IP，阿里云侧只有一条出站加密长连接，没有入站 80/443，没有 Host 可查。

调研没有找到任何一手案例是"因跑 cloudflared 出站隧道被阿里云关停"。找到的关停案例都是：违规内容、挖矿、未备案域名解析到内地 IP 且走 80/443。

### 真实风险在别处

按严重度排：

1. **中国区 App Store 上架强校验 ICP 备案号**（苹果 2023-09 起；2024-04 起还校验 App 名称与工信部记录一致）。`.ai` 无法备案 ⇒ **这个域名下的产品上不了中国区**。

   换个可备案域名是必要条件，不是充分条件。备案是**通过境内接入服务商**办理的，所以中国区版本要凑齐三样：可备案域名（`.com` / `.cn`，注册商也须在工信部批复名单里）、境内备案主体、以及**跑在境内服务器上的服务**——最后这条意味着不能指向境外 Relay。再加上 App 备案。

   所以中国区不是"改个域名指向"，是**另一套部署**：境内 Relay + 另一个域名 + 独立备案。好在它和现在这套不冲突——Bridle 和 app 代码不变，变的只是 app 里那一个 relay 地址（`ios/Rowel/Net/RelayDirectory.swift` 的 `defaultRelayURL`，以及 `bridle/src/identity.ts` 的 `DEFAULT_RELAY_URL`）。真要做的时候按 §1.5 这一节重新评估一遍，不要照抄现在这套的结论。
2. **被动牵连停机**：他人把未备案域名解析到这台 ECS 的公网 IP，触发平台巡检直接停机。跟我们怎么部署无关，纯看运气，有真实案例。
3. **配合调查时无法自证**：一台境内机器跑端到端加密中继、拿不出明文、没有日志。真被问到时，解释成本远高于备案本身。
4. 备案罚则本身（33 号令：责令改正 + 1 万元罚款）——需要管局立案，常规入口是接入商转达，而那条链断了。

### 决定（2026-08-15）

**维持现状**，明确接受上述灰色状态。评估过的替代方案：

| 方案 | 边际成本 | 状态 |
|---|---|---|
| 现状：北京 ECS + CF Tunnel | ¥0（机器已存在） | **采用** |
| 境外 VPS（香港/新加坡） | ¥24/月起 | 未采用。合规干净，且中国用户少一跳折返 |
| Cloudflare Workers + Durable Objects，无源站 | ¥0（免费版：10 万请求/天、13,000 GB-s/天；入站 WS 消息 20:1 折算；休眠连接不计时长） | 未采用。免费额度对个人量级绰绰有余，但 Relay 要按 Hibernation API 重写，绑死 Cloudflare。单帧上限本来就已经按它的 32 MiB 对齐了，所以这一条不再是迁移的代价 |
| 老实备案 | — | 不可行，`.ai` 出局 |

**扩大规模前重新评估这一节。**上面的风险评估建立在"个人、小流量、不公开推广"之上；有真实用户之后每一条的概率都变。

---

## 2. DNS

已经加好了，`cloudflared tunnel route dns` 建的：

| 类型 | 名称 | 内容 | 代理 |
|---|---|---|---|
| `CNAME` | `rowel` | `a553d87c-715d-4045-9e2d-012ee543c96c.cfargotunnel.com` | 橙云开 |

自己重建的话不用手动填，跑 `cloudflared tunnel route dns <隧道名> rowel.novabox.ai`。

验证：

```sh
dig +short rowel.novabox.ai
curl -fsSL https://rowel.novabox.ai/healthz
```

`dig` 出来了但 `curl` 说解析不了，是本机解析器缓存了刚才那次 NXDOMAIN（SOA 的 negative TTL 是 1800 秒）。macOS 上 `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`。

### 安装脚本挂哪

**不挂在 Relay 上**（见 §1）。仓库转公开后直接从 GitHub 取：

```sh
curl -fsSL https://raw.githubusercontent.com/0x5446/rowel/main/install.sh | sh
```

短地址已经配好了，是一条 Cloudflare **Redirect Rule**（不是 Worker，不用写代码）：

```
rowel.novabox.ai/install  →  302  https://raw.githubusercontent.com/0x5446/rowel/main/install.sh
```

这样 app 里那行 `curl -fsSL https://rowel.novabox.ai/install | sh` 仍然成立，但中继被攻破**不会**污染安装链路——两者是不同的信任域。

重定向本身现在就生效，但跟过去是 404：仓库还是私有的。**仓库转公开的那一刻它自己就通了**，不需要再动 Cloudflare。

指向 `main` 而不是某个 tag，是有意的：这一层是引导脚本，永远取最新；`install.sh` 内部再用 `ROWEL_REF` 把真正 checkout 的源码钉到发布 tag 上。两层分开，改发布版本不用动 Cloudflare 规则。

### 转公开之前必须做完的

仓库一旦公开，提交历史收不回来。这几条是不可绕过的：

- [ ] **全历史秘密扫描**（`gitleaks detect --no-git` 与 `--log-opts=--all` 各一遍）
- [ ] **打 tag**：`install.sh` 默认 checkout `ROWEL_REF`（现在是 `v0.1.0`）。这个 tag 不存在的话，安装脚本会在 `git clone --branch` 那步失败——私有期间没人跑得到，公开的第一分钟就有人跑得到
- [x] LICENSE 就位（MIT）
- [x] 包元数据不再是 `UNLICENSED` / `private`
- [ ] 依赖许可证核对（`npm ls --all` 里没有 GPL 传染项）
- [ ] `/privacy` 页面已写：Relay 能观测到在线状态、连接关系、流量计数；推送落地后还会知道 device token 与机器的关联
- [ ] 至少两名发布维护者，或明确写出当前是单人维护及其后果

### 私有仓库期间的注意

安装脚本本身能从 Relay 拿到，但它里面 `git clone` 的是私有仓库——没有 GitHub 访问权的人跑到那一步会失败，脚本会明确说是私有仓库并给出手动 clone 命令。要真正对外，仓库得转公开，或者改成从发布产物安装。

脚本是幂等的（重跑是更新不是重装），装完把 `bridle` 链接到 `~/.local/bin`。app 里那行命令要改的话，改 `ios/Rowel/App/Links.swift` 一处。

---

## 3. iOS app

### 上真机 / TestFlight

签名已开。bundle id 是 `ai.novabox.rowel`，team 从环境变量来：

```sh
ROWEL_TEAM_ID=<你的 Team ID> xcodegen generate
```

**免费个人 team 与付费的区别，是整个发布计划的分水岭：**

| | 免费个人 team | 付费 Developer Program（$99/年） |
|---|---|---|
| 装到自己设备 | ✓ | ✓ |
| profile 有效期 | **7 天**，过期即闪退 | 1 年 |
| TestFlight | ✗ | ✓ |
| 推送（`aps-environment`） | ✗ 后台 Keys 页面也不开放 | ✓ |
| 上架 | ✗ | ✓ |

**一个决策卡三件事**：TestFlight、推送、上架的共同前置都是这 $99。

付费会员**可能是另一个 team，也可能就是原来那个**，取决于用哪个 Apple ID 入会。本仓库这个账号属于后者：会员 2026-08-19 激活后 team id **没有变**，`AVKUVD4FPN` 同时是付费 team 和个人 team。（2026-09-21 实测更正：本段原先写死「付费会员是另一个 team……`AVKUVD4FPN` 就是它（免费那个）」，与本账号事实相反。）

`ROWEL_TEAM_ID` 要填哪个，用下面三条**事实**核对，别照抄任何一段文字：

- **Store 分发 profile 的 `application-identifier` 前缀就是 team id**：本机 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 里那份 `iOS Team Store Provisioning Profile: ai.novabox.rowel` 写的是 `AVKUVD4FPN.ai.novabox.rowel`——**免费 team 发不出 Store 分发 profile**，所以这个 id 是付费的；
- `xcodebuild archive` 出来的归档：`codesign -dv --verbose=2 <…>/Rowel.app` 里的 `TeamIdentifier`；
- developer.apple.com → Account → **Membership details** 上的 Team ID。

只有当你用**另一个 Apple ID** 入会（那种情况下确实是另一个 team），`ROWEL_TEAM_ID` 才要换成新的 10 位 id；填错的症状是**一路签到导出才报错**。

### 用 API key 发布，不要用 Xcode 登录

`ios/release.sh` 做归档、导出、校验、上传，认证走 App Store Connect API key：

```sh
ROWEL_TEAM_ID=<付费 team id> \
ASC_KEY_ID=<key id> ASC_ISSUER_ID=<issuer id> \
ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_<key id>.p8 \
ios/release.sh
```

key 在 App Store Connect → Users and Access → Integrations 生成，`.p8` **只能下载一次**。选 API key 而不是在 Xcode 里登 Apple ID，是因为 key 不需要有人在键盘前回双因素验证码，重装机器也不失效，还能单独吊销。

**这把 key 的权限要 Admin，App Manager 不够。** 归档之后的导出（`xcodebuild -exportArchive`）要能通过云签名（cloud signing）建出分发证书，用 App Manager 的 key 会停在这里：

```
error: exportArchive Cloud signing permission error
error: exportArchive No signing certificate "iOS Distribution" found
```

（2026-09-21 实测：同一个团队、同一台从未登录过 Xcode 的机器、同一个归档，`rowel-release`（App Manager）失败，换成 `rowel-release-admin`（Admin）立刻 `EXPORT SUCCEEDED`。所以"App Manager 就够"只对**上传与提交**成立，对**导出**不成立。）

**`--no-upload` 只能验到一半，别把它当"没问题的证明"。** 这个模式按设计**不传 key**，于是在本机没有分发证书时会直接 `error: exportArchive No Accounts`——它跳过的恰恰是最容易出问题的那一步。它能证明的是：Release 配置能归档、`DEVELOPMENT_TEAM` 认得这个 team、构建号戳记与 `git rev-list --count HEAD` 一致。上传前真正的校验是脚本里那道 `altool --validate-app`（成功时日志里是 `VERIFY SUCCEEDED`）。

判断成败也要看日志标记（`** ARCHIVE SUCCEEDED **` / `** EXPORT FAILED **` / `VERIFY SUCCEEDED` / `UPLOAD SUCCEEDED`），不要只看退出码——把脚本接进管道时，退出码会变成管道末尾那个命令的。

`.gitignore` 拦了 `*.p8`、`*.mobileprovision`、`*.certSigningRequest`。

构建号默认取 `git rev-list --count HEAD`——单调递增，不用记上次传到几。

### 推送（APNs）

推送要四个值，全都配上才生效，缺一个 Relay 就不叫醒任何人 —— 其余功能不受影响。

```sh
npx wrangler secret put ROWEL_APNS_KEY --config relay-worker/wrangler.jsonc   # .p8 全文，粘进去
npx wrangler secret put ROWEL_APNS_KEY_ID --config relay-worker/wrangler.jsonc
npx wrangler secret put ROWEL_APNS_TEAM_ID --config relay-worker/wrangler.jsonc
npx wrangler secret put ROWEL_APNS_TOPIC --config relay-worker/wrangler.jsonc  # ai.novabox.rowel
```

密钥在 https://developer.apple.com/account/resources/authkeys/list 建，勾 **Apple Push Notifications service (APNs)**。`.p8` **只能下载一次**。

四个都用 `secret` 而不是 `var`：`.p8` 是私钥，另外三个虽然不是秘密，但放一起才不会有人下次只 rotate 一半。

**为什么签名在 Relay 而不在 Bridle。** APNs 只收开发者密钥签的推送。那把密钥不能塞进跑在别人笔记本上的 Bridle —— 否则每个用户都握着能推给所有其他用户的钥匙。所以 Relay 签，Relay 也因此成了唯一会知道 device token 的组件。

**它不会知道推送的内容。** Bridle 只发 token 和机器名，横幅上的字是 `relay-worker/src/apns.ts` 里的常量。`WakeRequest` 里没有能放正文的字段，所以这不是"承诺不看"，是没有东西可看。手机醒来后自己开隧道取内容，本地发通知 —— 那句话既没经过 Relay，也没到过苹果。

**用 alert 不用 silent。** `content-available` 是更诱人的设计（醒来、取、发真实文案），但 iOS 把静默推送当可丢弃的：限流、低电量模式下丢、app 被划掉后干脆不送。"能删掉这个吗"不能等系统心情好了再送。

### 提审时会被问到的

- **相机权限**：扫配对二维码。`INFOPLIST_KEY_NSCameraUsageDescription` 里已经写清了用途。
- **本地网络权限**：同 Wi-Fi 直连电脑。`INFOPLIST_KEY_NSLocalNetworkUsageDescription` 说明了为什么。
- **ATS 例外**：`NSAllowsLocalNetworking: true`。直连是局域网内的明文 WebSocket，里面搬的全是 Noise 密文——底下再套一层 TLS 是给一个没人能签发证书的名字做认证，没有意义。走 Relay 的路径是 `wss`，没有例外。
- **加密出口合规**：`ITSAppUsesNonExemptEncryption: true` 已写进 Info.plist。这是实话——app 用 CryptoKit 实现 Noise（Curve25519 + ChaCha20-Poly1305）加密用户输入，不属于苹果列出的任何一项豁免（非医疗、非仅认证、非版权保护、非 56 位以下）。填 false 能少答一道题，但那是在出口声明上说假话。代价是 App Store Connect 会问一次是否按大众市场自分类（ECCN 5D992.c，是），随之而来的是每年一次给 BIS 的自分类报告。不阻塞任何构建。
- **隐私清单**：`ios/Rowel/PrivacyInfo.xcprivacy`。不追踪、不收集、无第三方 SDK；唯一需要声明理由的 API 是 `UserDefaults`，理由码 `CA92.1`（本 app 自己的数据，不用于追踪）。
- **后台模式**：一个都不声明。曾经写着 `remote-notification` 却没有一行注册推送的代码，那是 Guideline 2.5.4 的直接拒审理由。做推送时连同实现一起加回来。

### 发布关键路径

上市是当前最大的杠杆，所以它不是部署文档的附录，是一条有顺序、有门槛的路径。每一项做完才能做下一项。

| # | 事项 | 门槛（做完的判据） | 阻塞于 |
|---|---|---|---|
| 1 | 版本协商落地 | 新旧双向互通测试通过 | — ✅ 已完成 |
| 2 | 部署 Relay | `deployed.test.js` 打公网地址全绿 | — ✅ 已完成 |
| 3 | 写 `/help` 与 `/privacy` | 隐私页说清 Relay 能观测到什么 | — ✅ 已完成 |
| 4 | 仓库转公开 | 全历史秘密扫描通过、LICENSE 就位、包元数据非 UNLICENSED、打出 `install.sh` 里 `ROWEL_REF` 指的那个 tag | 只差打 tag |
| 5 | 购买 Developer Program | 账号可签发 APNs key | — ✅ 已完成 |
| 6 | 签 Paid Applications 协议 | ASC → Business → Agreements 显示 Active | 人工 |
| 7 | 建 ASC API key | `ios/release.sh` 能跑到上传 | 人工 |
| 8 | TestFlight 外测 | 一个非自己的设备装上并完成一次配对 | 6、7 |
| 9 | 提交审核 | 加密出口声明、隐私清单、权限说明齐备 | 8 |

第 9 项的三样都已就位，见上一节。

### 如果一直不买那 $99

这不是"推迟"，是**换一个产品定位**，必须说清楚而不是含糊过去：

- 阶段目标降为**源码开发预览**：会用 Xcode 的人自己 clone、自己签、每 7 天重装一次
- README 与所有对外表述**不得**宣称"可发布产品"或"上架中"
- 推送与定时任务**从路线图移除**，不是标为"待做"——没有付费账号它们永远不会做完
- 分发只能靠源码；浏览器插件（Chrome Store $5 一次性、无设备限制）反而成为唯一能真正上架的客户端

**这条路可以走，但它是一个不同的产品。**混着说会让所有计划都建立在一个没做的决策上。

### 官网要重做（未开始）

现在这四个页面是**功能正确、定位错误**的：它们在用文字解释一个视觉产品。

一个手机 App 的官网，主体应该是**手机 App 本身长什么样** —— 截图、录屏、真实界面。用户扫一眼就知道这是什么、界面好不好看、值不值得装。现在首页第一屏是三段散文，用户看完还是不知道它长什么样。

重做时的要求：

- **视觉主体是设备图 / 录屏**，不是文字。审批卡片、轨迹、会话面板这三个是最有说服力的画面
- 文字降级为图旁的说明，不是内容主体
- 保留现在这版**内容上的诚实**：`/get` 说清楚还没上架、`/privacy` 说清楚 Relay 存了什么。重做的是表达方式，不是把这些话删掉换成营销词
- 截图要能随 App 更新而更新，不能手工维护一堆很快过期的图

**前置**：App 的界面要先稳定下来，现在还在每天改。等功能收敛了再做，否则拍的图第二天就过期。

### 对外页面

四个页面在 `site/public/`，部署命令：

```sh
npx wrangler deploy --config site/wrangler.jsonc
```

隐私页（`site/public/privacy.html`）是**唯一一份对外承诺 Relay 能看到什么的文档**，所以它里面每一条都要能在代码里对上，而不是能自圆其说。写的时候核对过这几处，改动 Relay 或配对流程时要一起改：

| 页面上的说法 | 权威在哪 |
|---|---|
| Relay 不落盘、不记日志 | `relay/src/` 里没有任何 `writeFile` / `console.*` |
| Relay 内存里存了什么 | `registry.ts` 的 `Machine`、`offers.ts` 的 `HeldOffer` |
| 机器名是明文 | `Machine.name`，注册时上报，配对前就要显示给 app |
| 配对期最多 15 分钟持有 bundle | `PairingBundle` 含 LAN 地址、公钥、一次性 token |
| 手机端解除配对是单向的 | `AppModel.unpair` 只动本地；Mac 侧要 `bridle revoke` |

**不要在隐私页上写代码没做到的事。**"手机上解除配对会同时通知电脑" 这种话写起来顺手，但它是假的——一部想被遗忘的手机，恰恰是最不该听它自称的那一部。

---

## 域名本身

`novabox.ai` 的注册到期日是 **2026-10-07**，从今天（2026-08-15）算还有 53 天。GoDaddy 那边确认一下自动续费是开的——域名一掉，所有已配对的 Bridle 会同时连不上 Relay（局域网直连还能用，因为那条路不经过域名）。
