# 提示词工程

> 最后更新: 2026-07-02

## Token 优化

- 不写 AI 已知的内容（通用知识由模型自带）
- 内联核心规则到 SKILL.md，减少文件 IO 次数
- 使用 Grep 检索知识库，命中才加载，miss 跳过（miss 成本 = 一次 Grep）
- statusLine hook 不消耗 token（终端本地渲染）

## 准确性

- 核心安全规则直接写在 SKILL.md 开头（始终在上下文）
- 用脚本替代推理：确定性检查用 PowerShell 脚本，返回结构化结果
- 明确禁止项（禁止 force push、禁止 --no-verify）比"建议"有效
