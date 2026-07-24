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

## Knowledge Retrieval

任务涉及以下关键词时，**先检索知识库**确保使用正确的设计模式：

| 触发关键词 | 检索命令 | 加载内容 |
|---|---|---|
| 工厂、Factory、管线、pipeline、单据生成、上架单生成、质检单生成、Adapt、LoadData、FillData、ValidateData、GenerateData、PersistData、五层 | `../scripts/search-knowledge.ps1 -Keyword "工厂"` | `backend/factory-pipeline.md` |

检索命中后：
1. 读取知识文件，理解五层分离的设计意图
2. **新写或重构 Factory 方法**：遵守 LoadData/FillData/ValidateData/GenerateData/PersistData 分层，GenerateData 不落库、ValidateData 纯内存
3. **仅修改现有逻辑**：参考现有方法的层次归属，不改动时跳过但保持后续新增一致

**其他关键词**：直接运行 `../scripts/search-knowledge.ps1 -Keyword "<用户意图关键词>"` 检索，命中则加载对应知识文件。

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

## Completion Verification

- 每次代码修改完成后，必须执行受影响项目的 build
- build 输出默认忽略 warning，只保留 error/fail/失败摘要
- error 必须清零；未执行 build 不得报告 `Done`

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
