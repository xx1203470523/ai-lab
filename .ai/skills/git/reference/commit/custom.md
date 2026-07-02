# Git Push 个人配置

## 提交规范

### WMS项目

**标题格式**：`type(scope): 中文简短总结`

**正文格式**：使用结构化 Markdown 章节，保持中文、简洁、可追溯：

### Summary

- 改动概述及原因

## Changed Files

- `path/to/file` - 相关改动说明

- `## Summary` 必填，其余章节按需添加
- 小改动可只保留 `## Summary`
- 不要声称运行了实际未执行的验证步骤

**提交备注尾部禁止添加 Claude 共同作者签名**：不要在提交信息末尾追加任何 Co-Authored-By 行，包括 Claude Opus 4.7 的 noreply 签名。

**提交命令禁止使用 here-string 写法**：不要使用带 at 符号包裹的多行提交信息写法；示例和实际命令都必须避免该符号。

## 其他项目

- 按默认规范