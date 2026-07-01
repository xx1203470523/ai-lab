---
description: "Create 模式下新增 Skill、Rule Pack、workflow、reference 或 script 的条件规则。"
---

# Skill Mode Create Rules

## 触发

- 用户要求新增 Skill、Rule、Rule Pack、workflow、reference、script 或 EXAMPLES。
- 生命周期判断结论包含 Create。

## 新建 Skill 条件

- 只有职责边界、生命周期、触发场景均独立，并且预计持续扩展时，才新建 Skill。
- 属于现有职责范围、仅新增少量规则、单个 workflow、单个 script、单个 reference 或单个业务模块时，扩展现有 Skill。
- 新建前必须说明为什么不能落到 Existing Skill、workflow、rule pack、script 或 reference。

## 新增项落点

- 稳定强约束进入 Base Rules 或 Conditional Rule Pack。
- 复杂流程、状态流转、任务拆分、验证顺序进入 workflow。
- 固定、可参数化、可重复执行的 Tool 操作进入 script。
- 背景、历史决策、迁移资料进入 reference。
- 示例输入、示例输出、边界案例进入 `EXAMPLES.md`。

## 新 Skill 最小文件

- 新增 Skill 必须包含 `SKILL.md` 和 `EXAMPLES.md`。
- `workflows/`、`references/`、`scripts/` 只有实际内容时才创建。
- 禁止默认生成空目录。

## Frontmatter

Skill 必须包含：

```yaml
---
name: skill-name
description: "触发场景和职责"
shell: powershell
version: 1.0.0
---
```

- 目录名与 `name` 字段使用 kebab-case，且保持一致。
- Rules 建议使用 `description`，如需限定路径使用复数 `paths`。

## README

- 新增或重构后可同步更新 `skills/README.md`。
- README 只做索引，不承载规则正文。
