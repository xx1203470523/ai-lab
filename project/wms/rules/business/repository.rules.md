---
description: "IMTC.WMS 后端 Domain Repository Base Rules：命名、类结构、职责边界、方法设计、兼容和格式约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Domain/Domain.Warehouse/Repositories/**/*.cs"
  - "IMTC.WMS.AdminWebApi/Domain/Domain.AutomationWarehouse/Repositories/**/*.cs"
---

# Repository Base Rules

本文件是 `wms-repository` 的 Base Rules，只包含 Repository 任务始终适用的最小强约束；查询、原生 SQL、写入等细则按场景读取 `rules/business/packs/`。

## 1. Scope And Packs

| 场景 | 规则包 |
|---|---|
| Queryable、Where、分页、软删除、数据范围、性能 | `rules/business/packs/repository-query.rules.md` |
| 原生 SQL、SQL 参数化、IN 条件、字符串拼接治理 | `rules/business/packs/repository-raw-sql.rules.md` |
| Insert / Update / Delete、批量写入、事务协作 | `rules/business/packs/repository-write.rules.md` |

## 2. Namespace

- Repository 默认使用所属领域类库级 namespace，例如 `namespace Domain.Warehouse;`、`namespace Domain.AutomationWarehouse;`。
- 禁止按目录拼接 namespace，例如 `Domain.Warehouse.Repositories.InStock`。
- 新增 using 必须服务于当前仓储实现，禁止保留未使用 using。

## 3. Directory And Naming

- Repository 文件位于：`IMTC.WMS.AdminWebApi/Domain/<DomainProject>/Repositories/<Module>/...`。
- Repository 文件名必须与类名一致。
- Repository 类命名必须使用：`<EntityName>Repository`。
- 一个 Repository 默认只围绕一个聚合根或一个实体族的持久化访问展开，禁止把跨业务流程编排集中塞入单个 Repository。
- 不因规范化重命名历史文件、历史类名或历史目录。

## 4. Class Shape

标准结构：

```csharp
namespace Domain.Warehouse;

/// <summary>
/// 仓储说明
/// </summary>
public class MyEntityRepository : Repository<MyEntity>, ITransient
{
    public MyEntityRepository(ISqlSugarClient context) : base(context)
    {
    }
}
```

约束：

- Repository 必须继承：`Repository<TEntity>, ITransient`。
- 构造函数必须使用 `ISqlSugarClient context` 并传入 `base(context)`。
- 类必须有 XML `<summary>`，说明对应业务对象或表含义。
- 新增公共方法必须有 XML `<summary>`；参数和返回值语义不明显时必须补充 `<param>`、`<returns>`。
- C# 缩进使用 4 个空格。

## 5. Repository Responsibility

- Repository 只负责持久化访问、查询组合、批量写入入口和必要的数据投影。
- 业务编排、权限判断、事务边界、外部系统调用、PDA/Web 展示流程默认属于 Service 或上层应用服务。
- 新增 Repository 代码禁止依赖 Web PC、PDA 页面结构或前端展示状态。
- Repository 可返回实体、领域查询结果、`ISugarQueryable<T>`、投影 DTO 或 View DTO；禁止为某个 UI 组件硬编码展示逻辑。
- 禁止在 Repository 中写入与持久化无关的临时流程控制、缓存调度、HTTP 调用或消息推送逻辑。

## 6. Method Design

- 方法名必须表达业务动作或查询结果，新增代码禁止使用含义模糊的 `SQL1`、`GetData`、`DoUpdate` 等命名。
- 历史类中已有 `SQL*` 命名不因规范化任务强制改名；新增方法优先使用清晰英文名称。
- 公共方法参数必须使用明确 DTO、查询对象、实体、Id 集合或简单条件；禁止传入未约束的 SQL 片段。
- 返回影响行数的方法必须返回 `int` 或 `Task<int>`；返回查询构造器的方法不得在内部执行查询。
- 业务异常优先由 Service 判断并抛出；新增 Repository 方法默认返回数据、空值或影响行数。

## 7. Compatibility And Scope Control

- 禁止在 Repository 规范化任务中顺手修改 Service、Controller、DTO、前端、PDA 或数据库脚本。
- 禁止把历史 SQL、历史硬删除、历史 `SQL*` 命名、历史注释一次性批量重写，除非用户明确要求专项治理。
- 对可能改变查询结果、分页顺序、过滤范围、锁范围或事务时长的修改，必须在代码最终形态中保持意图清晰。
- 保留历史兼容字段、兼容查询和旧接口返回结构，除非用户明确要求破坏性清理。

## 8. Formatting

- 代码注释使用简体中文。
- 代码标识符使用英文并遵循项目既有命名。
- 方法之间保留一行空行。
- 禁止无关排序、无关格式化、无关重排。
- 禁止留下未使用变量、死代码、调试输出或临时注释。
