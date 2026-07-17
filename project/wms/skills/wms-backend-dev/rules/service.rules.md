# Service Rules

## Purpose

定义 Service / DTO 层开发必须遵守的稳定约束。

不包含：

- 任务流程
- Skill 路由
- Agent 编排
- 业务流程

---

## Rule Loading

当前规则为 Service Base Rules。

命中以下场景时加载对应 Pack：

| 场景                                                | Rule Pack                            |
| --------------------------------------------------- | ------------------------------------ |
| DTO 命名、字段、输入输出、查询结构、API 返回结构    | `packs/service-dto.rules.md`         |
| 事务边界、状态流、远程调用、库存/标签/T100/立库风险 | `packs/service-transaction.rules.md` |
| V2 Service、V2 DTO、调用切换、旧逻辑清理            | `packs/service-v2.rules.md`          |

规则：

- 命中必须读取。
- 未命中禁止读取。

---

## Responsibility

Service 负责：

- 业务编排。
- 领域协调。
- 调用链闭环。
- 事务边界。
- 异常闭环。
- 返回结果组装。

禁止：

- 在 Controller 编写业务逻辑。
- 在 Service 堆积复杂持久化细节。
- 依赖 Web/PDA 页面结构。
- 使用前端展示状态替代业务状态。

---

## Boundary

Service 任务只处理：

- Service 实现。
- Service 接口。
- DTO 契约。

涉及：

- Entity 字段、索引、映射 → 遵守 Entity Rules。
- Repository 查询、SQL、持久化 → 遵守 Repository Rules。
- API 路由、入口契约 → 遵守 Controller Rules。

---

## Namespace And Structure

规则：

- Service 使用类库级 namespace。

示例：

`namespace Services.Warehouse;`

- Service 类命名：

`<BusinessName>Service`

- 接口命名：

`I<BusinessName>Service`

- Service 默认实现项目约定生命周期。

方法：

- 公共方法必须有 XML summary。
- 异步方法必须使用 `Async` 后缀。
- 同步方法禁止添加 `Async`。

大型 Service：

- 允许使用 partial 按职责拆分。
- 单个文件只承载明确职责。

---

## Context Requirement

修改 Service 前必须确认：

- 输入来源。
- 输出消费者。
- 数据来源。
- 调用链。
- 事务边界。
- 异常分支。
- 状态流。
- 后续影响。

禁止：

- 只根据方法名修改业务逻辑。
- 根据字段名猜测业务含义。
- 补充不存在的状态、库存动作、远程调用。

不确定以下内容时进入确认：

- 业务含义。
- 状态流。
- 库存影响。
- 标签影响。
- T100/立库影响。
- 远程调用影响。

---

## Logic Protection

默认保护原业务逻辑。

允许：

- 明确范围内的小修复。
- 局部性能优化。

禁止：

- 删除历史兼容逻辑。
- 删除旧 DTO。
- 删除旧返回结构。
- 修改状态流。
- 修改库存流。
- 修改远程调用闭环。

发现问题必须区分：

- Bug。
- 优化。
- 风险。
- 可抽象项。

未经确认不得直接扩大修改。

---

## Method And Split

规则：

- 一个 Service 方法处理一个明确业务动作。
- 一个 partial 文件对应一个职责方向。

允许拆分方向：

- 查询。
- 创建。
- 更新。
- 删除。
- 校验。
- 扫描。
- 打印。
- 导出。
- 回调。
- 同步。

禁止：

- 一个方法混合查询、校验、事务、远程调用、DTO 拼装。
- 为形式拆分代码。
- Service 直接编写复杂 SQL。

### File Organization

partial 文件按职责独立存储，使用反引号分隔：

``{Name}Service`{Purpose}.cs``

标准 `{Purpose}` 示例：`Query`、`Export`、`Confirm`、`Print`。

禁止：

- 查询和导出逻辑混在同一个 partial 文件。
- 后置填充和查询构建混在同一个 partial 文件。

---

## Contract Protection

DTO 变化必须确认影响：

- 字段删除。
- 字段重命名。
- 类型变化。
- 可空性变化。
- 枚举变化。

涉及：

- Web。
- PDA。
- API。
- 打印。
- 导出。
- 外部系统。

必须先确认。

禁止未经授权：

- 修改 `IMTC.WMS.AdminUI/`
- 修改 `IMTC.WMS.PDA/`

---

## Exception And Verification

规则：

- 使用项目统一业务异常机制。
- 异常信息必须表达业务原因。
- 禁止吞异常。
- 禁止让业务进入未知状态。

验证：

检查：

- 调用链。
- DTO 契约。
- 事务边界。
- 异常分支。
- 状态闭环。
- 影响范围。

未经授权：

- 不主动运行 build/test。

授权 build 时：

`dotnet build <project> /p:WarningLevel=0`

要求：

- 错误清零。
- 警告不阻塞验证。

---

## Change Scope

禁止：

- 大批量维护。
- 大批量重构。
- 跨无关 Service 修改。
- 以“统一整理”为目的修改。

发现多个类似问题：

- 记录为优化建议。
- 未确认不得批量实施。

---

## Code Style

规则：

- C# 使用 4 空格缩进。
- 注释使用简体中文。
- 标识符使用英文。
- 遵循项目已有命名。

禁止：

- 无关格式化。
- 无关排序。
- 无用 using。
- 无用字段。
- 无用私有方法。
- 临时变量。
- 调试输出。
- 注释废代码。
