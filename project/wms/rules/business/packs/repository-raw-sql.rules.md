---
description: "Repository Raw SQL Conditional Rule Pack：原生 SQL 参数化、软删除、IN 条件和字符串拼接治理约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Domain/**/Repositories/**/*.cs"
---

# Repository Raw SQL Rule Pack

命中条件：任务涉及原生 SQL、SQL 字符串、`Ado.SqlQuery*`、`Queryable` 无法表达的查询、SQL 参数、IN 条件或 SQL 治理。

## 1. Raw SQL Entry

- 新增查询优先使用 SqlSugar 链式 API，只有链式 API 难以表达、性能确有必要或需要兼容历史 SQL 时才允许原生 SQL。
- 只读、无外部输入且为兼容历史报表的 SQL 必须保持范围明确，禁止顺手扩大查询字段和表关联。

## 2. Parameterization

- 原生 SQL 必须参数化，使用 `SugarParameter`、`AddParameters` 或 SqlSugar 等价参数机制。
- 禁止把用户输入、查询条件、单号、编码、日期、状态等直接拼接进 SQL 字符串。
- 禁止新增 `String.Format`、插值字符串、字符串累加方式拼接带外部输入的 `WHERE` 条件。
- `IN` 条件优先使用链式 `Contains` 或参数化方案；禁止直接拼接未经验证的 Id/Code 列表。

## 3. Scope And Soft Delete

- 原生 SQL 查询涉及软删除表时必须显式包含对应 `IsDeleted = 0` 或业务确认的历史数据条件。
- 使用原生 SQL 绕过全局过滤器时，必须显式补回租户、站点、数据权限或状态条件。
- 禁止为了查数方便扩大数据范围。
