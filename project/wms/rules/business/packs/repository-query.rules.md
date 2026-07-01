---
description: "Repository Query Conditional Rule Pack：Queryable、过滤范围、软删除、分页、性能和数据范围约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Domain/**/Repositories/**/*.cs"
---

# Repository Query Rule Pack

命中条件：任务涉及查询、Where、Join、Select、分页、统计、聚合、软删除、租户/站点/数据权限、排序或查询性能。

## 1. Queryable Usage

- 新增查询优先使用 SqlSugar 链式 API：`Queryable()`、`Context.Queryable<TEntity>()`、`WhereIF`、`LeftJoin`、`Select`、`GroupBy`、`MergeTable`。
- 需要继续由调用方组合条件的查询可返回 `ISugarQueryable<T>`。
- 需要立即执行的查询必须明确返回 `Task<T>`、`Task<List<T>>`、`List<T>`、实体或统计值。
- 异步方法名必须以 `Async` 结尾。
- SqlSugar 查单条记录使用 `FirstAsync()`；禁止新增不存在的 `FirstOrDefaultAsync()` 调用。
- 禁止先 `ToList` 再做本可由数据库完成的过滤、排序、分组或分页。
- 分页查询必须在数据库侧完成分页，禁止全量拉取后内存分页。

## 2. Filter And Data Scope

- 新增查询必须尊重软删除过滤、租户过滤、站点或数据权限上下文；禁止无理由绕过全局过滤器。
- 使用 `ClearFilter()` 必须有明确业务理由，并且必须显式补回必要的 `IsDeleted`、站点、租户或状态条件。
- 原生 SQL 查询涉及软删除表时必须显式包含对应 `IsDeleted = 0` 或业务确认的历史数据条件。
- 禁止为了查数方便在 Repository 中扩大数据范围。

## 3. Performance

- 查询必须尽量只 `Select` 需要的字段，避免无必要返回整表实体。
- 多实体关联查询必须明确 join 条件，避免隐式笛卡尔积。
- 批量查询优先使用集合条件一次查询，禁止在循环中逐条查询造成 N+1。
- 汇总、计数、分组优先交给数据库执行。
