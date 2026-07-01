---
description: "Review 模式下只读审查、输出粒度和读取范围的条件规则。"
---

# Skill Mode Review Rules

## 触发

- 用户要求审查、评估、检查是否过重、检查是否污染或只输出建议。
- 用户明确表示不生成文件或不执行重构。

## Review 边界

- Review 默认只读，不生成文件。
- Review 不执行 scripts。
- Review 不自动转为 Refactor；除非用户继续要求实施。
- Review 只读取完成判断所需的最小文件集。

## 读取范围

- 先读取目标 `SKILL.md` 和 Base Rules。
- 按需读取 workflows、packs、EXAMPLES、references 或 scripts。
- 只有审查示例污染时读取 `EXAMPLES.md`。
- 只有审查脚本职责或授权策略时读取 scripts。

## 输出要求

- 按问题粒度输出。
- 每个问题说明位置、问题类型、影响、建议迁移位置。
- 区分阻塞问题与可后续优化。
- 对“不需要拆分 / 不需要新增”的判断也要说明理由。

## 规模启发

- `SKILL.md` 超过 80 行时，审查是否混入规则或流程。
- Base Rules 超过 120 行时，审查是否混入模式、类型或边界细则。
- 单个 Skill 包含 5 个以上 workflow 时，审查是否职责过宽；不是自动拆 Skill。
