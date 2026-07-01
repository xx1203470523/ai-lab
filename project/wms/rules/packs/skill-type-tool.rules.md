---
description: "Tool Skill 的参数收集、脚本化和授权执行条件规则。"
---

# Skill Type Tool Rules

## 触发

- 生命周期判断后目标为 Tool Skill。
- 任务涉及命令编排、脚本、Git、导出、清理、发布、日志等跨项目工具流程。
- 用户要求设计或审查 scripts。

## 职责边界

- Tool Skill 负责参数收集、模式路由、执行前确认和结果说明。
- workflow 负责参数校验、流程编排、失败处理和脚本调用顺序。
- script 负责固定命令执行。
- Tool Skill 不承载通用命令教程。

## Script 优先原则

当流程同时满足以下条件时，优先设计为 script：

- 步骤高度固定。
- 输入可参数化。
- 可重复执行。
- 不依赖 AI 根据上下文推理判断。

判断：

- 每次步骤完全相同 → script。
- 需要 AI 根据上下文决策 → workflow。
- 固定命令 + 少量决策 → workflow 编排 + script 执行。

## Script 边界

- scripts 不默认执行。
- scripts 只在用户明确授权后使用。
- scripts 不绕过 Rules、Gate、权限或用户确认。
- 一次性命令不应沉淀成 skill script。
- scripts 不承担规则职责。
