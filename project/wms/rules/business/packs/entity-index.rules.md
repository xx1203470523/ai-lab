---
description: "Entity Index Conditional Rule Pack：SugarIndex、唯一约束、软删除参与唯一性和索引变更风险约束。"
paths:
  - "IMTC.WMS.AdminWebApi/Domain/Domain.Warehouse/Entities/**/*.cs"
---

# Entity Index Rule Pack

命中条件：任务涉及新增、删除、修改 `[SugarIndex]`，唯一索引，索引名，索引字段顺序，或软删除字段是否参与唯一性。

## Index Constraints

- 索引使用 `[SugarIndex(...)]`。
- 索引特性必须放在 `[SugarTable]` 后、类声明前。
- 唯一索引必须确认软删除字段是否需要参与唯一约束。
- 禁止为了格式统一擅自新增、删除或改名索引。
- 禁止擅自修改索引名、索引字段或排序方向。
- 索引变更可能影响数据库结构和查询计划，必须说明风险或等待用户确认。
