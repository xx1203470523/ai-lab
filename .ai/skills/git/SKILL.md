---
name: git
description: "Git version-control operations for push/push-and-commit, rebase, worktree, stash, and branch workflows. Trigger keywords: 推送、push、提交并推送、commit and push、推送代码、上传代码、变基、rebase、工作区、worktree、贮藏、stash、分支、branch、创建分支。Commit-only requests do not enter the Push workflow."
---

# Git

## Core Safety Rules

These rules always apply:

- Never commit or push directly on `main`, `master`, `production`, or `staging`.
- Never use `--force` for pushes.
- Never bypass Git hooks with `--no-verify` or `--no-gpg-sign`.
- Never push unrelated tasks together.
- Never commit changes outside the current task scope.
- Never use `git add -A` or `git add .`; stage files explicitly.

## Routing

Load the matching rules first, then follow the workflow. Worktree intent takes precedence over ordinary branch intent.

| User intent | Rules | Workflow | Behavior |
|---|---|---|---|
| Push / push-and-commit / upload code | `./rules/push.rules.md`, `./rules/commit.rules.md` | `./workflow/push.md` | Pre-check → rebase → commit → push → MR lookup/link and suggested MR content |
| Commit only | `./rules/commit.rules.md` | — | Commit only; do not push or prepare an MR link unless explicitly requested |
| Worktree | `./rules/branch.rules.md`, `./rules/worktree.rules.md` | `./workflow/worktree.md` | Create/enter/list/remove a worktree |
| Branch | `./rules/branch.rules.md` | — | Branch naming and creation rules |
| Rebase | `./rules/rebase.rules.md` | — | General Git knowledge plus repository-specific rules |
| Stash | `./rules/stash.rules.md` | — | Naming and cleanup rules |

An explicit request to create or update an MR belongs to the project-level MR Skill when one exists. The ordinary Push workflow only prepares MR title, description, duplicate lookup, and a web link; it must not call `glab mr create` or update an MR.

## Unmatched Commands

For intents outside these routes, such as `git log`, `git diff`, `git blame`, or `git cherry-pick`, use general Git knowledge. Do not load unrelated workflow or rules files.
