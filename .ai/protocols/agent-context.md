# Agent Context Protocol

用于 Coordinator 向 Agent 传递执行上下文。

## Responsibility

负责：

- 定义 Agent 启动时必须拥有的信息
- 限制 Agent 读取范围
- 限制 Agent 修改范围
- 避免 Agent 重复分析上下文

不负责：

- 任务拆分策略
- Skill 路由
- 业务规则
- 技术实现规范

## Required Context

每个 Agent 启动时必须提供：

### Task

- Task Goal（任务目标）
- Task Type（任务类型）
- Current Phase（当前阶段）

### Execution Skill

- Terminal Skill（执行 Skill）
- Domain Scope（负责领域）

### Rules Context

必须明确：

- Base Rules Path（基础规则路径）
- Condition Packs Path（条件规则路径）

规则加载：

- 只读取指定 Rules
- 禁止扫描全部 Rules
- 禁止读取未命中的 Pack

### File Boundary

必须明确：

Allowed Read Path：

允许读取路径

Allowed Modify Path：

允许修改路径

Forbidden Path：

禁止读取和修改路径

### Verification

必须明确：

- Verification Requirement（验证要求）
- 完成标准
- 是否需要 build/test
- 是否需要数据库验证

## Context Passing Strategy

### Coordinator 已掌握的信息

Coordinator 可以直接传递：

- 任务目标
- 已判断复杂度
- 命中 Skill
- Rules 路径
- 文件范围

Agent 不需要重复分析。

### Agent 自主获取的信息

Agent 可以：

- 读取指定文件
- 查询指定范围代码
- 根据 Rules 实现

Agent 不可以：

- 扫描整个项目寻找可能影响文件
- 修改未分配路径
- 自行增加任务范围

## Scope Expansion

发现以下情况：

- 影响范围超过分配路径
- 发现新的业务模块
- 需要修改其他端
- 需要新增未定义规则

必须：

1. 停止修改
2. 输出 Scope Expansion
3. 等待 Coordinator 重新分配

## Agent Completion Output

必须返回：

- Changes（修改内容）
- Files（修改文件）
- Verification（验证结果）
- Risks（剩余风险）
