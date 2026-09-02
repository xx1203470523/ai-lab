---
name: git
description: "Git 版本控制操作：推送/提交并推送、变基、工作区、贮藏和分支工作流。触发关键词：推送、push、提交并推送、commit and push、推送代码、上传代码、变基、rebase、工作区、worktree、贮藏、stash、分支、branch、创建分支。仅提交请求不得进入 Push 工作流。"
---

# Git

## 核心安全规则

以下规则始终有效：

- 禁止在 `main`、`master`、`production` 或 `staging` 分支上直接提交或推送。
- 禁止使用 `--force` 推送。
- 禁止使用 `--no-verify` 或 `--no-gpg-sign` 跳过 Git hooks。
- 禁止将多个无关任务一起推送。
- 禁止提交当前任务范围外的变更。
- 禁止使用 `git add -A` 或 `git add .`；必须逐文件暂存。

## 路由

先加载匹配的 rules，再按 workflow 执行。Worktree 意图优先于普通 Branch 意图。

| 用户意图 | Rules | Workflow | 行为 |
|---|---|---|---|
| Push / 提交并推送 / 上传代码 | `./rules/push.rules.md`、`./rules/commit.rules.md` | `./workflow/push.md` | 前置检查 → 变基 → 提交 → 推送 → MR 查重/链接和建议内容 |
| 仅提交 | `./rules/commit.rules.md` | — | 只提交；除非用户明确要求，否则不推送、不准备 MR 链接 |
| Worktree | `./rules/branch.rules.md`、`./rules/worktree.rules.md` | `./workflow/worktree.md` | 创建/进入/列表/删除工作区 |
| Branch | `./rules/branch.rules.md` | — | 分支命名和创建规范 |
| Rebase | `./rules/rebase.rules.md` | — | 通用 Git 知识与项目特定规则 |
| Stash | `./rules/stash.rules.md` | — | 贮藏命名和清理规范 |

显式创建或更新 MR 的请求，在存在项目级 MR Skill 时交给该 Skill。普通 Push workflow 只准备 MR 标题、正文、查重结果和 Web 链接；不得调用 `glab mr create` 或更新 MR。

## 未匹配命令

对于 `git log`、`git diff`、`git blame`、`git cherry-pick` 等未匹配意图，直接使用通用 Git 知识处理。不要加载无关的 workflow 或 rules 文件。
