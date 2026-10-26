# WMS ORM 查询边界

## 实体到表

项目仓储实体用 `[SugarTable]` 声明表名，属性用 `[SugarColumn]` 声明列名/描述，`[Tenant]` 指向数据库租户。典型主业务链：

- `InStockReceiptHead` → `instock_receipt_head`
- `InStockReceiptDetail` → `instock_receipt_detail`
- `InStockReceiptLabel` → `instock_receipt_label`
- `InStockUpShelves` → `instock_up_shelves`
- `InStockUpShelvesDetail` → `instock_up_shelves_detail`
- `OutStockPickOrder` → `outstock_pick_order`

这些实体通常属于 `DBTenant.Default`（WMS）。共享、日志、立库和 BI 实体必须按实体上的 `[Tenant]` 及对应配置路由，不得按表名前缀猜测。

## 关系与字段

- `instock_receipt_detail.ReceiptHeadId`、`instock_receipt_label.ReceiptHeadId` → `instock_receipt_head.Id`
- `instock_up_shelves.ReceiptHeadId` → `instock_receipt_head.Id`
- `instock_up_shelves_detail.UpShelvesId` → `instock_up_shelves.Id`
- 常用单号字段：`ReceiptNo`、`UpShelvesNo`、`PickOrderNo`、`SyncCode`。
- 常用数量字段：`ReceivedNum`、`UpNum`、`ApplyNum`、`PickedNum`。
- 常用状态字段：`Status`、`UpStatus`、`SyncStatus`、`ExcuteStatus`。

## 直接 SQL 与 ORM 的差异

SqlSugar Repository 可能附加全局查询过滤器、租户范围和软删除过滤；直接 MySQL 查询不会自动继承。生成 SQL 前必须核对实体/接口代码中的删除字段（本项目常见为 `IsDeleted`，部分历史表可能是 `DeletedAt`），不能机械套用 `DeletedAt IS NULL`。

实体含 `[SugarIndex]` 的字段应优先用于过滤和排序；避免 `SELECT *`，设置合理 `LIMIT`，并优先以单号、ID、时间范围收敛结果。

## 操作边界

仓储与服务同时存在 `Queryable`、`Insertable`、`Updateable`、`Deleteable` 和事务操作。dbsql 只提取查询语义，不复现应用写操作。任何数据修复、清理、更新请求只能输出预检/备份/事务/验证/回滚脚本，不能调用查询脚本执行。
