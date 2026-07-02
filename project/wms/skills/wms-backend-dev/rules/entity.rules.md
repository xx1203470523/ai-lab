# Entity Base Rules

本文件是 `wms-entity` 的 Base Rules，只包含实体任务始终适用的最小强约束；字段、索引、Repository 基础结构细则按场景读取 `rules/business/packs/`。

## 1. Conditional Rule Packs

| 场景 | 规则包 |
|---|---|
| 字段、SugarColumn、nullable、长度、精度、枚举、NoDB | `rules/business/packs/entity-field.rules.md` |
| 索引、唯一约束、软删除参与唯一性 | `rules/business/packs/entity-index.rules.md` |
| 新增实体时补 Repository 基础结构 | `rules/business/packs/entity-repository-base.rules.md` |

## 2. Namespace

- 实体与仓储默认使用类库级 namespace：`namespace Domain.Warehouse;`。
- 禁止按目录拼接 namespace，例如 `Domain.Warehouse.Entities.InStock`。

## 3. Directory

- 实体文件位于：`IMTC.WMS.AdminWebApi/Domain/Domain.Warehouse/Entities/<Module>/...`。
- 仓储文件位于：`IMTC.WMS.AdminWebApi/Domain/Domain.Warehouse/Repositories/<Module>/...`。
- 新增文件名应与类名一致。
- 不因规范化重命名历史文件、历史类名或历史目录。

## 4. Entity Class Attributes

类级特性顺序固定：

```csharp
[DBGeneration]
[Tenant(DBTenant.Default)]
[SugarTable("table_name", TableDescription = "表说明")]
[SugarIndex("idx_Field", nameof(Field), OrderByType.Desc)]
public class MyEntity : DataPermissionEntityAbstract, IDeletedFilter
{
}
```

约束：

- 已有真实 `[DBGeneration]` 的实体保持真实特性。
- 当前没有 `[DBGeneration]` 的历史实体，不实际新增真实特性；只在 `[Tenant(...)]` 前补 `//[DBGeneration]`。
- 新增实体是否使用真实 `[DBGeneration]` 以用户任务明确要求为准；未明确时使用 `//[DBGeneration]`。
- 每个实体必须维护租户特性，默认：`[Tenant(DBTenant.Default)]`。
- `[SugarTable]` 必须包含 `TableDescription`。
- `[SugarIndex]` 位于 `[SugarTable]` 后、类声明前；修改索引前读取 `entity-index.rules.md`。
- 禁止擅自修改表名、列名、索引名。

## 5. Entity Inheritance

- 需要站点或数据权限的业务实体使用：`DataPermissionEntityAbstract, IDeletedFilter`。
- 普通表实体使用：`TableEntityAbstract, IDeletedFilter`。
- 乐观锁实体按项目既有基类使用，并在具备软删除字段时显式声明 `IDeletedFilter`。
- 业务实体必须显式实现 `IDeletedFilter`。
- 禁止手动设置 `IsDeleted`。
- 禁止因规范化删除旧字段、兼容字段或 `[Obsolete]` 特性。

## 6. Repository Boundary

- 新增实体需要 Repository 基础结构时，读取 `entity-repository-base.rules.md`。
- 禁止在实体规范化任务中顺手修改历史 Repository SQL、硬删除或复杂查询行为。
- 复杂查询、原生 SQL、持久化行为归 `wms-repository`。

## 7. Formatting

- C# 缩进使用 4 个空格。
- 类级特性紧贴类声明。
- 字段 summary 紧贴 `SugarColumn`。
- 属性之间保留一行空行。
- 禁止无关排序、无关格式化、无关重排。
- 代码注释使用简体中文。
- 代码标识符使用英文并遵循项目既有命名。
