# 实体 ↔ 表 ↔ 查询边界（WMS profile）

本文件解决一个问题：**手写 SQL 时，怎么让结果口径与应用看到的一致。** 结论都带证据，证据可能过期，用前复核。

## 表名与列名只能从实体反推

| 信息 | 来源 |
|---|---|
| 表名 | 实体类上的 `[SugarTable("instock_receipt_label")]` |
| 列名 | 属性名（`[SugarColumn(ColumnDescription = "…")]` 只给中文名，不是列名） |
| 该实体属于哪个库 | `[Tenant(DBTenant.Default)]` → `ConfigId` → `appsettings` 的 `Database=` |
| 索引清单 | 实体上的 `[SugarIndex("idx_xxx", nameof(...))]` |

**不得臆造字段。** 需要某个字段时：找到实体文件（`Domain/Domain.*/Entities/**`），按属性名确认；不确定就 `DESCRIBE` 那张表。给结论时把实体文件路径与行号一并给出（写进 `EntityEvidence`）。

`[SplitField]` 需要注意：`TableEntityAbstract.CreateOn` 上的注释写着「日志等按创建时间分表的实体统一使用该字段定位分表」（`Domain/Domain.Shared/Entities/TableEntityAbstract.cs:23-26`）。也就是说**日志类数据可能按创建时间分了表**，查询历史区间时打到一张表上会漏数据。查日志类实体前先确认分表规则，不要假定只有一张表。

## 软删除：判据是「实体是否实现 `IDeletedFilter`」

这套项目里有两件容易混起来的事：

1. **`IsDeleted` 列存在**——它定义在基类 `TableEntityAbstract`（`Domain/Domain.Shared/Entities/TableEntityAbstract.cs:40-44`，`bool IsDeleted`），所以**几乎所有表都有这个列**。
2. **应用会不会自动按它过滤**——只有**实现了 `IDeletedFilter`**（`Domain/Domain.Shared/Interfaces/IDeletedFilter.cs:6-12`）的实体才会。全局过滤器在 `DBQueryFilterInitializer.Initialize` 里安装：`AddTableFilter<IDeletedFilter>(entity => entity.IsDeleted == false)`，且**BI 连接不安装**（`Domain/Domain.Shared/Repository/DBQueryFilterInitializer.cs:28-31`）。

实测规模（`Domain` 与 `Services` 下带 `[SugarTable]` 的 .cs，排除 bin/obj）：**279 个实体文件，其中 266 个声明了 `IDeletedFilter`，13 个没有**。没声明的例子：`Domain.LowCode/Entities/Gendemo.cs`、`GenTableColumn.cs`、`Domain.Warehouse/Entities/Base/BaseStokeeperMaterial.cs`，以及 `Services.Warehouse/Dtos/DataInit/*` 下那批。

### 由此得到的规则

- 实体**实现** `IDeletedFilter` → 手写 SQL **加** `IsDeleted = 0`。理由不是「列存在」，而是「应用的可见范围就是这样」；不加会查出应用永远看不到的行。
- 实体**未实现** `IDeletedFilter` → **默认不加**。列虽然存在，但应用不据此过滤，加了会让你看到比应用更少的行——这是「数字对不上」的典型来源。
- **不要**写成「所有表都加 `IsDeleted = 0`」或「所有表都加 `DeletedAt IS NULL`」。前者在上面 13 个实体上是错的；后者更错，见下。

### `DeletedAt` 只在 1 个实体上存在

`InstockReceiptLabel`（`Domain/Domain.Warehouse/Entities/InStock/InstockReceiptLabel.cs:148`）是仓库里**唯一**有 `DeletedAt` 列的实体。它**同时**声明了 `IDeletedFilter`（`:16`），并且删除路径把两列一起写：

```csharp
// Services/.../InStock/Receipt/InStockReceiptV2Service`PDA.cs:1015-1022（PDA 退扫）
.SetColumns(m => m.IsDeleted == true)
.SetColumns(m => m.DeletedBy == userName)
.SetColumns(m => m.DeletedAt == now)
```

它的唯一索引是 `uniq_LabelId_DeletedAt (LabelId, DeletedAt)`（`:15`）——这是「同一 LabelId 允许重复出现，靠 DeletedAt 区分历史」的写法。

**因此正确判据是 `IsDeleted = 0`，不是 `DeletedAt IS NULL`。** 两列在这条删除路径上一致，但真正被 ORM 强制、也是应用口径的是 `IsDeleted`；把 `DeletedAt IS NULL` 当通用判据，会在另外 278 个实体上直接报错（没有这个列）。

> 这一条是对旧技能文档的**纠错**：旧版 `wms-mysql-reference.md` 的模板全部使用 `DeletedAt IS NULL`，与本项目的真实约定不符。

### BI 连接是刻意的例外

`DBQueryFilterInitializer` 明确跳过 `ConfigId = BI` 的连接，注释写明「BI 连接用于报表和快照历史查询，必须保留已删除数据」。所以：查 BI 时**不能**照搬业务库的软删除口径——已删除数据在那里是数据，不是噪声。（另注：静态 BI 是 Oracle，本技能无执行器，见 `routes.md`。）

## `SiteCode` 已废弃，不要拿它过滤

`DataPermissionEntityAbstract.SiteCode` 带着 `[Obsolete("每个据点都是独立部署的,所以据点无需作为判定条件")]`（`Domain/Domain.Shared/Entities/DataPermissionEntityAbstract.cs:11-13`）。

**每个据点是独立部署的**——所以据点维度不是靠列过滤，而是靠**连到哪个库**。含义有两条：

- 手写 SQL 里 `WHERE SiteCode = '…'` 是错的：它可能返回空集，也可能返回一张混着历史数据的子集，两种都不会报错。
- 据点隔离由路由承担（`routes.md` 的据点↔库映射），这也是为什么本技能坚持「库名由路由决定、禁止在 SQL 里写库名或 schema 前缀」。

## 写查询时的边界

- **不带库名/schema 前缀**：库由路由决定，写进 SQL 只会掩盖路由错误。
- **不 `SELECT *`**：只取需要的列。列名以实体属性为准。
- **`WHERE` 尽量落在实体 `[SugarIndex]` 声明的列上**，那是索引的唯一权威清单；`[SugarColumn]` 只描述列，不描述索引。
- **`CreateOn` 是创建时间**（`TableEntityAbstract.cs:24-26`）。业务上的「发生时间」另有其列，两者不可互换——写成哪个由业务语义决定，拿不准就先确认列语义再写条件。
- 实体所在的库要靠 `[Tenant]` 判断：同一张表可能在 `shared`/`logs` 等不同租户下指向不同库（开发环境就有 `dev.shared` 与 `dev.logs` 指向同一个物理库、但属于不同 `ConfigId` 的情况）。
