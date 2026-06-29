---
name: skill-core-build
description: 生成或优化纯功能型 Core Skill（工具/操作流程类），不包含业务逻辑
---

# Skill Core Build

## 1. 目标

用于生成或优化"Core Skill"。

Core Skill 定义：
- 纯功能型技能（如 git、文件处理、环境操作）
- 描述可执行流程
- 不包含业务逻辑（如电商、金融、库存规则）

## 2. 触发方式

- `/skill-core-build 生成 <功能描述>`
- `/skill-core-build 优化 <skill名>`
- 用户描述：新建 skill、优化 skill、写一个 git / 文件 / 工具类操作

## 3. 输出路径

**唯一路径**：`.ai/core/skills/<skill-name>/`，不允许生成到其他位置。

必须生成：

```
.ai/core/skills/<skill-name>/
├── SKILL.md
└── examples.md
```

按需生成（不允许空目录）：
- reference/
- scripts/
- config/
- assets/

生成后注册到 Claude Code：

```powershell
.ai/core/skills/sync.ps1 install
```

## 4. 新建 Skill 流程

### 1）需求理解

提取：
- 输入是什么
- 输出是什么
- 核心操作步骤是什么

### 2）流程设计

将需求拆解为可执行步骤：

要求：
- 每一步必须可执行
- 不允许抽象描述
- 不允许业务推理

### 3）生成方案（1-2 个即可）

每个方案必须包含：
- 执行流程
- 优缺点
- 推荐方案（必须标注一个）

### 4）确认后生成文件

生成：

**SKILL.md**（必须）：
- name
- description
- execution flow（核心）
- input / output
- constraints

要求：极简、结构化、不写解释。

**examples.md**（必须）：
至少 3 个使用例子：
- 正常情况
- 边界情况
- 错误/异常情况

### 5）验证

```bash
find .ai/core/skills/<name> -type f
```

```powershell
.ai/core/skills/sync.ps1 install   # 创建 junction 到 ~/.claude/skills/
```

## 5. 优化 Skill 流程

1. 完整读取目标 Skill 所有文件
2. 按执行流程逐步 dry-run 检查：
   - 是否每一步可执行
   - 是否缺输入/输出
   - 是否存在冗余步骤
   - 是否逻辑跳跃
3. `EnterPlanMode` 输出优化方案（问题 → 修改方式 → 影响）
4. 用户确认后修改

## 6. 核心约束

### Core Skill 只允许

- git 操作
- 文件操作
- 系统/环境操作
- CLI 工具流程
- 日志/调试类操作

### 禁止

- 业务逻辑（金融/电商/库存）
- 策略分析
- 行业判断
- 长解释内容
