---
name: wms-dev
description: "WMS 后端开发唯一入口：协调 Entity、Repository、Service、Controller 等 Domain Skill，控制改动范围、任务拆分、Agent 分派与验证。使用本 skill 时必须遵守 @../rules/business/dev.rules.md。"
shell: powershell
version: 3.0.0
---

# WMS Dev — 后端开发 Coordinator

必须遵守：@../rules/business/dev.rules.md

## Trigger

- 新增或修改 WMS 后端功能。
- 跨 Entity / Repository / Service / Controller 多层联动。
- 用户未指定 Domain Skill，需要 Coordinator 拆分。

## Modes

### Lightweight（默认尝试）

触发判断：In Scope ≤ 1 文件 + 1 字段 / 方法，无契约影响（API / DTO / Web / PDA / 打印 / 导出 / 外部系统）。

跳过：综合改动范围评估、推荐执行批次、后续候选三段。
保留：Start Gate、Mini Task Contract（3 行）、验证。

规则加载：只加载 `dev.rules.md` Base、目标 Domain Base；仅在命中明确场景时读取对应 Conditional Rule Pack。

### Full

跨层联动、契约影响、优化 / 重构合集、多批次候选时使用，输出完整 Output Format。

规则加载：按任务影响范围读取命中的 Conditional Rule Packs，不默认读取全部 packs。

## Start Gate

写操作前必须通过 `/wms-start-gate`；Blocked 时本 skill 任务状态置 `Blocked` 并按 gate 指向下一步。详见 `@../wms-start-gate/SKILL.md`。

## Workflows

- 综合评估与批次：@workflows/scoped-batch-planning.md
- Coordinator 流程（任务状态 / 拆分 / Agent 分派 / 验证）：@workflows/coordinator-flow.md

## Domain Skill Routing

| 影响层 | Domain Skill | Base Rules |
|---|---|---|
| 实体字段、SqlSugar 特性、可空性、索引、实体结构 | `wms-entity` | `../rules/business/entity.rules.md` |
| Repository 查询、原生 SQL、持久化访问、仓储结构 | `wms-repository` | `../rules/business/repository.rules.md` |
| Service 编排、DTO、事务、调用链闭环 | `wms-service` | `../rules/business/service.rules.md` |
| Controller、路由、API 入口、契约入口 | `wms-controller` | `../rules/business/controller.rules.md` |

## Conditional Rule Packs

Coordinator 只负责识别命中条件并把对应 pack 路径传入 Agent；未命中的 packs 不默认读取。

| 场景 | 读取规则包 |
|---|---|
| DTO 入参 / 出参 / 查询条件 / API 返回结构变化 | `../rules/business/packs/service-dto.rules.md` |
| 事务边界、状态流、远程调用、库存/标签/T100/立库风险 | `../rules/business/packs/service-transaction.rules.md` |
| V2 Service / V2 DTO / 调用切换 / 旧逻辑清理 | `../rules/business/packs/service-v2.rules.md` |
| Repository 查询、Where、分页、软删除、数据范围 | `../rules/business/packs/repository-query.rules.md` |
| 原生 SQL、SQL 参数化、IN 条件、拼接治理 | `../rules/business/packs/repository-raw-sql.rules.md` |
| Repository 插入、更新、删除、批量写入 | `../rules/business/packs/repository-write.rules.md` |
| Entity 字段、SugarColumn、nullable、长度、精度、枚举 | `../rules/business/packs/entity-field.rules.md` |
| Entity 索引、唯一约束、软删除参与唯一性 | `../rules/business/packs/entity-index.rules.md` |
| 新增实体时补 Repository 基础结构 | `../rules/business/packs/entity-repository-base.rules.md` |
| Controller 路由、HTTP 动作、路由冲突 | `../rules/business/packs/controller-route.rules.md` |
| Controller 鉴权、权限码、匿名访问、菜单权限 | `../rules/business/packs/controller-auth.rules.md` |
| API 契约、参数绑定、返回结构、Web/PDA/外部系统影响 | `../rules/business/packs/controller-contract.rules.md` |

## Coordinator Workflow

1. 状态置 `Pending`，识别需求和边界，判断是否只读。
2. 写操作通过 `/wms-start-gate`；Blocked 则置 `Blocked` 并停止。
3. 判断模式（Lightweight / Full），输出 Task Contract。
4. 识别涉及 Domain、Base Rules 和命中的 Conditional Rule Packs。
5. 用户确认批次后输出执行计划。
6. 状态置 `Running`，按 Domain 派单一任务给实现 Agent；Agent prompt 必须包含：
   - Task Contract 全文。
   - Domain Skill 名。
   - Base Rules **绝对路径**。
   - 已命中的 Conditional Rule Packs **绝对路径**。
   - 启动指令："先 Read 上述 Base Rules 和 Rule Packs，再开始实现；未命中的 packs 不要一次性读取；发现任务范围扩大时先回报。"
   - 允许 / 禁止读写路径。
7. 状态置 `Verifying`，独立 Verification Agent 验证。
8. 汇总实现与验证结果，置 `Done` 或 `Blocked`。

> ⚠️ 子 Agent 不继承父会话上下文，personal Domain Skill 不会被子 Agent 自动加载。Rules 必须通过绝对路径 + 启动指令显式传入 Agent prompt。

## Output Format

### Lightweight

```markdown
## WMS Dev（Lightweight）

- 状态：Pending / Running / Verifying / Done / Blocked
- 目标：...
- Start Gate：Passed(ReadOnly) / Passed / Blocked
- Mini Task Contract：In Scope / Out of Scope / 验证方式
- Domain Skill / Base Rules / 命中 Rule Packs：...
- 验证：已验证 / 残余风险
```

### Full

```markdown
## WMS Dev 任务状态

- 当前状态 / 目标功能 / Start Gate / 当前 worktree / 当前批次：...

## 综合改动范围评估

| 优先级 | 类别 | 改动项 | 文件数 | 风险 | 证据等级 | 建议分支范围 |
|---|---|---|---|---|---|---|

## Task Contract

- 本次批次 / 目标 / In Scope / Out of Scope / 明确不改
- 允许读取 / 禁止读取或修改
- 涉及层级 / 预计文件数 / 契约影响 / 验证方式 / 停止条件

## 规则加载

- Base Rules：...
- 命中 Conditional Rule Packs：...
- 未命中且不读取：...

## 推荐执行批次

- 建议本次只处理 / 不建议本次处理 / 原因 / 是否需要用户确认：...

## 任务拆分

| 子任务 | Domain Skill | Base Rules | 命中 Rule Packs | Agent 类型 | 状态 |
|---|---|---|---|---|---|

## 验证与清理

- Verification Agent / 已验证 / 未验证 / 逻辑检查 / 未引用文件 / 无用代码 / 残余风险：...

## 后续候选

| 优先级 | 候选项 | 证据等级 | 不在本次处理原因 | 建议后续分支 |
|---|---|---|---|---|

## Blocked 信息

- 阻塞原因 / 需要确认 / 建议下一步：...
```

## Boundaries

- 不直接实现代码，不复制 Domain Rules 正文。
- 不复制 `/wms-start-gate`、`/git-sync-main`、`/git-rebase-main`、`/git-worktree`、`/git-stash` 内部流程。
- 不主动读写 Web / PDA，除非任务本身是对应端任务。
- 不默认读取未命中的 Conditional Rule Packs。
