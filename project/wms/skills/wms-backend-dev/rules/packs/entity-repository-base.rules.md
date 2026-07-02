# Entity Repository Base Rule Pack

命中条件：新增实体、调整实体基础结构时，需要同步新增或审查对应 Repository 基础结构。

## Repository Base Constraints

- 仓储类命名：`<EntityName>Repository`。
- 仓储类继承：`Repository<TEntity>, ITransient`。
- 构造函数使用 `ISqlSugarClient context` 并传入 `base(context)`。
- 仓储 namespace 使用 `Domain.Warehouse` 或所属领域类库级 namespace。
- 新增仓储查询禁止字符串拼接 SQL。
- 原生 SQL 必须参数化；涉及原生 SQL 时改由 `wms-repository` 并读取 `rules/business/packs/repository-raw-sql.rules.md`。
- 禁止在实体规范化任务中顺手修改历史 Repository SQL、硬删除或复杂查询行为。
