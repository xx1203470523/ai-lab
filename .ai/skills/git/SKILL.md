---
name: git
description: "Git 版本控制操作：推送/提交并推送、变基、工作区、贮藏和分支工作流。触发关键词：推送、push、提交并推送、commit and push、推送代码、上传代码、变基、rebase、工作区、worktree、贮藏、stash、分支、branch、创建分支。仅提交请求不得进入 Push 工作流。"
---

# Git

## 工作方式

`scripts/` 下的脚本是各操作的**唯一权威实现**。AI 负责理解用户意图、选择动作、
解释脚本结果、决定异常怎么处置；**不负责口头复现判定逻辑**。

- 需要判断「能不能推、落后几个提交、工作区能不能删」时，跑脚本，不要凭读到的输出下结论。
- 脚本报 `blocked` 时，把 `reason` 与 `data` 里的证据转述给用户并停下等决定；不要绕过守卫。
- 脚本报 `error` 时，说明是执行出错，不要当成「业务上不允许」。
- 不要为了「顺手」而重写脚本里的检查。
- 脚本返回的 `cdCommand` 由你自己在会话 Shell 里执行。不要把命令丢给用户去敲，
  也不要只把路径打印出来就当已经切过去了。

接口、参数、全部阻断码、`cdCommand` 的执行与回读要求见
`./reference/scripts/script-contract.md`（改脚本要同步改它）。

## 核心安全规则

- 禁止在 `main`、`master`、`production` 或 `staging` 分支上直接提交或推送。
- 禁止使用 `--force` 推送。
- 禁止使用 `--no-verify` 或 `--no-gpg-sign` 跳过 Git hooks。
- 禁止将多个无关任务一起推送。
- 禁止提交当前任务范围外的变更。
- 禁止使用 `git add -A` 或 `git add .`；必须逐文件暂存。
- 创建 worktree 前必须确认当前目录和分支对应主工作目录；不在主工作目录时先切回主工作目录。
- 禁止在 worktree 内创建嵌套 worktree。
- rebase main 时若检测到本地 main 含合并提交，必须以 fetch 后的 `origin/main` 为基准，不得以本地 main 为基准。

以上多数规则**已固化在脚本里**（受保护分支、`-A` 写法、本地合并提交检测都会直接阻断），
保留在这里是因为脚本拦不下「用户口头要求做某件危险事」这类场景。

## 路由

先加载匹配的 rules，再按 workflow 执行。Worktree 意图优先于普通 Branch 意图。

| 用户意图 | Rules | Workflow | 行为 |
|---|---|---|---|
| **描述需求并开始开发**（`/git` 后面直接跟一段需求） | `./rules/branch.rules.md`、`./rules/worktree.rules.md` | `./workflow/feature-start.md` | 找同一迭代的既有分支 → 有就接着做，没有就新建工作区与分支 → 切进去开工 |
| Push / 提交并推送 / 上传代码 | `./rules/commit.rules.md`、`./rules/rebase.rules.md` | `./workflow/push.md` | 前置检查 → 变基 → 提交 → 推送 → MR 查重/链接和建议内容 |
| 仅提交 | `./rules/commit.rules.md` | — | 只提交；除非用户明确要求，否则不推送、不准备 MR 链接 |
| Worktree | `./rules/branch.rules.md`、`./rules/worktree.rules.md` | `./workflow/worktree.md` | 创建/进入/列表/删除工作区 |
| Branch | `./rules/branch.rules.md` | — | 分支命名和创建规范 |
| Rebase | `./rules/rebase.rules.md` | — | 变基约束与托管平台 |
| Stash | `./rules/stash.rules.md` | — | 贮藏命名和清理规范 |

以「查/删工作区」「查 MR 是否已存在」「看看落后多少」这类**只读查询**为主的请求，
直接跑对应脚本的只读动作并解释结果即可，不必走完整 workflow。

## 未匹配命令

对于 `git log`、`git diff`、`git blame`、`git cherry-pick` 等未匹配意图，直接使用通用 Git 知识处理。不要加载无关的 workflow 或 rules 文件。
