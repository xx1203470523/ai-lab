# Git Push 规范

- 禁止推送 `main`/`master`/`production`/`staging` 分支
- 不要一次推送多个不相关任务的改动，每次推送仅对应一个任务/主题
- 不要提交当前任务范围外的代码变更
- 不要跳过 git hooks（`--no-verify`、`--no-gpg-sign`）
