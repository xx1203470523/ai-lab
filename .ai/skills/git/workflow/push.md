# Git Push

## 1. 前置检查 (Pre-checks)

### 环境与分支校验

1. 检查当前仓库是否在 git 仓库中
2. 检查是否有未提交的变更（`git status` 有 modified 或 untracked 文件）
3. 远程仓库 `origin` 可访问
4. 读取 `./rules/push.rules.md`，确认当前分支不在 main/master/production/staging 上
5. 检查是否落后远程（main / production），若有冲突需先处理

### 提交内容校验

- 读取 `./rules/commit.rules.md`，检查提交内容是否符合规范
- 若有项目自定义规范，读取 `./reference/commit/custom.md`

## 2. 变基检查 (Rebase Check)

提交前检查是否基于远端最新的 main/production，有更新则变基：

```bash
git fetch origin main
git rebase origin/main
```

- rebase 冲突时：`git rebase --abort`，向用户报告冲突文件，不盲目强制解决

## 3. 提交 (Commit)

### 范围控制

仅提交当前对话任务涉及的代码变更。工作区中与当前任务无关的改动不纳入本次提交。
禁止使用 `git add -A` / `git add .`，逐文件 `git add`。

### 提交信息

按 `./rules/commit.rules.md` 格式编写。有项目自定义规范时优先使用。
提交信息尾部禁止含 `Co-Authored-By:` 和 `🤖 Generated with` 行。

## 4. 推送 (Push)

```bash
git push -u origin {branch-name}
```

推送成功后报告：分支名、提交 hash、推送结果、MR 链接。

### 生成 MR 链接

- 运行 `glab mr list --source-branch {branch-name} --output json` 检查是否已有 MR
- 若已有 MR，直接输出现有 MR 链接
- 若尚无 MR，输出创建链接：`https://<host>/<project>/-/merge_requests/new?merge_request[source_branch]={branch-name}&merge_request[target_branch]=main`
- `<host>` 和 `<project>` 从 `glab repo view --output json` 的 `web_url` 提取
- MR 链接单独一行、醒目展示

### MR 描述

MR 描述正文尾部禁止含以下行：
- `Co-Authored-By: Claude <noreply@anthropic.com>`
- `🤖 Generated with [Claude Code](https://claude.com/claude-code)`

## 3. 异常处理 (Error Handling)

- 执行失败立即停止后续操作，向用户详细说明失败原因
- 推送被拒（non-fast-forward）：检查是否有人在同分支协作，优先 rebase 而非 merge
