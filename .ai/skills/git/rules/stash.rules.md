# Git Stash 约束

以下为 AI 无法推断的项目特定规则，通用 stash 操作不再赘述。

- 命名规范：`stash/{分支名}-{简短描述}`
- 推送前检查是否有残留 stash，提醒用户清理
- 清理 stash 前必须用户确认，不自行 `drop` 或 `clear`
