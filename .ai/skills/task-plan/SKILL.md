---
name: task-plan
description: "任务计划模式：基于知识边界拆包，生成结构化计划文件供 task-execute 执行。触发：任务计划、拆包、制定计划、task plan、/task-plan"
---

# Task Plan

## 核心安全规则

- 边界发现优先使用 `knowledge/INDEX.md` 关键词匹配，禁止读取业务代码（.cs、.vue、.ts、.sql、.py 等）
- 无知识索引时允许读取项目元数据（README.md、CLAUDE.md、package.json 等）辅助边界推断
- 每个包的 manifest 只含知识/规则/模式文件路径，不含业务代码路径
- 计划文件必须写入当前项目的 `plans/` 目录，文件名 `task-{YYYYMMDD}-{HHMM}-{slug}.md`
- 拆包数量 1-5 个，超过 5 个需告知用户确认后才能继续
- 计划生成后必须让用户确认，用户确认前不得写入文件

## 路由

| 命令 | 入口 | 说明 |
|------|------|------|
| 制定计划（默认） | `./workflow/planning.md` | Step 0-5 完整计划流程，先判 Simple/Complex |
| Simple 模式 | `./workflow/planning.md`（Simple 分支） | 单包直出，不拆批、不启 Agent |
| 知识边界发现 | `./workflow/boundary-discovery.md` | 从 INDEX.md 关键词匹配发现边界，含通用项目回退 |
| 拆包策略 | `./rules/decomposition.rules.md` | 粒度、合并、上限、排序规则 |
| 计划输出格式 | `./rules/plan-output.rules.md` | YAML frontmatter 字段规范 |
| 查看已有计划 | 直接列出 `plans/` 目录 | 按状态筛选、查看摘要 |

## 未匹配命令

若用户意图不在以上路由中（如仅查看已有计划、询问计划状态等），直接用通用知识处理。**不要**加载 workflow/ 和 rules/ 目录下的文件。
