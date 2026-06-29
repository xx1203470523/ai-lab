---
name: git-push
description: 当用户输入 "/git-push" 或说"推送"、"提交并推送"、"git push"、"commit and push"时触发。自动检查分支、同步远端、分析改动生成 Conventional Commits 提交信息、暂存提交推送。
---

# Git Push 自动化

## 固定路径

- 项目配置：`~/.claude/skills/git-push/reference/custom.md`
- 默认主分支：`master`

## 前置

1. 读取 `reference/custom.md` 获取用户信息和提交规范偏好。未配置的字段回退到 `git config`。
2. 确认当前目录是 git 仓库根目录。

## 执行步骤

### 1. 分支检查

```bash
git branch --show-current
```

- 当前在 `master`/`main` → 提示"正在主分支上直接提交"，要求用户确认。取消则退出。
- 当前在 feature 分支 → 直接继续。

### 2. 远端同步

```bash
git fetch origin
```

**feature 分支**：
```bash
# 先检查本地 master 是否落后
git rev-list --count master..origin/master
```
- 落后 > 0 → `git checkout master && git pull && git checkout -` 更新本地 master
```bash
# 再检查 feature 是否落后 origin/master
git rev-list --count HEAD..origin/master
```
- 落后 > 0 → 提示"当前分支落后 origin/master X 个提交，是否 rebase？"
  - 确认 → `git rebase origin/master`
  - 冲突 → 列出冲突文件，停止，等用户处理
  - 取消 → 跳过（提醒有合并冲突风险）

**master 分支**（用户已确认）：
```bash
git pull --rebase origin master
```

### 3. 分析改动

```bash
git status --porcelain
git diff --staged --stat
git diff --stat
```

根据改动内容和 `custom.md` 中的规范生成 Conventional Commits 格式的 commit message：

```
<type>(<scope>): <中文简述>

<详细说明>
- python: 改动项1
- web: 改动项2
- 无归属子项目的改动则不加前缀
```

每条 `- ` 行前缀用子项目名（python/web/webapi/docs/config），无归属则空着。

展示改动文件清单 + 生成的 message，用户确认/修改。

### 4. 暂存 + 提交

展示改动文件清单，用户确认范围后暂存：

```bash
git add <file1> <file2> ...    # 按确认范围
# 或用户明确"全部"时：
git add -A
```

```bash
git commit -m "..."
```

提交失败则报告错误并停止。

### 5. 推送

```bash
git push origin <branch>
```

| 结果 | 处理 |
|------|------|
| 成功 | ✅ 显示 commit hash 和推送结果 |
| 远端有新提交 | ⚠️ 提示先 rebase origin/master 再推送 |
| 权限/认证失败 | ⚠️ 提示检查凭据 |
| 其他错误 | ⚠️ 报告原始错误，等待用户决策 |

### 6. 完成

推送成功后结束。不切回 master，不额外拉取。

## 安全规则

- master 分支提交必须确认
- rebase 冲突必须停止，不做自动合并
- 任何 git 命令失败不继续下一步
- 不执行 `--force` push，除非用户明确要求
- 提交信息不添加 `Co-Authored-By:` 行
