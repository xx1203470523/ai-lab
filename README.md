# AI-Lab

统一管理个人 AI 工程化资产。

目标：

* 脱离 Claude Code、Codex 等具体工具
* 脱离具体项目
* 统一维护 Skill、Rule、Workflow、Knowledge
* 支持多项目、多会话、多 Worktree 开发
* 支持未来 Agent 化演进

---

## Design Principles

### 1. AI-Lab 是资产中心

AI-Lab 管理：

* Rules
* Skills
* Workflows
* Hooks
* Templates
* Bootstrap
* Registry

而不是管理项目代码。

---

### 2. 项目是消费者

项目负责：

* 业务知识
* 业务规则
* 业务 Workflow
* Agent Context

AI-Lab 负责：

* 通用能力
* 工程化能力
* 自动化能力

---

### 3. Context First

Agent 的核心目标：

不是自动执行。

而是：

* 隔离上下文
* 限制职责范围
* 提升输出质量

当前阶段：

```text
Agent = Context Profile
```

---

### 4. Tool Agnostic

不绑定：

* Claude Code
* Codex
* Gemini
* OpenCode

通过 Adapter 适配。

---

## Directory Structure

```text
AI-Lab
│
├─ .ai
│  │
│  ├─ adapters
│  ├─ bootstrap
│  ├─ hooks
│  ├─ journal
│  ├─ rules
│  ├─ skills
│  ├─ templates
│  └─ workflows
│
├─ registry
│
├─ projects
│  │
│  ├─ wms
│  ├─ trade
│  └─ voxcpm
│
└─ docs
```

---

## Responsibilities

### .ai/adapters

工具适配层。

例如：

```text
claude
codex
gemini
```

负责：

* 初始化
* 配置生成
* Hook 接入
* Session 管理

---

### .ai/bootstrap

初始化脚本。

例如：

```text
attach-project.ps1

sync-project.ps1
```

---

### .ai/hooks

Prompt 注入。

关键词路由。

知识自动加载。

---

### .ai/rules

通用规则。

例如：

```text
coding-style

git

architecture

communication
```

---

### .ai/skills

通用 Skill。

要求：

* 自包含
* 可跨项目复用
* 不依赖业务知识

例如：

```text
impact-analysis

git-worktree

code-review

feature-development
```

---

### .ai/workflows

通用工作流。

例如：

```text
feature-development

bug-fix

refactor
```

---

### registry

项目注册中心。

负责：

* 项目发现
* 路径解析
* Tool 配置

---

### projects

业务知识中心。

例如：

```text
projects/wms
```

存放：

```text
knowledge
skills
rules
workflows
agents
```

---

## Worktree Policy

Worktree 属于运行时状态。

不属于知识资产。

统一放置于工具目录。

例如：

```text
.claude/worktree
.codex/worktree
.agent/worktree
```

AI-Lab 不直接管理 Worktree。

AI-Lab 仅提供：

```text
git-worktree Skill
```

---

## Current Priorities

P0

* WMS Knowledge
* wms-dev
* git-worktree

P1

* Registry
* Attach Project
* Agent Context

P2

* Hook Routing
* Knowledge Injection

P3

* Task Decomposition

P4

* Cross Project Validation

---

## Long-Term Goal

建立一套：

* 可迁移
* 可扩展
* 可复用

的个人 AI 工程化体系。

通过真实业务持续验证。

避免为了工程化而工程化。

---

## AI-Lab 是什么？

本质上：

你
而不是
项目

里面沉淀的是：

你的思考方式
你的开发方法论
你的工作流
你的知识体系