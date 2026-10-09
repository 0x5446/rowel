# Deep Review — M3：app 功能在 dsh 0.2 上可用，真模型验收，截图脚本移植

- Repo: /Users/alpha/workspace/rowel-wt-m3
- HeadSHA: bf99680b8af366fbd6692770775be1266140c85a（审查对象：commit bf99680，相对 origin/main）
- RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-rowel-wt-m3-bf99680-1791552109.CLiR
- 引擎：codex 0.157.1，配置 `work`（~/.codex-profiles/work），gpt-6-sol / llm_proxy / effort high（沿用 owner 为 M1/M2 指定的配置）
- 维度：correctness、goalfit、maintainability、conventions + 信号 security；cursor 未登录，跳过
- 规模：去掉 fixtures 19 文件 +676/−229；fixtures 重录并新增 2 个
- Phase 2：未派独立回证进程；全部 Warning 由作者逐条对照源码确认（与 M1 同法），1 条降级

## VERDICT: NEEDS_FIX → 已修复；1 条降为 Suggestion 不处理

0 条 Critical。去重后 13 条：

| # | 问题 | 来源 | 结论 | 处理 |
|---|---|---|---|---|
| 1 | 重连时子代理的审批先于列表到达，挂在子代理名下，父会话看不见 | correctness | 属实 | 列表读完、父子关系已知后把卡片挪到父会话（`reseatCards`）；测试 |
| 2 | `Tools/dsh.mjs` 把 dsh 的失败当成功，脚本继续往下走 | correctness | 属实 | 失败时把错误码与消息写到 stderr 并退出 1；会重试的提交步骤显式容错；`demo.sh` 的调用失败即停 |
| 3 | `demo.sh` 的会话不在工作区里 | correctness、goalfit | 属实 | 先取样例目录的工作区，再只用 `workspaceId` 创建 |
| 4 | `modelRows` 遇到 CRLF 或行首注释会丢路由 | correctness、maintainability | 部分属实 | 统一换行、去行尾空白、跳过行首注释；给了 settings 却取不到路由时报错；新增 `e2e/tests/settings.test.js`。未引入 YAML 库：只搬两个顶层节，文本处理已足够且已有测试钉住 |
| 5 | 真模型测试带着开发者真实 HOME，私人技能会进模型上下文 | conventions | 属实 | 模型模式同样用临时 HOME，只沿用环境里的凭据 |
| 6 | 截图环境的 PATH 加入了 node 所在目录，可能是用户目录 | conventions | 属实 | 由脚本直接以绝对路径的 node 启动 dsh，PATH 只留系统目录 |
| 7 | 截图日志含 launch token，home 可被其他用户读取 | security | 属实 | `umask 077`、home 目录 0700、旧日志收紧为 0600 |
| 8 | 目录列表 fixture 没有条目，条目解析坏了测试也会过 | goalfit、maintainability | 属实 | 录制前建一个可见、一个隐藏目录；断言名称、路径与隐藏标记 |
| 9 | 不可浏览的判断没有经过界面实际用的代码 | maintainability | 属实 | 抽出 `DirectoryListing.cannotBrowse`，界面与测试共用 |
| 10 | 子代理翻页漏传父地址不会被测试发现 | maintainability | 属实 | 子代理用例里翻页并断言 subagent 地址 |
| 11 | 目录 fixture 的面包屑名称含录制机器的临时目录名 | conventions | 属实 | 录制时按脱敏后的路径重建面包屑名称并去重 |
| 12 | 迁移文档把 timed 提问、真机走查仍写在 M3 | conventions | 属实 | 改为延后与 M4；M3 行注明完成与实测出处 |
| 13 | 端口被抢占时 `Tools/dsh.mjs` 会把 cookie 发给占用者 | security | 降为 Suggestion | 截图 harness 一次性、只在本机回环；同一用户的进程本就能读 cookie 文件，跨用户抢占端口需在 dsh 停止的窗口里恰好监听同一端口，换来的是一个一次性 harness 的访问。成本与收益不相称，不处理 |

## 修复后的验证

- iOS 单测 374/374；`npm test` 全过；e2e（不带模型）59 过、9 跳过（4 个部署 Relay，5 个需模型）
- 真模型：`e2e/tests/model.test.js` 4/4 通过（隔离 HOME 下）；`screenshots.sh --up` 与 `demo.sh --arm` 在新的 PATH/权限下复跑通过（arm 的会话建在工作区）

## 维度元信息

| 来源 | VERDICT | issues | exit |
|---|---|---|---|
| dim-correctness | NEEDS_FIX | 4 W | 0 |
| dim-goalfit | NEEDS_FIX | 1 W + 1 S | 0 |
| dim-maintainability | NEEDS_FIX | 3 W | 0 |
| dim-conventions | NEEDS_FIX | 3 W + 1 S | 0 |
| dim-security | NEEDS_FIX | 2 W | 0 |
