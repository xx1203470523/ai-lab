# /git 脚本契约

本文件是 `scripts/` 下 5 个脚本的**唯一权威说明**。rules 与 workflow 只描述「什么时候调用哪个脚本」，
不复述守卫逻辑；改了脚本就改这里。

判定与执行都固化在脚本里，AI 负责**意图理解、选择动作、解释结果、异常处置**。

## 通用约定

| 约定 | 说明 |
|---|---|
| 运行方式 | `powershell -NoProfile -ExecutionPolicy Bypass -File <脚本> -Action <动作> ...` |
| 输出 | stdout 只有一段 JSON，没有其它内容；诊断信息走 stderr |
| 结果落盘 | 可选 `-OutputJson <路径>`，用无 BOM 的 UTF-8 写出同一份 JSON |
| 退出码 | `0` 正常；`1` 阻塞（判定为需要用户决定）；`2` 执行出错 |
| 编码 | 源码带 UTF-8 BOM；输出走 UTF-8 字节流，避免中文乱码 |
| 仓库定位 | 全部动作支持 `-Root`；不传则用当前目录向上找仓库根 |
| 联网 | 一律不隐式联网。需要 `fetch` 的动作必须显式加 `-AllowFetch` |

### 结果结构

```json
{
  "schemaVersion": 1,
  "success": true,
  "status": "ok | blocked | error",
  "action": "wt.create",
  "repoRoot": "D:\\Project\\WMS",
  "errorCode": null,
  "reason": "给人看的一句话结论",
  "data": { },
  "commandsRun": [{ "command": "git ...", "exitCode": 0 }],
  "nextActions": ["给调用方的下一步提示"]
}
```

- `success` 等价于 `status == 'ok'`，不要只看它，`blocked` 与 `error` 的处置方式不同。
- `commandsRun` 只记命令与退出码，**不含输出正文**，所以不会把凭证或大段 diff 带进日志。
- 判定为 `blocked` 时，`errorCode` 必定非空且 `reason` 说明为什么停下。

## 脚本一览

| 脚本 | 动作 | 作用 |
|---|---|---|
| `wt.ps1` | `list` / `status` | 只读：工作区清单、当前所在工作区与分支 |
| | `find` | 只读：近 N 天仍未合并的分支迭代候选，供调用方做语义匹配 |
| | `create` | 建**新分支**加工作区，创建后回读校验 |
| | `attach` | 把**既有分支**挂到新工作区，接着旧分支干活 |
| | `enter` | 解析工作区路径，返回需要**调用方自己执行**的切换命令 |
| `prepush.ps1` | `check` | 只读：分支守卫、目标分支解析、与远端分叉、本地合并提交隐患 |
| | `rebase` | 先做同样的检查，再变基到远端目标分支；冲突则中止并还原 |
| `commit.ps1` | `plan` | 只读：列出将暂存哪些显式路径、消息文件会带来什么 |
| | `commit` | 只暂存给定路径并提交 |
| `mr.ps1` | `query` | 该 source→target 是否已有 MR |
| | `link` | 在 query 之上附上评审证据与「新建 MR」链接 |
| `cleanup.ps1` | `plan` | 只读预检：逐个给可删/需保留判定，返回确认令牌 |
| | `apply` | 必须带令牌才执行；执行前重新校验状态 |
| | `prune` | 清掉目录已消失的失效工作区登记 |

## 各脚本接口与阻断码

### wt.ps1

```text
-Action list|find|create|attach|enter|status [-Name <名称|分支名>] [-Branch <新分支名|既有分支名>]
        [-Base <基分支>] [-Target <集成分支>] [-SinceDays <天数>] [-Top <个数>] [-DetailTop <个数>]
        [-Root <路径>] [-OutputJson <路径>] [-AllowFetch] [-DryRun]
```

- `-Name` 按**工作区目录名**或**分支名**解析，两者都能匹配。`attach` 不传 `-Name` 时
  用分支名规范化出的目录名。
- `-Base` 不传时按「主工作目录当前分支 → 唯一的远端候选分支」推断；推不出就停下问用户。
- `create` 只建**新**分支；分支已存在（本地或远端）会被拦下，改用 `attach`。

#### `find` 的定位

`find` **只给客观事实，不做语义匹配**。「这段中文需求是不是对应这个英文分支名」
（`仓库备料综合报表` → `prep-material-report`）是翻译加判断，脚本一旦猜就会误配，
所以候选清单原样交给调用方，由调用方比对后下结论。脚本保证的只有：
候选确实在时间窗内、确实未合并、确实不是集成分支。

`-SinceDays` 默认 30（分支最后提交时间），`-Top` 默认 20（按最后提交时间倒排后截断），
`-DetailTop` 默认 10（前 N 个才去拉最近 3 条提交标题）。`detail` 是逐分支 fork，
每次约 128ms，所以默认只对最可能被选中的前 10 个做。

候选里几个易误读的字段：

| 字段 | 说明 |
|---|---|
| `hasWorktree` / `worktreePath` | 已有工作区 → 走 `enter`；没有 → 走 `attach` |
| `aheadOfTarget` / `behindTarget` | 相对集成分支。领先为 0 且**没有工作区**的已被排除（已合并） |
| `hasUpstream` | 本地是否登记了上游分支 |
| `aheadOfUpstream` | 领先自己的上游。**没有上游时为 `null`** —— 这时的「未推送提交」无从谈起，不要当成 0 或全部未推 |

排除规则里有一个必须记住的例外：**领先为 0 但仍然挂着工作区的分支不排除**。
刚 `create` 出来、还没提交的工作区分支领先同样是 0，按「已合并」丢掉它，
用户回头找这个迭代就找不到，会以为没在做而重开一个。
这类会被计入 `excluded.mergedWithWorktree` 并保留在候选里。
`excluded.merged` 是「已合并**且没有工作区**」的数量。

> 「领先/落后」的口径：内部用的是 `for-each-ref` 的 `ahead-behind` 原子，实测它的输出是
> **「领先 落后」**，与 `git rev-list --left-right --count` 的**左=落后 右=领先**相反。
> 交叉验证过，不要凭文档直觉改。

| errorCode | 含义 |
|---|---|
| `name-required` / `branch-required` | 缺参数 |
| `worktree-not-found` | 找不到匹配的工作区 |
| `branch-not-found` | `attach` 时本地与 origin 都没有该分支，应改用 `create` |
| `branch-already-checked-out` | 该分支已挂在别的工作区上，应改用 `enter` |
| `nested-worktree-forbidden` | 当前目录已在某个链接工作区内，先回主工作目录 |
| `main-worktree-detached` | 主工作目录 HEAD 游离，基分支无从判断 |
| `protected-branch-name` | 分支名与受保护的集成分支同名 |
| `base-branch-ambiguous` | 有多个远端候选，必须由用户指定基分支 |
| `target-branch-unresolved` | `find` 判不了「已合并」因为集成分支不唯一，必须问用户 |
| `remote-base-missing` | 远端没有该基分支，需要 `-AllowFetch` |
| `branch-scan-failed` | `git for-each-ref` 失败 |
| `target-path-exists` / `branch-already-exists` / `remote-branch-already-exists` | 目标已存在 |
| `worktree-create-unverified` | `git worktree add` 成功但回读不到该工作区 |

`attach` 挂**本地已有**的分支时直接挂它，保持它当前的提交位置不动，**不擅自重置到 origin**；
只有分支仅存在于远端时才建一个跟踪远端的本地分支（`data.source` 区分这两种）。

**工作区切换**：`create` / `attach` / `enter` 都会返回 `cdCommand`
（形如 `Set-Location -LiteralPath '<路径>'`）与 `parentShellNote`。
子进程改不了父 Shell 的当前目录，所以这条命令由**调用方（AI）在自己的会话 Shell 里执行**，
并用 `(Get-Location).Path` **回读确认**；不要把命令丢给用户去敲，也不要只把路径打印出来就当切换完成。

### prepush.ps1

```text
-Action check|rebase [-Target <目标分支>] [-Root <路径>] [-OutputJson <路径>] [-AllowFetch] [-AllowUntracked]
```

| errorCode | 含义 |
|---|---|
| `detached-head` | HEAD 游离 |
| `protected-branch` | 当前就在受保护的集成分支上 |
| `target-branch-unresolved` | 目标分支推不出来，必须问用户 |
| `source-equals-target` | 源与目标同一个分支 |
| `remote-target-missing` | 远端引用不存在，需要 `-AllowFetch` |
| `fetch-failed` | fetch 失败 |
| `dirty-tree` | 有未提交改动，拒绝变基。已跟踪改动永远拦；未跟踪文件默认也拦，只有显式 `-AllowUntracked` 才放行 |
| `rebase-conflict` | 变基冲突，**已自动 abort 还原**并列出冲突文件 |

`data` 里的 `behindTarget` / `aheadOfTarget` 是**变基前**的值，属于触发依据；
变基后的真实状态在 `behindTargetAfterRebase` / `aheadOfTargetAfterRebase`。
`localTargetMergeCommits` 是「本地集成分支有多少远端没有的合并提交」，
它大于 0 就说明本地分支不能当变基基准，只能用 `refs/remotes/origin/<target>`。

### commit.ps1

```text
-Action plan|commit -Path <文件列表> -MessageFile <文件> [-Root <路径>]
        [-OutputJson <路径>] [-AllowNonConventional] [-DryRun]
```

| errorCode | 含义 |
|---|---|
| `paths-required` | 没给路径。本脚本不提供批量暂存 |
| `invalid-path-specifier` | 出现 `-A`/`--all`/`.`/`*`/`-u` 或仓库外、仓库根路径 |
| `path-not-changed` | 列出的路径没有待提交改动，不属于本次范围 |
| `message-file-required` / `message-file-missing` | 消息文件缺失 |
| `empty-message` | 消息为空 |
| `attribution-line-forbidden` | 消息含 `Co-Authored-By:` 或 `Generated with Claude Code` |
| `non-conventional-subject` | 标题不符 `<type>(<scope>): <简述>`；确属例外才加 `-AllowNonConventional` |
| `nothing-staged` / `git-add-failed` / `git-commit-failed` | 提交阶段失败 |

两个易踩的点：

- **数组参数**：`powershell -File` 不会把 `-Path a.txt b.txt` 拆成两个；写成
  `-Path 'a.txt,b.txt'` 也会作为**单个字符串**进来。脚本内部按 `,` `;` 换行再拆一次，
  两种写法都能用。在会话里用 `& script.ps1 -Path a.txt,b.txt`（PowerShell 原生数组）
  同样可以。
- **消息一律走文件**：多行提交信息经 here-string 传给原生进程会被拆断，
  所以只接受 `-MessageFile`，顺带让消息正文不出现在命令行里。

### mr.ps1

```text
-Action query|link [-Source <分支>] [-Target <分支>] [-Root <路径>]
        [-OutputJson <路径>] [-AllowFetch]
```

**只读**。绝不调用 `glab mr create`，绝不更新 MR、分配 reviewer、加 label。
创建或更新 MR 属于另一个需显式请求的动作，交给项目级 MR 技能。

| errorCode | 含义 |
|---|---|
| `detached-head` | 没传 `-Source` 且 HEAD 游离 |
| `target-branch-unresolved` / `source-equals-target` | 同 prepush |
| `no-origin-remote` | 没有 origin |
| `not-gitlab` | 远端不是 GitLab。推送不受影响，且**不会编造** MR 链接（`createUrl` 为 null） |
| `mr-lookup-degraded` | `glab` 不可用或调用失败。同样不编造链接，`status` 为 `blocked` |

### cleanup.ps1

```text
-Action plan|apply|prune [-Name <名称|分支名>] [-Target <分支>] [-ConfirmToken <令牌>]
        [-Root <路径>] [-OutputJson <路径>] [-AllowFetch] [-AllowUntracked]
```

严格两阶段：`plan` 只读并返回 `confirmToken`；`apply` 必须带令牌，
执行前用同样的算法重算令牌，不一致就报 `state-changed-since-plan` 拒绝执行。
令牌由每个候选的 `路径|分支|HEAD|合并判定|改动数|未推送数` 加目标引用与
`-AllowUntracked` 取值做 SHA256 得到，所以期间任何人推了代码或改了文件、
或者换了开关，都会让旧令牌失效。

`mergedVerdict` 取值与处置：

| 取值 | 依据 | 能否删 |
|---|---|---|
| `merged` | `git rev-list --count origin/<target>..<branch>` 为 0 | 可删 |
| `merged-squashed` | 提交不在目标分支，但 `glab` 报该 MR 为 `merged` | 可删 |
| `not-merged` | MR 状态不是 merged | 不可删 |
| `unknown` | 有提交不在目标分支且查不到 MR 状态 | **不可删**，按规则停下 |

其他阻断码：`confirm-token-required`、`state-changed-since-plan`、`worktree-not-found`、
`remote-target-missing`、`target-branch-unresolved`、`fetch-failed`、`prune-failed`。

**未提交改动的分级**（`trackedChangedFiles` / `untrackedFiles`）：

- 已跟踪文件的改动：**永远拦**，没有开关可以放行。
- 未跟踪文件：默认也拦；用户明确确认可以丢弃这批未跟踪内容后，加 `-AllowUntracked`
  才转为可删，此时该候选 `needsForce` 为真。

删除动作的自我保护：`git worktree remove` **默认不加 `--force`**（脏工作区让 git 自己拦），
**只有 `needsForce`（即脏的只有未跟踪文件）的候选才加 `--force`**；已跟踪改动进不了
可删清单，所以 `--force` 永远不会用来丢弃已跟踪改动。分支用 `git branch -d` 而**不是 `-D`**
（未合并让 git 自己拦）；工作区没删掉就不动分支，避免留下「分支没了工作区还在」的半成品。

**「未推送提交」必须在该工作区自己的目录里算**：`git log ... HEAD` 在仓库根跑取到的是
主工作目录的 HEAD，会把 main 的未推送提交摊到每个候选头上（2026-10-21 实测：
main 领先 origin/main 3 个提交，导致 23 个候选全部误报「3 个提交未推送」）。
实现里用 `$worktree.path` 作为 `-RepoRoot` 跑这两条 log。

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-git-skill-tests.ps1
```

在 `%TEMP%\git-skill-tests` 下搭一个带**假远端**的隔离仓库（主工作目录 + 两个链接工作区），
跑完即清理。**不会**向任何真实远端推送、合并 MR 或删除真实工作区。
加 `-KeepLab` 可保留现场排查。

改了 `scripts/` 下任何文件都要重跑；测试未过不要下结论。
