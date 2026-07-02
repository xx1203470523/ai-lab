---
name: git-push
description: "推送当前代码变更到远程仓库。自动基于main创建规范分支、生成提交备注、提交并推送。触发关键词：推送、push、提交推送、commit and push、推送代码、提交代码、上传代码"
shell: powershell
version: 1.0.0
---

## Trigger

用户要求推送代码、提交并推送变更到远程仓库时触发。

## Workflow

### Step 1: 检查前置条件

- [ ] 当前在 git 仓库中
- [ ] 有未提交的变更（`git status` 有 modified 或 untracked 文件）
- [ ] 远程仓库 `origin` 可访问
- [ ] 当前不在 main/master/production/staging 分支上直接操作（如在这些分支上，先提醒用户确认）

### Step 2: 变基检查

提交前检查是否在基于远端最新的main/production
如果有更新组需要变基

```
git checkout -b {branch-name}      # 从当前位置创建新分支（保留未提交改动）
git fetch origin main
git rebase origin/main             # 变基到最新 main
```

### Step 3: 提交

**范围控制**：仅提交当前对话任务涉及的代码变更。工作区中与当前任务无关的改动不纳入本次提交。

#### 4. 编写提交信息并提交

**标题格式**：`type(scope): 中文简短总结`

**正文格式**：使用结构化 Markdown 章节，保持中文、简洁、可追溯：

## Summary

- 改动概述及原因

## Changed Files

- `path/to/file` - 相关改动说明

- `## Summary` 必填，其余章节按需添加
- 小改动可只保留 `## Summary`
- 不要声称运行了实际未执行的验证步骤

**提交备注尾部禁止添加 Claude 共同作者签名**：不要在提交信息末尾追加任何 Co-Authored-By 行，包括 Claude Opus 4.7 的 noreply 签名。

**提交命令禁止使用 here-string 写法**：不要使用带 at 符号包裹的多行提交信息写法；示例和实际命令都必须避免该符号。

### Step 5: 推送

```
git push -u origin {branch-name}
```

推送成功后报告：分支名、提交 hash、推送结果、MR 链接。

#### 生成 MR 链接

- 运行 `glab mr list --source-branch {branch-name} --output json` 检查是否已有 MR。
- 若已有 MR，直接输出现有 MR 链接（格式：`https://<host>/<project>/-/merge_requests/<iid>`）。
- 若尚无 MR，输出创建 MR 的链接：`https://<host>/<project>/-/merge_requests/new?merge_request[source_branch]={branch-name}&merge_request[target_branch]=main`
- `<host>` 和 `<project>` 从 `glab repo view --output json` 的 `web_url` 字段提取。
- MR 链接单独一行、醒目展示，方便直接点击操作。

## Forbidden

- 不要在 main/master/production/staging 分支上直接提交
- 不要一次推送多个不相关任务的改动，每次推送仅对应一个任务/主题
- 不要提交当前任务范围外的代码变更
- 不要使用 `git add -A` / `git add .`
- 不要使用 `--force` 推送
- 不要跳过 git hooks（`--no-verify`、`--no-gpg-sign`）
- 不要提交包含 secrets/credentials 的文件
