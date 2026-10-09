# 文档索引

职责不重叠。按需要读，不必按顺序。

| 文档 | 回答什么 | 谁该读 |
|---|---|---|
| [`architecture.md`](architecture.md) | **为什么这样设计**，接缝在哪，新功能落在哪 | 要改这个系统的人；review 设计的人 |
| [`protocol.md`](protocol.md) | **App 与 Bridle 之间线上到底是什么字节**（配对、Noise、隧道版本 2 的帧、Relay），精确到位 | 要写第三方客户端、或重新实现任一端的人 |
| [`fold.md`](fold.md) | **dsh 0.2 的事件如何变成屏幕上的东西**：快照替换、流式帧、逐事件规则与边界情况 | 要写任何一个客户端的人 |
| [`dsh-api-inventory.md`](dsh-api-inventory.md) | app 实际调用的 dsh 0.2 端点与流、参数形状、在代码里由谁调用 | 要调用 dsh 的人 |
| [`dsh-0.2-protocol.md`](dsh-0.2-protocol.md) | dsh 0.2 自己的线协议：认证、`/api`、`remote.mux`、follow/page、`$events`，带源码出处与实测记录 | 排查 dsh 行为、或 dsh 升级后核对接口的人 |
| [`dsh-0.2-migration.md`](dsh-0.2-migration.md) | 从 dsh 0.1 迁到 0.2 的设计决策（D1–D8）、里程碑与风险 | 想知道某个取舍为什么这样定的人 |
| [`deployment.md`](deployment.md) | Relay 怎么部署，DNS 怎么配，上架前还缺什么 | 要把它跑起来的人 |
| [`instance-awareness.md`](instance-awareness.md) | 设计：一台 Mac 上有多个 dsh 时，app 怎么说清连着哪一个 | 改实例识别、救援提示的人 |
| [`one-pair-per-mac.md`](one-pair-per-mac.md) | 已否决的设计，留作记录：为什么不做"一机一配对" | 又想动这个念头的人 |

## 规格等级

不是每一节都同等成熟，读的时候要知道自己在读哪一种：

**规范级** —— 已实现，有测试守着，可照着重新实现：

- `protocol.md` 全部（权威是 `protocol/scripts/emit-vectors.js` 的向量）
- `fold.md` 全部（权威是 `ios/RowelTests/StoreTests.swift` 与 `LoadingTests.swift`，dsh 0.2 的真实形状见 `Fixtures/dsh-0.2/`）
- `architecture.md` §1–§9、§14–§18

**设计级** —— 决策已定、落点已定，但尚未实现：

> **补规范文档不是发布的前置条件。**首发阶段的权威是现有的测试向量、测试与参考实现（协议看 `protocol/scripts/emit-vectors.js`，折叠看 `Conversation.swift`）。新功能只写最小决策记录和验收用例即可动手。
>
> 只有出现下列任一情况，才把它升级成规范级：出现第二个真实客户端、有外部贡献者要接、或者两端实现开始互不兼容。在那之前，写规范挤占的是发布时间——而没有用户的完备规范服务的是一个不存在的人。
>
> 例外是**安全相关**的设计（推送密钥协议就是）：那类实施前必须先写清楚，因为写错了不会报错，只会不安全。

下列子系统属于设计级：

- `architecture.md` §10 推送
- `architecture.md` §11 定时任务
- `architecture.md` §12 多 agent 后端
- `architecture.md` §13 trace

## 冲突时以什么为准

```
测试向量  >  测试  >  代码  >  文档
```

`npm run check:docs` 机械地盯住其中一部分：一个 reimplementer 会照抄的常量、prologue 两端是否一致、帧类型是否都被描述、以及 `fold.md` 声称"尚未折叠"的 projection 有没有偷偷被折叠了。它跟在 `npm test` 里跑。

它只检查有唯一正确答案的事，不检查散文。**剩下的靠人**——所以改了 `bridle/src`、`ios/Rowel/Store`、协议帧或 dsh 方法之后，要么更新对应文档，要么在提交信息里写明为什么不影响。

文档与代码不一致时，先判断哪个是对的：如果文档描述的是**应该**的行为而代码没做到，那是代码 bug；如果文档记错了**已经**稳定的行为，那是文档 bug。两种都要修，不要只改一边让它们"看起来一致"。

## 给 AI 编码用的读法

要实现一个新客户端：`protocol.md` → `fold.md` → 跑通向量 → 接真实 Bridle。

要在现有代码里加功能：`architecture.md` §3（三个扩展点）→ 附录（新功能该往哪放）。

要评估一个改动是否安全：`architecture.md` §16（不变量清单），每条都有对应测试。
