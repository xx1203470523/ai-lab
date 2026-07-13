---
name: wms-backend-dev
description: "WMS 后端 .NET C# 开发终端：Entity/Repository/Service/Controller 四层。由 wms-dev 协调器路由或直接 /wms-backend-dev。仅涉及 AdminWebApi 时加载。"
shell: powershell
version: 1.0.0
---

# WMS Backend Dev — 后端终端 Skill

## Responsibility

负责：

- WMS 后端代码修改
- Entity 实体维护
- Repository 数据访问
- Service 业务编排
- Controller API实现
- 后端 Rules 执行

不负责：

- 前端实现
- PDA实现
- Agent任务拆分
- Git流程
- 数据库规范定义
- 业务规则设计

## Trigger

进入本 Skill：

- wms-dev 路由后端任务
- 用户指定 `/wms-backend-dev`
- 修改范围包含 `IMTC.WMS.AdminWebApi/`

## Domain Rules

Rules 仅用于代码设计、新增、修改、审查阶段。

根据实际影响层加载对应 Base Rules。

| 场景                               | Base Rule                                               |
| ---------------------------------- | ------------------------------------------------------- |
| 新增 Entity / 修改 Entity          | `../../rules/wms-backend-dev/entity.rules.md`           |
| 新增 Repository / 修改查询写入逻辑 | `../../rules/wms-backend-dev/repository.rules.md`       |
| 新增 Service / 修改业务编排        | `../../rules/wms-backend-dev/service.rules.md`          |
| 新增 Controller / 修改接口契约     | `../../rules/wms-backend-dev/controller.rules.md`       |

禁止：

- 任务分析阶段提前加载全部 Rules
- 与当前修改范围无关时读取 Rules

## Condition Packs

Condition Pack 仅在代码设计、新增、修改、审查时加载。

根据命中场景选择。

| 场景                       | Pack                                                                |
| -------------------------- | ------------------------------------------------------------------- |
| DTO/API契约变化            | `../../rules/wms-backend-dev/packs/service-dto.rules.md`            |
| 报表/分页/导出             | `../../rules/wms-backend-dev/packs/service-report.rules.md`         |
| 事务/多Repository写入      | `../../rules/wms-backend-dev/packs/service-transaction.rules.md`    |
| 库存/标签/质检/T100/状态流 | `../../rules/wms-backend-dev/packs/service-risk.rules.md`           |
| Repository查询优化         | `../../rules/wms-backend-dev/packs/repository-query.rules.md`       |
| Repository写入             | `../../rules/wms-backend-dev/packs/repository-write.rules.md`       |
| Entity字段约束             | `../../rules/wms-backend-dev/packs/entity-field.rules.md`           |
| Controller接口             | `../../rules/wms-backend-dev/packs/controller-setup.rules.md`       |
| API消费者影响              | `../../rules/wms-backend-dev/packs/controller-contract.rules.md`    |

禁止：

- Knowledge 查询阶段加载 Condition Pack
- 为了解业务背景加载 Rules

## Knowledge Discovery

Knowledge 用于补充已有业务背景、历史方案和领域经验。

Knowledge 与 Rules 独立。

需要检索：

- 不明确已有业务流程
- 修改已有领域逻辑
- 新增业务能力
- 状态流转变化
- 性能优化需要参考历史方案
- 需要了解已有实现经验

无需检索：

- 单纯代码格式调整
- 已明确代码位置的小范围修改
- 纯技术重构
- 编译修复

检索：

`~/.claude/scripts/search-knowledge.ps1`

关键词由 Agent 根据任务上下文生成。

执行：

```powershell
search-knowledge.ps1 -Keyword "<任务关键词>"
```

Knowledge 查询只返回领域参考文件。

禁止：

- Knowledge 查询触发 Rules 加载
- 使用 Knowledge 替代代码规范

## Loading Strategy

### Simple Task

执行：

1. 读取本 Skill
2. 读取影响层 Base Rules
3. 读取命中 Condition Packs
4. 实现任务

### Agent Task

由 Coordinator 提供：

- Task Scope
- Rules Path
- Allowed Path
- Forbidden Path

Agent 不主动：

- 扫描全部 Rules
- 扩大修改范围

## Project Boundary

允许修改：

- `IMTC.WMS.AdminWebApi/`

禁止修改：

- `IMTC.WMS.AdminUI/`
- `IMTC.WMS.PDA/`

跨端影响：

- 输出影响范围
- 等待协调器重新分配

## Escalation

发现：

- 需要修改其他端
- 需要新增未定义规则
- 业务范围扩大
- API契约影响消费者

必须：

1. 停止扩展
2. 输出影响范围
3. 等待重新分配
