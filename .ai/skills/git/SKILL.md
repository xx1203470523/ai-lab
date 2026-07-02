---
name: git
description: "Git 版本控制操作：推送/提交/push、变基/rebase、工作区/worktree、贮藏/stash、分支/branch。触发关键词：推送、push、提交推送、commit and push、推送代码、提交代码、上传代码、变基、rebase、工作区、worktree、贮藏、stash、分支、branch、创建分支"
---

# Git

## 核心安全规则

以下规则**始终有效**，不区分操作类型：

- 禁止在 main/master/production/staging 分支上直接提交或推送
- 禁止使用 `--force` 推送
- 禁止跳过 git hooks（`--no-verify`、`--no-gpg-sign`）
- 禁止一次推送多个不相关任务的改动
- 禁止提交当前任务范围外的代码变更
- 禁止使用 `git add -A` / `git add .`，逐文件 `git add`

## 路由

根据用户意图，**先阅读对应的执行流程文件**，规则文件由流程在对应步骤按需加载：

| 命令 | 入口 | 说明 |
|------|------|------|
| Push（推送 / push / 提交推送 / 上传代码） | `./workflow/push.md` | 前置检查 → 变基 → 提交 → 推送 → MR 链接 |
| Worktree（工作区 / worktree） | `./workflow/worktree.md` | 创建/进入/列表/删除工作区 |
| Branch（分支 / branch / 创建分支） | `./rules/branch.rules.md` | 分支命名与创建规范 |
| Rebase（变基 / rebase） | `./rules/rebase.rules.md` | 通用步骤用已有知识，rules 文件只含项目特定约束 |
| Stash（贮藏 / stash） | `./rules/stash.rules.md` | 通用步骤用已有知识，rules 文件只含命名与清理规范 |

## 未匹配命令

若用户意图不在以上路由中（如 `git log`、`git diff`、`git blame`、`git cherry-pick` 等），
直接用通用 git 知识处理。**不要**加载 workflow/ 和 rules/ 目录下的文件——它们不适用于这些命令。
