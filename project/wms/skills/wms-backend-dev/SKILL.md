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

根据修改层加载对应 Base Rules。

| Domain     | Base Rule                                      |
| ---------- | ---------------------------------------------- |
| Entity     | `../rules/wms-backend-dev/entity.rules.md`     |
| Repository | `../rules/wms-backend-dev/repository.rules.md` |
| Service    | `../rules/wms-backend-dev/service.rules.md`    |
| Controller | `../rules/wms-backend-dev/controller.rules.md` |

## Condition Packs

仅命中场景读取。

| 场景                       | Pack                                                    |
| -------------------------- | ------------------------------------------------------- |
| DTO/API契约变化            | `../rules/wms-backend-dev/service-dto.rules.md`         |
| 报表/分页/导出             | `../rules/wms-backend-dev/service-report.rules.md`      |
| 事务/多Repository写入      | `../rules/wms-backend-dev/service-transaction.rules.md` |
| 库存/标签/质检/T100/状态流 | `../rules/wms-backend-dev/service-risk.rules.md`        |
| Repository查询优化         | `../rules/wms-backend-dev/epository-query.rules.md`     |
| Repository写入             | `../rules/wms-backend-dev/repository-write.rules.md`    |
| Entity字段约束             | `../rules/wms-backend-dev/entity-field.rules.md`        |
| Controller接口             | `../rules/wms-backend-dev/controller-setup.rules.md`    |
| API消费者影响              | `../rules/wms-backend-dev/controller-contract.rules.md` |

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
