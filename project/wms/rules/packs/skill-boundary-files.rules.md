---
description: "Skill 体系各文件类型职责边界和迁移位置规则。"
---

# Skill Boundary Files Rules

## 触发

- 新建或重构 Skill 文件结构。
- 审查内容是否放错文件类型。
- 迁移 `SKILL.md`、Rules、workflows、references、scripts 或 EXAMPLES 内容。

## 文件职责

| 文件类型 | 只写 | 不写 |
|---|---|---|
| `SKILL.md` | Trigger、Responsibilities、Decision Flow、Loading Strategy、索引 | 规则正文、长流程、教程、示例集合、脚本实现 |
| `EXAMPLES.md` | 示例输入、示例输出、边界案例 | 必须/禁止/默认规则、执行流程、规范来源 |
| Rules / Packs | 必须/禁止/允许、最终形态约束、稳定职责边界 | 执行流程、搜索策略、Agent 调度、输出模板、示例集合 |
| workflows | 流程、状态流转、任务拆分、验证顺序 | 强约束唯一来源、命名规范正文、大段示例 |
| references | 背景、历史决策、迁移资料、辅助说明 | 强约束、执行流程、默认加载要求 |
| scripts | 授权后执行的固定参数化自动化 | 规则职责、默认执行语义、一次性命令沉淀 |

## 目录与命名

- Skill 入口固定为 `SKILL.md`。
- Skill 示例文件固定为 `EXAMPLES.md`。
- Base Rules 位于 `rules/<domain>.rules.md`。
- Conditional Rule Packs 位于 `rules/packs/<domain>-<topic>.rules.md`。
- workflows / references / scripts 下文件使用 kebab-case。
- `workflows/`、`references/`、`scripts/` 只有实际需要时创建。

## 迁移矩阵

- 规则正文 → Rules / Packs。
- 执行流程 → workflows。
- 示例 → `EXAMPLES.md`。
- 历史背景或迁移资料 → references。
- 固定可参数化操作 → scripts。
