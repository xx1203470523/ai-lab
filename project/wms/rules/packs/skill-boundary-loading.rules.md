---
description: "Skill 体系引用、按需加载和渐进式披露规则。"
---

# Skill Boundary Loading Rules

## 触发

- 用户要求调整引用关系、加载策略或按需加载。
- 审查 `@` 默认加载是否过多。
- 设计 workflow、rule pack、reference、EXAMPLES 或 script 的加载方式。

## 引用规则

- Skill → Base Rules：可用 `@../rules/*.rules.md`。
- Skill → workflows：用普通相对路径列出，例如 `workflows/<name>.md`。
- Skill → Rule Packs：用普通相对路径列出，例如 `../rules/packs/<name>.rules.md`。
- references、EXAMPLES、scripts 只用普通路径列出。
- 禁止 `@workflows/...`、`@../rules/packs/...`、`@references/...`、`@scripts/...`、`@EXAMPLES.md`。
- 禁止引用不存在的文件。

## 渐进式披露

加载顺序应为：

```text
SKILL.md
↓
Base Rules
↓
按任务模式读取 workflow / mode pack
↓
按 Skill 类型读取 type pack
↓
按职责边界读取 boundary pack
↓
必要时读取 EXAMPLES / references / scripts
```

## 按需读取

- Conditional Rule Packs 命中后读取，未命中不得默认加载。
- workflows 按任务模式或决策分支读取。
- references / EXAMPLES / scripts 不默认读取。
- scripts 只有用户明确授权后才可执行。
- 为避免上下文膨胀，不得在入口一次性列出必须读取全部 packs 或 workflows。
