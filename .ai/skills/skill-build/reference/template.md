# Skill 完整模板

## 目录结构

```
<skill-name>/
├── SKILL.md           # 必 — Frontmatter + 执行流程
├── examples.md        # 按需 — 至少 3 个典型场景
├── reference/         # 按需 — 配置/自定义模板
├── scripts/           # 按需 — 辅助脚本（.ps1/.sh/.py）
├── assets/            # 按需 — 静态资源/图标
├── logs/              # 按需 — 日志输出目录
└── config/            # 按需 — 运行时配置
```

## SKILL.md 模板

````markdown
---
name: <skill-name>
description: <触发条件 + 一句话功能>
---

## 固定路径

- xxx：`<路径>`

## 前置

1. xxx
2. xxx

## 执行步骤

### 1. xxx

```bash
command
```
````

- 条件A → 处理
- 条件B → 处理

### 2. xxx

...

### 3. xxx

...

## 安全规则

- xxx
- xxx

```

```
