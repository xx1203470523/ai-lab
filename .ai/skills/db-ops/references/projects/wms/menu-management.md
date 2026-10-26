# 菜单与权限管理（WMS profile）

本文件是 **WMS 菜单/权限数据的手工操作边界**：改 `sys_menu` / `sys_role_menu` 前该确认什么、按什么顺序做、
哪些看似合理的写法是错的。结论都带代码证据；**尚未在任何真实库上验证过**（见文末「证据状态」）。

> 相关：实体与列名反推规则见 `orm-boundaries.md`；软删除判据同样适用（`SysMenu` 与 `SysRoleMenu` 都实现了 `IDeletedFilter`）。
> 本文件只讲 WMS 菜单这组表，不重复通用 SQL 安全规则（见技能根目录 `references/sql-safety.md`）。

## 涉及的表与列名契约

| 表 | 列名风格 | 关键列 | 证据 |
|---|---|---|---|
| `sys_menu` | **PascalCase** | `Id` `MenuName` `ParentId` `OrderNum` `Path` `Component` `IsCache` `IsFrame` `MenuType` `Visible` `Status` `Perms` `Icon` | `Domain/Domain.System/Entities/SysMenu.cs`（属性未写 `ColumnName`，故列名=属性名） |
| `sys_role` | **PascalCase** | `Id` `RoleName` `RoleKey` `Status` | 同上（`Domain.System` 下的 `SysRole`） |
| `sys_role_menu` | **蛇形** | **`menu_id`** / **`role_id`** / `Id`（独立雪花主键） | `Domain/Domain.System/Entities/Relationships/SysRoleMenu.cs:13,19` 显式 `ColumnName` 映射 |
| `sys_user_role` | 蛇形（与 `sys_role_menu` 同风格） | 用前先 `SHOW COLUMNS` 确认 | 未逐字核对，按 `Relationships` 下的同族实体推定 |

**两套命名不一致是本组表最容易踩的坑。** `ORM` 侧没有任何全局命名约定（`Infrastructure.ORM/DBContext.cs`
的 `EntityNameService` 只设 `IsDisabledDelete = true`，不做列名转换），所以「没写 `ColumnName` 的属性名即列名」这条规则
在这里恰好会得出两种风格。

**因此：查 `sys_role_menu` 写 `WHERE MenuId = ...` 会报 `Unknown column`。**
仓库里已有 4 个老脚本犯过这个错（只影响它们的只读复核段），清单见
`D:\Project\WMS\sql\logs\2026-09-24\add-inventory-count-task-approve-permission.md:50-77`。
新写 SQL 一律用 `menu_id` / `role_id`。

**`sys_role_menu` 的主键是继承来的独立 `Id`（雪花），不是 `(role_id, menu_id)` 联合主键。**
含义有两面：
- 同一个 `(role_id, menu_id)` 理论上可以有多行（脚本插入时必须自己显式给 `Id`，`IsNullable=false`）。
  「是否重复授权」要按业务判断，不能假定有唯一键兜底——先用 `SHOW CREATE TABLE sys_role_menu` 确认实际索引。
- 备份/回滚要按 `Id` 对齐，不能按 `(role_id, menu_id)` 去重。

## 菜单类型与前端路由契约

`MenuType` 值域取自 `UserConst`（`Domain/Domain.Shared/Consts` 或其引用处的 `UserConst.cs:66-76`）：

| 值 | 含义 |
|---|---|
| `M` | 目录（只做分组，不对应页面） |
| `C` | 菜单（对应一个前端页面，`Component` 必须能解析到 .vue 文件） |
| `F` | 按钮（权限码载体，`Path` 通常是 `#`、`Component` 为空） |
| `L` | 外链 |

路由契约（依据 `Services.System/Services/Implementations/SysMenuService.cs` 的 `BuildMenus` / `GetRoutePath` / `GetComponent`）：

- 前端路由 `name` = `Path.ToLower()`；子节点 `Path` 是**相对段**，全路径由父目录拼成父 `Path + '/' + 子 Path`（`SysMenuService.cs:571-573`）。
  → **改父行的 `Path` 会连带改变其下所有子行的最终路由**。动 `Path` 前先看清它的子树。
- `Component` 必须等于前端 `IMTC.WMS.AdminUI/src/views/<Component>.vue`。
  前端用 `import.meta.glob('./../../views/**/*.vue')` 建索引，再按 `path.split('views/')[1]` 精确比对
  （`IMTC.WMS.AdminUI/src/store/modules/permission.js:12,111-120`）。
  **比对不到不会报错，页面直接白屏**——所以「`Component` 对应的页面文件是否存在」这件事 SQL 查不出来，
  必须在仓库里核对，或用一条文件检查命令确认。这是菜单类改动**唯一无法靠预检 SQL 兜住**的风险点。
- **`IsCache` 语义反直觉**：`'1'` 表示**不缓存**，`'0'` 表示缓存。列表页一般要给 `'0'`。
  （本仓既有菜单脚本把它写进头部契约注释，见 `sql/publish/v1.3.8.3/2026-09-15_add_asn_opt_arn_opt_menus.sql:16-33`。）
- `Visible`：`'0'` 显示、`'1'` 隐藏；`Status`：`'0'` 正常、`'1'` 停用。隐藏菜单在侧边栏不出现但路由仍在。

## 权限链路：一行菜单数据是怎么变成按钮可见性的

```
sys_menu(MenuType='F' 或 C 行的 Perms)
   └─ sys_role_menu（角色 ↔ 菜单分配）
        └─ 登录时聚合进用户 Permissions
             ├─ 后端 Application/Application.Contracts/Filters/ActionPermissionFilter.cs
             └─ 前端 IMTC.WMS.AdminUI/src/directive/permission/hasPermi.js / v-hasPermi
```

由此得到三条操作结论：

1. **删 `sys_menu` 行时，权限串可能一起消失。** 如果某个 F 节点是某个权限串的唯一载体，删掉它会让
   绑定了该权限的角色在后端拿到 403、在前端按钮不渲染。
   → 删前先把「将被删除的权限串」列出来留档（见 `sql/queries/q_menu_subtree_role_usage.sql` 的用法说明）。
2. **超管两边都绕过**（`*:*:*` 或 AdminRole）。所以「管理员能看到按钮」**不能**作为权限完好的证据——
   验证必须用非超管账号。
3. **权限码落点不统一**：有的权限串挂在 F 节点，有的只挂在隐藏的 C 菜单行上，有的页面干脆没有权限特性。
   不要假定「权限串一定在 F 行」，按实际 `Perms` 值去查。

## 应用侧守卫：删除菜单的两条前置

`Services.System/Services/Implementations/SysMenuService.cs:230-249`（`DeleteMenuById`）依次检查：

1. `HasChildByMenuId(menuId) > 0` → 抛「存在子菜单,不允许删除」
2. `CountByMenuId(menuId) > 0` → 抛「菜单已分配,不允许删除」
3. 通过后调用 `SoftDeleteAsync` —— **只软删 `sys_menu` 一行，不做级联**

补充事实：`DBContext.cs:82-100` 的 `EntityNameService` 把 `IsDisabledDelete = true` 写死，
所以**应用从不物理删除**；手工 SQL 若要物理删，必须自己承担备份与回滚（这也是为什么本组操作的模板都要求先建备份表）。

「取消某角色对本菜单的分配」是另一个入口：`CancelMenuRole`（`SysMenuService.cs:453-473`，
接口 `DELETE {menuId}/role/{roleId}`，权限 `system:role:authorize`），
底层是 `SysRoleMenuRepository.DeleteByRoleIdAndMenuId`。也就是说**「清理分配」和「删菜单」是两个独立动作**，
要合并成一次操作必须自己写脚本按顺序做。

## 三类操作的 guard 清单与顺序

### 清理菜单（要删的行必须无子菜单、无角色分配）

顺序**不能颠倒**：

1. **先看子树**：列出待删行及其全部子孙（`q_menu_subtree_role_usage.sql` 的递归部分可直接用）。
2. **先补授权**：只分配在待删行、未分配在保留行的角色，先补一条到保留行。
   → 只有这样，第 3 步清掉待删行的分配才不会让任何角色失去入口。
3. **清分配**：删掉待删子树内所有菜单行的 `sys_role_menu` 行（含历史软删行，避免留孤儿）。
4. **先子后父删菜单行**：先删子孙行，再删待删行本身——因为第 5 步的守卫要求「无子菜单」。
5. **删待删行**，条件里内联应用的两条守卫（`NOT EXISTS` 子菜单 + `NOT EXISTS` 分配），fail-closed。
   注意 MySQL 的 `ERROR 1093`：在 `DELETE` 的 `WHERE` 里子查询同一张表要用派生表包一层
   （`WHERE NOT EXISTS (SELECT 1 FROM (SELECT ... FROM sys_menu WHERE ParentId = ?) t)`）。

模板：`sql/operations/menu_cleanup.sql`。

### 更新菜单（改显示名、`Path`、`Component`、排序、显隐）

- **字段白名单**：`MenuName` / `Path` / `Component` / `Icon` / `IsCache` / `IsFrame` / `MenuType` /
  `Visible` / `Status` / `OrderNum` / `Perms`。其它列（`Id` / `ParentId` / `IsDeleted` / 审计列）不要顺手改。
- **必须带 `Id` + 条件收窄**，禁止无条件全表更新（`sql/index.md` 维护规则 5）。
- **改 `Path` 要连子树一起想**：父行 `Path` 是子行路由的拼接前缀（见上）。
- **改 `Component` 前先确认页面文件存在**，且全库没有第二行挂着同一个 `Component`
  （否则两个菜单指向同一页面，前端按 `Component` 匹配时行为不可预期）。
- `CreateBy`/`CreateOn` 不动；写 `UpdateBy`/`UpdateOn` 留痕（既有脚本统一写 `'script'`）。

模板：`sql/operations/menu_update.sql`。

### 新增菜单（本阶段未落地模板）

留到下一阶段。届时同样要固化：父节点唯一命中 fail-closed、`OrderNum` 动态取 `MAX+1`、
`Component` 冲突预检、候选 `Id` 冲突预检、**不自动授权任何角色**（既有脚本的一致约定：新建菜单后由管理员在
「系统管理 → 角色管理」里手工勾选）。可参照
`D:\Project\WMS\sql\publish\v1.3.8.3\2026-09-15_add_asn_opt_arn_opt_menus.sql` 的骨架。

## 备份与回滚

- **备份要在事务之外**：`CREATE TABLE ... AS/LIKE` 是 DDL，MySQL 会隐式提交，写进 `START TRANSACTION` 里会破坏事务边界。
- 备份范围要**覆盖整棵待删子树**，而不只是那一行；否则回滚时会缺子行与它们的分配。
- 递归取子树在 MySQL 8 用 `WITH RECURSIVE`；段0.1 顺手确认 `VERSION()` 与 `@@cte_max_recursion_depth`。
  5.7 没有窗口函数与递归 CTE，`ROW_NUMBER()`、`WITH RECURSIVE` 都会失败。
- 物理删除了就**没有应用层后悔药**（应用只有软删）。确认运行期无问题前不要删备份表。

## 证据状态

- **状态：未验证**（代码证据充分，尚未在任何真实库上执行或复核）
- 最后整理时间：2026-10-13
- 适用路由：不限据点（`sys_menu` 是每库独立的一份数据）；本组结论首次落地时使用的路由是 `dev.lebgjm`
- 证据来源：`IMTC.WMS.AdminWebApi` 下的 `SysMenu.cs` / `SysRoleMenu.cs` / `TableEntityAbstract.cs` /
  `DBContext.cs` / `SysMenuService.cs` / `SysMenuController.cs` / `UserConst.cs`；
  `IMTC.WMS.AdminUI` 下的 `store/modules/permission.js` / `directive/permission/hasPermi.js`；
  以及 `D:\Project\WMS\sql\` 下既有菜单脚本与其日志。

### 残留不确定性

- `sys_user_role` 的列名未逐字核对（按同族实体推定蛇形），用前 `SHOW COLUMNS` 确认。
- `sys_role_menu` 上是否真有 `(role_id, menu_id)` 唯一键未确认——`SHOW CREATE TABLE` 说了算。
- 「`CancelMenuRole` 是否软删分配行」未逐行核对：如果是软删，那么「已分配的判断」在应用侧按 `IsDeleted=0` 计，
  而库里会累积软删行——这会影响「分配数」统计口径与备份行数预期。
- 上文所有行号来自 2026-10-13 的工作区快照，代码变更后需复核。
