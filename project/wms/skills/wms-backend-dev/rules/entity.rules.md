# Entity Rules

## Purpose

定义 Entity 层开发必须遵守的稳定约束。

不包含：

- 任务流程
- Skill 路由
- Agent 编排
- 业务流程

---

## Rule Loading

当前规则为 Entity Base Rules。

命中以下场景时加载对应 Pack：

| 场景                                          | Rule Pack                               |
| --------------------------------------------- | --------------------------------------- |
| 字段、SugarColumn、nullable、长度、精度、枚举 | `packs/entity-field.rules.md`           |
| 索引、唯一约束、软删除唯一性                  | `packs/entity-index.rules.md`           |
| 新增实体并创建 Repository 基础结构            | `packs/entity-repository-base.rules.md` |

规则：

- 命中必须读取。
- 未命中禁止读取。

---

## Namespace

规则：

- 使用项目类库 namespace。
- 禁止根据目录层级生成 namespace。
- 禁止无业务原因修改历史 namespace。

---

## File Location

Entity：

`IMTC.WMS.AdminWebApi/Domain/Domain.Warehouse/Entities/<Module>/`

规则：

- 文件名与类名一致。
- 禁止无关移动和重命名历史实体。

---

## Entity Attribute

实体特性顺序：

- DBGeneration
- Tenant
- SugarTable
- SugarIndex

规则：

- 必须存在 Tenant 特性。
- SugarTable 必须包含 TableDescription。
- 禁止未经确认修改表名、字段映射、索引定义。

### DBGeneration

规则：

- 已存在真实 DBGeneration 保持不变。
- 历史实体未使用时不得主动新增真实特性。
- 未明确要求时保持现有项目方式。

---

## Entity Inheritance

业务实体：

- DataPermissionEntityAbstract
- IDeletedFilter

普通实体：

- TableEntityAbstract
- IDeletedFilter

规则：

- 业务实体必须支持软删除。
- 禁止手动修改 IsDeleted。
- 禁止删除历史字段、兼容字段、Obsolete 标记。

---

## Repository Boundary

Entity 任务只处理：

- 实体结构。
- 字段映射。
- Entity 特性。

禁止：

- 修改复杂查询。
- 修改 Repository SQL。
- 调整持久化逻辑。

---

## Change Scope

遵循最小修改原则。

禁止：

- 无关格式化。
- 无关重构。
- 批量修改历史实体。

以下变化必须单独确认：

- 字段语义变化。
- 表结构变化。
- 数据库迁移变化。
- 跨模块契约变化。

---

## Code Style

规则：

- C# 使用 4 空格缩进。
- 类特性紧贴类声明。
- 字段说明紧贴字段映射。
- 属性之间保留空行。
- 标识符使用英文。
- 注释使用简体中文。

---

## Verification

完成后检查：

- Namespace 是否正确。
- Entity 特性是否符合规范。
- 是否存在无关字段变化。
- 是否影响 Repository 或数据库契约。
- 是否存在无用 using、临时字段、调试代码。
