# Multi Agent Planning Workflow

用于 Complex 任务的拆分、调度和执行顺序。

## 1. Trigger

仅 Complex 任务进入。

Complex 判断来源：

- `./complexity-decision.md`

## 2. Split Strategy

根据任务范围选择拆分方式。

### Single Domain

单终端、单业务域：

示例：

- 后端单模块重构
- 单页面调整

执行：

单 Agent。

---

### Multi Layer Backend

后端跨层修改：

默认拆分：

| Batch | Domain              | Strategy |
| ----- | ------------------- | -------- |
| P0    | Entity + Repository | 数据结构 |
| P1    | Service + DTO       | 业务逻辑 |
| P2    | Controller + API    | 接口契约 |

执行规则：

- P0 完成并验证后进入 P1
- P1 完成并验证后进入 P2

---

### Multi Terminal

涉及多个终端：

例如：

- Backend + Frontend
- Backend + PDA

按终端拆分：

| Agent          | Skill            |
| -------------- | ---------------- |
| Backend Agent  | wms-backend-dev  |
| Frontend Agent | wms-frontend-dev |
| PDA Agent      | wms-pda-dev      |

执行：

- 无文件依赖 → 可以并行
- 有接口依赖 → 按依赖顺序执行

## 3. Context Dependency

Agent 之间存在依赖时：

后续 Agent 可以读取前置 Agent 输出。

示例：

Entity Agent
↓
Repository Agent
↓
Service Agent
↓
Controller Agent

跨终端：

Backend API
↓
Frontend Consume

## 4. Execution Rules

- 每个 Agent 只负责分配范围
- Agent 不主动扩大任务范围
- 修改范围冲突时停止并回报
- 验证通过后进入下一阶段
- Verification Agent 只读，不修改代码

## 5. Completion

Coordinator 汇总：

- 已完成 Agent
- 验证结果
- 未解决风险
- 后续任务
