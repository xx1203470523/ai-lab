# Git Worktree 工作流

本工作流只负责**编排**：什么时候调哪个脚本、拿到结果后做什么、异常怎么处置。
前置校验、阻断条件、令牌算法全部以 `../reference/scripts/script-contract.md` 与脚本本身为准，
不要在这里或对话里重新推演一遍。

## 1. 进入 / 列表

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 -Action list
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 -Action status
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 -Action enter -Name <名称或分支名>
```

1. 用户给了名称就 `enter -Name`；只想知道有哪些就用 `list` / `status`。
2. `enter` 成功时返回 `cdCommand`，按 `../reference/scripts/script-contract.md` 的要求自己执行并回读确认；
   `alreadyThere` 为真就不必再切。
3. `worktree-not-found` 时把 `data.available` 列给用户，不要自行退化到「那就新建一个」。

## 2. 创建工作区

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\wt.ps1 `
    -Action create -Name <工作区名> -Branch <分支名> [-Base <基分支>] [-AllowFetch]
```

1. 工作区名用 `-` 分隔，分支名用 `/` 分隔；目录落在 `<仓库>/.claude/worktree/<工作区名>`。
2. **基分支不猜**。`-Base` 省略时脚本按「主工作目录当前分支 → 唯一的远端候选分支」推断；
   推不出会报 `base-branch-ambiguous`，此时停下问用户要并入 main 还是 production，不要替他选。
3. 报 `nested-worktree-forbidden` 说明当前目录已在链接工作区里，先回主工作目录再重跑。
4. 报 `protected-branch-name` 或 `branch-already-exists` 时改名字，不要试图绕过。
5. 成功后同样要执行返回的 `cdCommand` 并回读确认，再开始开发。
6. 脚本会回读校验新工作区确实登记成功；报 `worktree-create-unverified` 时不要当成功。

## 3. 清理工作区（两阶段，必须让用户先看到清单）

### 阶段一：预检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\cleanup.ps1 `
    -Action plan [-Name <名称>] [-Target <目标分支>] [-AllowFetch]
```

1. **把 `data.deletable` 与 `data.blocked` 两份清单完整展示给用户**，逐项给出
   `mergedVerdict`、`mergedEvidence`、`blockers`、`changedFiles`、`unpushedCount`。
2. 明确说明哪些「按规则保留」以及为什么，再等用户确认。**不要替用户确认**，
   也不要说「看起来没问题我就执行了」。
3. `mergedVerdict` 为 `unknown` 的**一律不可删**（通常是 squash 合并但 `glab` 查不到）。
   这种情况如实告诉用户查不到依据，让他决定，不要默认按已合并处理。

### 阶段二：执行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\cleanup.ps1 `
    -Action apply -ConfirmToken <阶段一返回的 confirmToken> [-Name <名称>] [-Target <目标分支>] [-AllowFetch]
```

1. `-Name` 与 `-Target` 必须与预检时**完全一致**，否则令牌对不上。
2. 报 `state-changed-since-plan` 说明自预检以来状态变了（有人推送或改了文件）。
   重新跑 `plan`，把新清单再展示一次，重新取得确认；不要复用旧确认。
3. 报 `confirm-token-required` 说明跳过了阶段一。回去做预检，不要手工拼令牌。
4. 结果为 `partial-cleanup` 时，逐条转述 `data.failed` 里失败在哪一步，不要只说「部分失败」。

### 失效登记

目录已被手工删掉、只剩 git 登记时用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <skill>\scripts\cleanup.ps1 -Action prune
```

## 4. 边界

- 当前会话就在待删工作区里时，脚本会把它列为阻塞项。先切回主工作目录再执行。
- 用户要求「强制删」时，先说明会丢什么再让他决定，不要改脚本绕过。
