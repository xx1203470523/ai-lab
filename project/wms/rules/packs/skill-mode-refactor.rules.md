---
description: "Refactor 模式下瘦身、迁移、拆分和保留语义的条件规则。"
---

# Skill Mode Refactor Rules

## 触发

- 用户要求重构、瘦身、拆分、迁移、优化加载或调整职责边界。
- 生命周期判断结论是 Refactor。

## 重构优先级

- 优先瘦身入口和默认加载内容。
- 优先拆模块、拆 workflow、拆 rule pack；最后才拆 Skill。
- 只有职责边界发生根本变化时才拆 Skill。
- 不为了统一风格、未来可能复用或抽象偏好而拆分。

## 语义保留

- 不无故删除已有有效语义。
- 强约束迁移到 Rules / Packs。
- 流程迁移到 workflows。
- 示例迁移到 `EXAMPLES.md`。
- 背景、历史说明、迁移资料迁移到 references。
- 固定可参数化操作迁移到 scripts。

## Base Rules 瘦身

- Base Rules 只保留所有场景都必须默认加载的底线。
- 模式规则、类型规则、文件边界、加载策略、污染审查、知识边界应拆到 packs。
- Base Rules 超过 120 行时必须审查是否又变成治理手册。

## Workflow 与 Rules 去重

- workflow 只写流程和读取顺序。
- pack 只写必须 / 禁止 / 允许 / 最终形态约束。
- 发现 workflow 与 pack 重复时，规则留在 pack，流程留在 workflow。

## 验证要求

- 检查默认 `@` 加载是否只剩 Base Rules。
- 检查新增路径是否存在。
- 检查 `SKILL.md` 是否保持轻入口。
- 检查 EXAMPLES、references、scripts 是否未成为规则来源。
