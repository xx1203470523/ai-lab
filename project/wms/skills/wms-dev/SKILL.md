---
name: wms-dev
description: "WMS 开发协调入口：负责任务分析、复杂度判断、终端 Skill 路由、复杂任务编排。具体代码实现由 wms-backend-dev / wms-frontend-dev / wms-pda-dev 执行。"
shell: powershell
version: 1.0.0
---

# WMS Dev — 开发协调器

## Responsibility

负责：

- WMS 开发任务入口
- 任务复杂度判断
- 终端 Skill 路由
- Complex 任务拆分
- Agent 编排协调
- 执行结果汇总

不负责：

- 具体业务代码实现
- 后端/前端/PDA技术规范定义
- 业务规则定义
- 代码模板维护

## Trigger

- 新增或修改 WMS 任何端（后端/前端/PDA）功能
- 跨端联动或跨层联动
- 用户未指定终端技能，需要协调器分析并路由

## Workflow

执行流程：

### Complexity Decision（任务复杂度分析）

读取：

`./workflow/complexity-decision.md`

判断：

- Simple
- Complex

### Complex Planning（复杂任务编排）

Complex 任务读取：

`./workflow/multi-agent-planning.md`

负责：

- Agent 拆分
- 执行顺序
- 依赖关系

## Skill Routing

| 影响端       | 终端 Skill         | 项目路径                |
| ------------ | ------------------ | ----------------------- |
| 后端 .NET C# | `wms-backend-dev`  | `IMTC.WMS.AdminWebApi/` |
| 前端 AdminUI | `wms-frontend-dev` | `IMTC.WMS.AdminUI/`     |
| PDA 手持端   | `wms-pda-dev`      | `IMTC.WMS.PDA/`         |

## Rule Loading

终端 Skill 负责加载具体 Rules。

wms-dev 只负责传递：

- 目标 Skill
- 任务范围
- 影响范围
- Workflow上下文

禁止：

- 在本 Skill 内复制 Rules 内容
- 自行维护业务规则

## Agent

Agent 任务协议：

`../../protocols/agent-task-packet.md`

Agent 执行协议：

`../../protocols/agent-context.md`

Agent 拆分：

`./workflow/multi-agent-planning.md`

## Task Status

- `Pending`：待开始
- `Running`：执行中
- `Verifying`：验证中
- `Done`：完成
- `Blocked`：阻塞原因 + 需确认内容 + 建议下一步

## Boundary

本 Skill：

负责：

- 分析
- 路由
- 编排
- 汇总

本 Skill 不负责：

- 后端代码实现
- 前端代码实现
- PDA代码实现
- Git流程
- 数据库规范
- 业务规范
