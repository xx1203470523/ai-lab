---
description: "Skill 体系职责污染、过重和新增项必要性审查规则。"
---

# Skill Boundary Pollution Rules

## 触发

- 用户要求审查污染、是否过重、是否该拆分。
- Review 或 Refactor 需要判断内容迁移位置。
- 新增 Skill / workflow / rule pack / script / reference 前需要必要性审查。

## 污染类型

- Skill 污染：`SKILL.md` 混入规则正文、长流程、教程、示例集合或脚本实现。
- Rules 污染：Rules / Packs 混入 workflow、搜索策略、Agent 调度、输出模板或示例集合。
- Workflow 污染：workflow 混入最终形态强约束、命名规范正文或大段示例。
- Reference 污染：references 混入必须 / 禁止 / 默认等强约束或执行流程。
- Script 污染：scripts 被描述为默认自动执行、绕过授权、承担规则职责或无参数化价值。
- Example 污染：EXAMPLES 被当作规范来源、加载入口或执行流程来源。

## 过重审查

- `SKILL.md` 超过 80 行时，审查是否混入规则或流程。
- Base Rules 超过 120 行时，审查是否混入模式、类型、边界或污染细则。
- 单个 Skill 包含 5 个以上 workflow 时，审查职责是否过宽；不自动拆 Skill。

## 新增项必要性

- 新增 Skill：检查是否与现有 Skill 职责重复，是否违反数量控制。
- 新增 workflow：检查是否只是单一步骤，是否可合并到现有 workflow。
- 新增 Rule Pack：检查是否本可进入 Base Rules 或现有 Pack。
- 新增 script：检查是否具备固定、可参数化、可重复执行价值。
- 新增 reference：检查是否只是通用知识或 AI 已知内容。
- 新增层级必须解决已发生的重复、维护成本或职责冲突。

## 审查输出

- 位置：文件路径或章节。
- 污染类型：Skill / Rules / Workflow / Reference / Script / Example。
- 具体问题：越界承载了什么。
- 建议迁移位置：Rules、workflow、EXAMPLES、reference、script 或删除。
- 严重程度：阻塞 / 可后续优化。
