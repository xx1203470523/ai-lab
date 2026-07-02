---
name: wms-backend-dev
description: "WMS 后端 .NET C# 开发终端：Entity/Repository/Service/Controller 四层。由 wms-dev 协调器路由或直接 /wms-backend-dev。仅涉及 AdminWebApi 时加载。"
shell: powershell
version: 1.0.0
---

# WMS Backend Dev — 后端终端 Skill

必须遵守：@./rules/entity.rules.md（以实际任务 Domain 为准）

## Trigger

- wms-dev 协调器路由后端任务到本 skill
- 用户直接指定后端开发：`/wms-backend-dev`
- 涉及 `IMTC.WMS.AdminWebApi/` 的代码变更

## Domain Routing

| 影响层 | Context | Base Rules（先加载） |
|---|---|---|
| Entity — 实体字段、SqlSugar 特性、可空性、索引 | `wms-entity` | `./rules/entity.rules.md` |
| Repository — 查询、SQL、持久化、仓储结构 | `wms-repository` | `./rules/repository.rules.md` |
| Service — 编排、DTO、事务、调用链 | `wms-service` | `./rules/service.rules.md` |
| Controller — 路由、API、鉴权、契约 | `wms-controller` | `./rules/controller.rules.md` |

## Conditional Rule Packs

仅加载命中场景的 Pack，未命中不得默认读取。

| 场景 | 读取 Pack |
|---|---|
| DTO 入参/出参/查询条件/API 返回结构变化 | `./rules/packs/service-dto.rules.md` |
| 事务边界、多 Repository 写入、异常闭环 | `./rules/packs/service-transaction.rules.md` |
| 状态流、库存、标签、质检、T100、立库、远程调用 | `./rules/packs/service-risk.rules.md` |
| Repository 查询、Where、分页、软删除、原生 SQL、参数化、IN 条件、数据范围 | `./rules/packs/repository-query.rules.md` |
| Repository 插入、更新、删除、批量写入 | `./rules/packs/repository-write.rules.md` |
| Entity 字段、SugarColumn、nullable、长度、精度、枚举、索引、唯一约束 | `./rules/packs/entity-field.rules.md` |
| 新增实体时补 Repository 基础结构 | `./rules/packs/entity-repository-base.rules.md` |
| Controller 路由、HTTP 动作、鉴权、权限码、菜单 | `./rules/packs/controller-setup.rules.md` |
| API 契约、参数绑定、返回结构、Web/PDA/外部系统影响 | `./rules/packs/controller-contract.rules.md` |

## Loading Strategy

### 简单任务（复用协调器判断）

- 加载：本 SKILL.md + 目标 Domain Base Rules
- 命中特定场景才读对应 Condition Pack
- 不扫描未命中 Pack

### 复杂任务（协调器拆批后）

- 协调器在 Agent Task Packet 中指定 Base Rules + 命中 Packs 绝对路径
- Agent 按启动指令逐文件读取，不自行扩展

## Boundaries

- 本 skill 的 rules/ 目录由协调器管理。每次任务只读取协调器指定的文件路径，不自行扫描 rules/ 目录
- 不为了"了解上下文"而读取未指定的 Pack
- 只读写 `IMTC.WMS.AdminWebApi/`
- 禁止读取或修改 `IMTC.WMS.AdminUI/`（前端）和 `IMTC.WMS.PDA/`（PDA）
- DTO/API 契约变更可能影响 Web/PDA 时，只提示影响范围，不自行查看或修改对应端代码
- 发现任务扩展至前端/PDA 时，停止并回报协调器

## Escalation

任务范围在实现过程中扩大时：
1. 停止当前实现
2. 向协调器报告：原始范围 vs 实际发现的范围
3. 等待协调器重新评估（可能升级到复杂模式、新增 P 批次或拆分终端）
