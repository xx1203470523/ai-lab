# AI-Lab Guide

本文件描述 AI-Lab 的使用方式。

---

# Project Lifecycle

## Step 1 - Attach Project

首次接入项目。

执行：

```powershell
attach-project.ps1
```

输入：

```text
Project Name
Project Path
Project Type
```

例如：

```text
wms
D:\Company\WMS
company
```

生成：

```text
registry

workspace

tool configuration
```

---

## Step 2 - Build Knowledge

创建项目知识库。

位置：

```text
projects/<project>/knowledge
```

例如：

```text
projects/wms/knowledge
```

内容：

```text
业务流程

数据库结构

模块职责

领域规则
```

---

## Step 3 - Build Skills

创建项目 Skill。

位置：

```text
projects/<project>/skills
```

例如：

```text
projects/wms/skills
```

---

Skill 分类：

### Generic Skill

位置：

```text
.ai/skills
```

要求：

```text
跨项目
自包含
```

---

### Project Skill

位置：

```text
projects/<project>/skills
```

允许依赖：

```text
knowledge
rules
workflows
```

---

## Step 4 - Build Agent Context

创建 Agent。

位置：

```text
projects/<project>/agents
```

例如：

```text
backend-agent

pda-agent

web-agent

review-agent
```

---

Agent 目标：

```text
Context Isolation
```

而不是：

```text
Automation
```

---

## Step 5 - Build Workflow

位置：

```text
projects/<project>/workflows
```

例如：

```text
instock

outstock

inventory
```

---

Workflow 负责：

```text
任务拆解

阶段控制

上下文组织
```

---

# Skill Design Rules

所有 Skill 必须：

* 单一职责
* 可复用
* 可组合
* 可维护

---

避免：

```text
万能 Skill
```

---

推荐：

```text
impact-analysis

feature-development

git-worktree

code-review
```

---

# Hook Design Rules

当前阶段：

只做 Prompt Routing。

---

例如：

```text
入库
```

自动加载：

```text
receipt knowledge

instock workflow

wms-dev skill
```

---

不要提前设计复杂 Hook。

优先验证价值。

---

# Agent Design Rules

Agent 是：

```text
Context Profile
```

---

不是：

```text
Auto Agent
```

---

Agent 负责：

```text
限定边界

减少污染

提高专注度
```

---

# Worktree Rules

统一使用：

```text
工具目录/worktree
```

例如：

```text
.claude/worktree
.codex/worktree
.agent/worktree
```

---

禁止：

```text
AI-Lab/worktree
```

---

因为：

Worktree 属于运行时状态。

---

# Registry Rules

Registry 是唯一入口。

项目相关配置统一维护于：

```text
registry
```

---

Skill

Workflow

Agent

Hook

不得硬编码路径。

---

统一通过 Registry 解析。

---

# Engineering Rules

允许新增：

* Skill
* Rule
* Workflow
* Knowledge

---

谨慎新增：

* Bootstrap
* Hook

---

禁止频繁新增：

* Framework Layer
* Factory Layer
* Orchestrator Layer

---

原则：

```text
先验证

后抽象

最后固化
```

---

# Current Focus

未来 3 个月重点：

1. WMS Knowledge
2. wms-dev
3. git-worktree
4. Agent Context
5. Hook Routing

---

衡量标准：

不是目录是否完美。

而是：

```text
是否每天都在使用

是否持续产生收益

是否持续被迭代
```
