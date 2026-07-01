---
description: "个人 Git workflow 安全约束，适用于个人 Git 类 skill。"
---

# Git Rules

本文件只定义 Git 操作必须满足的安全约束，不定义执行流程、分支修复方案或输出模板。

## 1. Repository Boundary

- Git 命令必须作用于明确的 repository 或 worktree。
- 对目标路径执行 Git 命令时，必须使用 `git -C "<repo-or-worktree-path>" ...` 或等价的显式路径方式。
- 禁止在 `C:\Users\liyanpeng` 主目录执行具有写入、副作用或历史改写风险的 Git 命令。
- 禁止在未确认目标 worktree 前执行 `stash`、`switch`、`checkout`、`branch`、`rebase`、`cherry-pick`、`reset`、`commit`、`push` 或 `worktree remove`。

## 2. Main Baseline

- 判断主分支基线是否最新时，必须以 `origin/main` 为准。
- 禁止只用本地 `main` 判断当前工作区是否基于最新主分支。
- 检查前必须获取远端 `main` 的最新引用。
- PowerShell 中传递包含 `@{...}` 的 Git revision 表达式时，必须整体加引号，例如 `'stash@{0}'`、`'@{u}'`。

## 3. Side Effect Guard

- 禁止在用户未明确要求或确认时自动执行 rebase、cherry-pick、reset、stash、switch、branch 创建或删除、push、worktree 删除。
- 禁止默认丢弃、覆盖、清理或隐藏用户未提交改动。
- 禁止使用 `git add -A` 或 `git add .` 暴力暂存全部文件。
- 禁止跳过 hooks。
- 禁止使用普通 `--force` 推送；确需改写远端历史时，只能在用户明确确认后使用 `--force-with-lease`。

## 4. Reporting Constraints

- Git 类 skill 的结果必须说明目标路径、当前分支、工作区是否 dirty、远端 `origin/main` hash，以及是否执行过有副作用的 Git 操作。
- 若只做检查而未修改任何 Git 状态，必须明确说明“未执行 rebase / cherry-pick / push / stash 等写操作”。
