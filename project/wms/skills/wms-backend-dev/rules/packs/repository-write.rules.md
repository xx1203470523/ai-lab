# Repository Write Rule Pack

命中条件：任务涉及新增、更新、删除、软删除、批量写入、批量更新、影响行数、删除再插入或事务内 Repository 写入。

## 1. Insert Update Delete

- 新增插入、更新优先使用 Repository 基类能力或 `Context.Insertable`、`Context.Updateable`。
- 局部更新必须显式表达更新列，例如 `SetColumns`、`IgnoreColumns` 或项目既有等价写法。
- 批量更新必须以实体集合、Id 集合或明确条件为边界，禁止无条件全表更新。
- 删除默认使用软删除能力；禁止新增硬删除 SQL，除非用户明确要求物理删除并说明数据风险。
- 禁止手动设置实体 `IsDeleted` 来替代项目软删除能力，除非历史代码已采用该模式且本次任务只做最小兼容。

## 2. Transaction Boundary

- Repository 不负责开启、提交或回滚业务事务；事务编排默认由 Service 使用项目事务服务完成。
- Repository 可提供事务前预查询方法和事务内写入方法，但不得把可预先完成的查询塞进写事务流程。
- “删除再插入”类场景应支持先查询待处理 Id，再由上层在事务内执行软删除、新增或更新。
- 禁止在 Repository 中混入跨单据、跨外部系统、跨 Service 的事务编排。

## 3. Batch Performance

- 大批量写入必须使用批量 API 或明确分批策略，禁止逐条同步写入造成长事务或长锁。
- 返回影响行数的方法必须返回 `int` 或 `Task<int>`。
