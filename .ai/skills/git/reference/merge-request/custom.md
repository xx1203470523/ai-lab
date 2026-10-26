# Merge Request 信息准备契约

本文件定义 Push workflow 如何准备 MR 信息。不负责创建、更新、审批、分配 reviewer、添加 label 或合并 MR。

## 格式优先级

按顺序取第一个适用的来源：

1. 用户明确要求的格式或语言
2. 仓库里的 MR 模板
3. 本文件的通用 fallback

项目既有章节及顺序优先于 fallback，不得另行发明第二套格式。

## 建议标题

优先用当前任务的 commit subject；没有就用符合用户需求的简短 `type(scope): summary`。
代码标识符、分支名和命令保持原样。

## 建议正文

正文只能用以下来源能证明的内容：

- 用户需求和验收条件
- 目标分支与源分支之间的提交记录
- 目标到源的 diff 摘要
- 本次 workflow 实际执行的检查
- 明确排除项或有意保持不变的范围

通用 fallback：

```markdown
## Summary

- <改动目的和受影响流程>

## Changed Files

- `<path>` - <具体改动>

## Verification

- <实际执行的检查，或明确说明未执行>
```

只有任务改变用户可见行为或业务行为且已有具体场景时，才加 `## Test Scenarios`；
只有存在明确排除项且有助于 reviewer 理解范围时，才加 `## Exclusions`。
小改动可只保留 `## Summary` 和 `## Verification`，不保留空章节。

## 质量与安全

- 说明改了什么以及为什么改，不粘贴大段原始 diff
- 不得声称执行过未执行的构建、测试、审查或部署
- 不得包含未提交的无关变更
- 不得包含密钥、令牌或无关私密信息
- 不得追加 `Co-Authored-By:` 或 `🤖 Generated with` 行
