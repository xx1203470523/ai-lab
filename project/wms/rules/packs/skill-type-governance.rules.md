---
description: "Governance Skill 的治理范围、个人级边界和非业务实现规则。"
---

# Skill Type Governance Rules

## 触发

- 生命周期判断后目标为 Governance Skill。
- 任务治理 Skill / Rules / workflows / references / scripts / EXAMPLES 的结构、生命周期、加载或审查边界。
- 目标 Skill 类似 `skill-builder`，负责管理个人 Skill 体系。

## 职责边界

- Governance Skill 管理结构、生命周期、职责边界、加载策略和审查流程。
- Governance Skill 不执行业务代码开发。
- Governance Skill 不替代具体领域 Skill 或 Tool Skill。
- Governance Skill 不把业务规范写成治理规则。

## 个人级默认

- 默认治理 `~/.claude/skills/` 下个人级 Skill。
- 不生成项目级 shared skill，除非用户明确要求。
- 若目标是项目级 shared rules、agents、hooks 或 skills，先遵守对应项目边界规则。

## 输出边界

- 可以设计目录结构、加载策略、规则包和 workflow 拆分。
- 可以审查污染、过重和引用问题。
- 不把 references、EXAMPLES、scripts 当规则来源。
