# Git Rebase 约束

以下为 AI 无法推断的项目特定规则，通用 rebase 操作不再赘述。

- 变基目标：`origin/main` 或 `origin/production`，按当前分支的基分支选择
- 冲突策略：`git rebase --abort` 后向用户报告冲突文件清单，不自行解决
- 托管平台：GitLab（使用 `glab` CLI，非 `gh`）
- 在 worktree 内变基前，确认主工作目录的基分支状态
