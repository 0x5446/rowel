# AGENTS.md

给在本仓库里干活的 agent（DSH / Codex / Claude 都算）。这里只写两件事：跑什么门禁，以及**多个会话同时在这一个 checkout 里干活时怎么不互相踩**。项目本身的约定在 `CONTRIBUTING.md`，架构在 `docs/`。

## 门禁

```bash
npm test              # protocol / bridle / dsh-plugin / relay 的 TS 编译 + 单测 + docs 一致性
npm run check:docs     # 只查文档与代码是否一致
npm run test:ios       # iOS：xcodegen 生成工程后跑 xcodebuild test（等价于 cd ios && ./run-tests.sh）
```

`ios/run-tests.sh` 认两个环境变量：`ROWEL_SIM` 指定模拟器，`ROWEL_DERIVED` 指定 DerivedData 与结果包的落点。两个都不设时它按 `tail -1` 挑最新的一台 iPhone（**所有人都会挑中同一台**），并把结果写到 `ios/build/Rowel.xcresult`、用 xcodebuild 默认的 DerivedData。

## 多会话并发（重要）

这个仓库经常同时有多个 agent 会话在跑，共享同一个工作区。历史上互相踩坏过测试（test bundle 中途消失 / SIGKILL / 安装失败），根因就是下面第 1、2 条被忽略。

1. **模拟器一人一台。** 跑 iOS 测试时显式指定自己的设备，不要用未设 `ROWEL_SIM` 时的默认值：

   ```bash
   cd ios && ROWEL_SIM="iPhone 17e" ROWEL_DERIVED=/tmp/rowel-derived-<你的会话> ./run-tests.sh
   ```

2. **DerivedData 与结果包放私有目录**，不要写共享的 `ios/build`，也不要依赖默认的 `~/Library/Developer/Xcode/DerivedData`（同名 scheme 会互相覆盖）。上面的 `ROWEL_DERIVED` 就是干这个的；要跑单独一类用例、直连 xcodebuild 时照抄同样的两个路径：

   ```bash
   xcodebuild -project ios/Rowel.xcodeproj -scheme Rowel \
     -destination "platform=iOS Simulator,name=$ROWEL_SIM" \
     -derivedDataPath /tmp/rowel-derived-<你的会话> \
     -resultBundlePath /tmp/rowel-derived-<你的会话>/Rowel.xcresult \
     -only-testing:RowelTests/<某个类> test
   ```

3. **共享工作区里不动别人的 git 状态**：不要 `git stash` / `git reset` / `git add` 别人的树——别人的暂存是别人的意图。**提交自己的改动不算在内**：`git commit -- <你的路径>` 只提交列出的路径，不会把别人的暂存内容带进去（这个文件自己的两次提交就是这么做的），想更彻底就去自己的 worktree：

   ```bash
   git commit -m "..." -- ios/Rowel/Views/Foo.swift        # 只提交这些路径，别人的暂存不动
   git worktree add /tmp/rowel-wt-<你的会话> -b <你的分支>   # 或者整摊搬出去做
   ```

4. **要改别人正在改的文件，先开 worktree 并说一声。** 同一个工作区里并发编辑靠运气，不靠约定。

5. **资源认领写在 `.build-tmp/sessions.md`**（未被 git 跟踪）：模拟器、DerivedData、正在改的文件。跑之前看一眼，跑起来之前先追加自己的行。

6. **冲突怎么收**：先协商，谈定之后**由一方解完**，另一方不重复动。解完把结论写进提交信息或上面那份认领表，别让下一个会话重新推一遍。

## iOS 测试的一点环境事实

- 沙箱更严的 agent 环境里，`xcodebuild` 可能因为 Swift 宏插件服务写不了工作区外而失败（报 `swift-plugin-server produced malformed response`，随后的一堆「requires conformance to Observable」都是它的连带错误）。这是权限问题，不是代码问题。
- **测试跑到一半被杀，先怀疑撞车，别先怀疑内存。** 症状是 `Unable to initialize test bundle` / `Failed to create a bundle instance … Check that the bundle exists on disk`，或者干脆 SIGKILL。成因是被测的那份 app bundle **在测试途中被换掉了**：另一个会话把同一个 scheme 编进了同一份 DerivedData（默认按 scheme 名共用，所以**模拟器不同也照样撞**），或者两个会话在共用同一台模拟器。两次实测都是这个特征而非 OOM——19:33 死在 `InterruptLayoutTests` 起步处，12:49 死在 `MainThreadStarvationTests`。先按第 1、2 条排除，再去看代码。
- `MainThreadStarvationTests` 会挂载真实的 `ConversationView` 灌 200 chunk/s，是这套里最吃资源的一个；单独跑是稳的（10/10）。它在整套连跑里失败时，按上一条先排除撞车。
