# STOP_OVER_ENGINEERING

## Purpose

本文件用于防止 AI-Lab 演变为新的开发项目。

AI-Lab 的目标是提升开发效率。

不是成为主要开发对象。

---

# 第一原则

业务优先于工程化。

出现以下情况时：

- Trade 功能未完成
- WMS 开发任务未完成
- 当前需求尚未交付

优先完成业务。

禁止继续优化 AI-Lab。

---

# 第二原则

发现问题先记录。

不要立即设计。

流程：

发现问题

↓

记录到 Journal

↓

连续出现 3 次以上

↓

再考虑抽象

---

# 第三原则

先人工执行。

后自动化。

满足以下条件才能自动化：

- 连续执行 ≥ 5 次
- 步骤稳定
- 预期长期存在

否则禁止创建：

- Skill
- Hook
- Workflow
- Script

---

# 第四原则

一个问题只允许一层抽象。

允许：

Feature Development Workflow

禁止：

Feature Workflow Factory

Workflow Generator

Workflow Builder

Workflow Registry

---

# 第五原则

新增前必须回答：

1. 解决了什么问题？
2. 这个问题最近出现了几次？
3. 不做会怎样？
4. 能否先手工完成？
5. 三个月后还会存在吗？

如果回答不明确：

禁止新增。

---

# 第六原则

优先级排序

P0

业务开发

- WMS
- Trade
- VoxCPM

P1

知识沉淀

- Knowledge
- Journal

P2

Skill

P3

Workflow

P4

Hook

P5

目录结构优化

P6

框架重构

---

# 第七原则

每周检查

统计：

本周新增：

- Skill
- Rule
- Workflow

统计：

本周完成：

- WMS功能
- Trade功能
- VoxCPM功能

如果：

工程化产出 > 业务产出

说明开始偏离目标。

---

# 第八原则

AI-Lab 不是产品。

AI-Lab 是工具。

工具服务业务。

业务不服务工具。

---

# 当前阶段目标

仅允许重点建设：

- WMS Knowledge
- wms-dev
- git-worktree
- Agent Context
- Hook Routing

除此之外的新方向：

全部进入 Journal。

暂不实施。