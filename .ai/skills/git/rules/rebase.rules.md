# Git Rebase 约束

**执行方式**：走 `../scripts/prepush.ps1 -Action rebase`，不要手工拼 `git fetch` + `git rebase`。
阻断码处置见 `../reference/scripts/script-contract.md`。

- 变基目标是 `origin/main` 或 `origin/production`，按当前分支的基分支选
- 目标分支必须有依据地解析出来；解析不出唯一答案时停下问用户，不得默认 main
- 基准只能是远端引用 `refs/remotes/origin/<目标分支>`，本地集成分支含合并提交时不得作为基准
- 冲突时 `git rebase --abort` 后把冲突文件清单交给用户，不得自行解决或用 merge 绕过
- 托管平台是 GitLab，用 `glab` 而不是 `gh`
