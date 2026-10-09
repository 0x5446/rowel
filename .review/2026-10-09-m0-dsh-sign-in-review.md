# Deep Review — M0：Bridle 登录 dsh 0.2 并识别版本

- Repo: /Users/alpha/workspace/rowel-wt-m0
- HeadSHA: fe59c7f3a5f4f36e3ea3bcec568b56f1da137bb6（审查对象：commit fe59c7f）
- RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-rowel-wt-m0-fe59c7f-1791525358.hw7P
- 引擎：codex，配置 `work`（~/.codex-profiles/work），模型 gpt-6-sol，effort high（owner 指定）。首选的 `codex:work`（~/.codex/work.config.toml）因找不到 provider `llm_proxy` 全部失败，未自动重试，经 owner 选择换成 `work`
- 维度：correctness、goalfit、maintainability、conventions、security（信号触发）、concurrency（信号触发）；cursor 未登录，跳过
- Phase 2：未派独立回证进程。全部 C/W 由作者逐条对照源码确认后修复（见下），修复后用单测和真实 dsh 实测验证

## VERDICT: NEEDS_FIX → 全部修复，无遗留 Critical / Warning

0 条 Critical；去重后 10 组 Warning（多数被 2～5 个维度同时报出）。

| # | 问题 | 来源 | 处理 |
|---|---|---|---|
| 1 | 插件：dsh 交出端口晚于 3 秒，Bridle 固定在旧端口 | correctness、goalfit(R1)、concurrency | 插件读宿主 dsh 的版本（经 `realpath` 找到 `@deepseek-ai/dsh/package.json`）：0.2 一直等到登录（60 秒上限并报错），0.1 立即启动，读不到等 3 秒；回调重跑且端口变了时记错误要求重启 dsh |
| 2 | 自启动：Bridle 被强杀时含 token 的临时文件残留 | correctness、goalfit(R2)、security | 每次启动前清理 `secrets/dsh-launch-*.log`。影响本来就小：0600 文件在 0700 目录里，同一用户本可读 dsh 的签名密钥 |
| 3 | 被拒的 cookie 未在所有路径作废；旧请求的 401 会删掉新 cookie | correctness、goalfit(R4)、security、concurrency | `respond`、`export`、WebSocket 握手、`identifyDsh` 统一作废；`forgetCookie(base, refused)` 只删与被拒值相同的条目 |
| 4 | 别的服务回 401 被当成 dsh，并被发送 cookie | correctness、goalfit、security | 401 之后再核对首页的 dsh 特有拒绝文案（`dsh web …`），不符为 unknown，不发 cookie |
| 5 | 插件配置写入非原子；同一 insert 下有别的条目时卸载会留下坏 YAML | correctness、goalfit(R7)、concurrency | 临时文件 + rename，保留原权限；只匹配后面没有缩进续行的完整条目，否则交给人手工处理 |
| 6 | `status` 把已登录的 0.2 报成 down | correctness、goalfit(R8) | 用版本识别判断 up/down；0.1 才跑旧健康检查；M1 前对 0.2 如实说明"已登录但还不能服务"，`doctor` 对此给 warn |
| 7 | 两条登录路径缺端到端测试 | maintainability(R9) | 新增 `bridle/tests/dsh-launch.test.js`（假 dsh 打印反代地址的 token 行）、`dsh-plugin/tests/sign-in.test.js`（假 ctx.inject） |
| 8 | 插件 inject 回调同步抛错会进 dsh | conventions | 回调全部包在 try/catch，记日志 |
| 9 | 多进程写 cookie 文件互相覆盖 | concurrency | 每次修改都重读磁盘、只改一条再写 |
| 10 | 换 cookie 一次超时就让启动失败 | concurrency | 在 45 秒启动期限内重试；最终失败时提示停掉该 dsh 再启动 bridle |

写测试时发现：假 dsh 对带 cookie 的旧方法回 401，会让 Bridle 正确地作废 cookie；真实 dsh 0.2 回的是 404。已按真实行为修正假 dsh。

## 验证

- `npm test`：195 通过（含文档一致性检查）
- 真实 dsh（隔离实例，未碰 3080）：插件 + 0.2.0-rc.2 绑定到 dsh 报告的端口并登录、无错误日志；用户自启动的 0.2 与 0.1.7 均识别为"需要登录"并给出办法；0.1.1 识别为旧版
