# 计划文件模板

```markdown
---
plan_id: task-YYYYMMDD-HHMM-{slug}
created: YYYY-MM-DDTHH:MM:SS
status: pending
mode: complex
project: {project}
description: "{一句话任务描述}"
knowledge_sources:
  - ai-lab://knowledge/domains/{domain}.md
  - ai-lab://project/{project}/knowledge/INDEX.md
packages:
  - id: pkg-01
    name: "{层级}：{知识域} + {具体工作}"
    skill: "{终端技能名，如 wms-backend-dev；无技能时填空字符串}"
    domain: "{知识域名称}"
    layer: data
    status: pending
    depends_on: []
    manifest:
      knowledge:
        - "project/{project}/knowledge/{category}/"
      rules:
        - "project/{project}/skills/{skill}/rules/{domain}.rules.md"
      packs:
        - "project/{project}/skills/{skill}/rules/packs/{pack}.rules.md"
      patterns: []
    boundaries:
      allow_read:
        - "{项目代码目录}/"
      allow_write:
        - "{项目代码目录}/"
      forbid:
        - "{其他端目录}/"
    contract:
      in_scope: "{明确在范围内的工作}"
      out_of_scope: "{明确排除的工作}"
      expected_files: "{N}-{M}"
      stop_condition: "{何时触发范围扩大升级}"
  - id: pkg-02
    name: "{层级}：{知识域} + {具体工作}"
    domain: "{知识域名称}"
    layer: business
    status: pending
    depends_on:
      - pkg-01
    manifest:
      knowledge:
        - "project/{project}/knowledge/{category}/"
      rules:
        - "project/{project}/skills/{skill}/rules/{domain}.rules.md"
      packs:
        - "project/{project}/skills/{skill}/rules/packs/{pack}.rules.md"
      patterns: []
    boundaries:
      allow_read:
        - "{项目代码目录}/"
      allow_write:
        - "{项目代码目录}/"
      forbid:
        - "{其他端目录}/"
    contract:
      in_scope: "{明确在范围内的工作}"
      out_of_scope: "{明确排除的工作}"
      expected_files: "{N}-{M}"
      stop_condition: "{何时触发范围扩大升级}"
total_packages: 2
---

# Task Plan: {任务描述}

## 复杂度评估

- 领域数: {N}
- 层数: {M} (data / business / interface)
- 跨端: 是 / 否
- 文件预计: {min}-{max}
- 结论: Simple → {N} packages / Complex → {N} packages

## 知识边界来源

| 索引 | 文件 | 命中 |
|------|------|------|
| knowledge/INDEX.md | {文件} | {匹配说明} |
| project/{project}/knowledge/INDEX.md | {文件} | {匹配说明} |

## 包依赖图

```
{ASCII 依赖图，如:}
pkg-01 (data) ──→ pkg-02 (business) ──→ pkg-03 (interface)
```

## 任务日志

| 包 | 状态 | Agent | 开始时间 | 完成时间 | 备注 |
|----|------|-------|----------|----------|------|
| pkg-01 | pending | - | - | - | - |
| pkg-02 | pending | - | - | - | - |
```
