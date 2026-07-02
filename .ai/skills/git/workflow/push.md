# Git Push

## 1. 前置检查 (Pre-checks)

### 环境与分支校验

1. 检查当前仓库工作区是否处于 worktree，如果不在，需要用户确认
2. 读取 `./rules/push.rules.md`，检查当前分支是否符合推送规范
3. 检查是否落后远程（main / production / 远端分支），若有冲突需先处理

### 提交内容校验

- 读取 `./rules/commit.rules.md`，检查提交内容是否符合规范
- 若有自定义规范，读取 `./reference/commit/custom.md`

## 2. 执行推送 (Execute)

- 校验通过后，执行推送命令

## 3. 异常处理 (Error Handling)

- 若执行失败，立即停止后续操作，并向用户详细说明失败原因
