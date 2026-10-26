# 新增 WMS 菜单/权限管理的模板与 profile 文档

- 日期：2026-10-13
- 变更类型：技能文档与 SQL 模板（**不改任何 `.ps1` 行为**，离线用例条数不变）

## 为什么加

用户提出「把 WMS 菜单管理纳入脚本管理」，先要覆盖两类操作：**清理菜单**（要删的行必须没有分配的角色）
与**更新菜单**；新增菜单留到下一阶段。

这两类操作在项目仓库里已有多个先例脚本（`D:\Project\WMS\sql\publish\` 下），但每次都要重新推一遍
守卫条件与执行顺序，且踩过同一个坑（`sys_role_menu` 的列名）。所以本轮把「守卫 + 顺序 + 列名契约」
沉淀成本技能的模板与 profile 文档，让下一次不必重推。

## 加了什么

| 文件 | 内容 |
|---|---|
| `references/projects/wms/menu-management.md` | 菜单管理的完整边界：列名契约、`MenuType` 值域、`Path`/`Component`/`IsCache` 路由契约、权限链路、应用删除守卫、三类操作的 guard 与顺序、备份与回滚要求 |
| `sql/operations/menu_cleanup.sql` | 清理菜单模板：先补角色 → 再清分配 → 先子后父删行，守卫内联应用的两条前置；含备份段与注释回滚段 |
| `sql/operations/menu_update.sql` | 更新菜单模板：字段白名单、`Id` + `IsDeleted` 收窄、`Component`/`Path` 冲突预检、子树路由影响面核对 |
| `sql/queries/q_menu_subtree_role_usage.sql` | 只读：按关键字列出菜单行 + 子树 + 每行角色分配数 + 分配了这些行的角色清单 |
| `sql/README.md` | 新增「`operations/` 与项目仓库发布 SQL 的区别」一节，明确三边（项目仓库 / `queries/` / `operations/`）的归属判据 |
| `sql/index.md` | 登记 `q_menu_subtree_role_usage.sql`（`operations/` 的模板不登记，理由见 `README.md`） |
| `SKILL.md` | 目录结构树补 `operations/` 与 profile 文档；能力边界补一行 |

## 守卫从哪来（不是自己发明的）

「清理菜单必须没有分配的角色」这条规则来自应用代码，不是约定俗成：

`IMTC.WMS.AdminWebApi/Services/Services.System/Services/Implementations/SysMenuService.cs:230-249`
（`DeleteMenuById`）依次检查 ① 无子菜单 ② 无角色分配，通过后只软删 `sys_menu` 一行、**不做级联**。
模板里的 `NOT EXISTS` 守卫与之一一对应。

顺序（先补角色 → 再清分配 → 先子后父删行）是这三条事实的必然结果，不是风格选择：
清理分配会让「已分配」变「未分配」，所以补授权必须在清理之前；「无子菜单」是删父行的前置，所以子行必须先删。

## 验证方式

**已做的（离线）**

- `.ps1` 一个都没改：`lib/` 与 `scripts/` 未新增、未修改函数，因此离线用例预期条数不变。
  命令：`powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\db-ops\tests\run-offline-tests.ps1"`
- 列名契约对照过两处独立证据：实体映射（`SysRoleMenu.cs:13,19` 的 `ColumnName`）与
  项目仓库既有日志里对同类错误的记录（`D:\Project\WMS\sql\logs\2026-09-24\add-inventory-count-task-approve-permission.md:50-77`，点名 4 个老脚本误用 `MenuId`）。
- `operations/` 下的 SQL 是写语句，**不过只读守卫**（守卫只对 `Query`/`File` 的 SQL 生效），
  因此改为人工审阅：与 `SysMenuService.DeleteMenuById` 的两条前置逐条对照。

**没做的（必须写明）**

- **三个 SQL 文件都没有在任何真实库上执行过，`q_menu_subtree_role_usage.sql` 也没有跑通过。**
  本机没有 MySQL 客户端，凭据文件也未建立，阶段 1 不连库——所以语法、结果口径、行数预期都未经实测。
  第一次使用前请先在只读场景下跑 `queries/q_menu_subtree_role_usage.sql`（只读、无副作用），
  确认无误后再考虑写模板；跑通后把实测结论回填 `sql/index.md` 的「验证时间」与 profile 文档。

## 已知局限

1. 模板用的是 MySQL 8 语法（`ROW_NUMBER()`、`WITH RECURSIVE`）。5.7 上会失败，需要改写。
2. `operations/` 的模板不登记进 `sql/index.md`，因此**索引不是「技能里所有 SQL」的完整清单**——
   `queries/` 才是被索引的那一半。这是刻意的：索引的用途是找可复用只读查询。
3. 模板的备份表名是固定的占位名（`bak_sys_menu_menu_cleanup` 等）。实例化到项目仓库时必须换成
   带日期的具体名（既有约定：`bak_<表>_<用途>_<yyyyMMdd>`），否则同一天多次操作会互相覆盖。
4. `menu_update.sql` 不负责改层级（`ParentId`）：改层级会连带改变子树路由，需要单独评估，模板里有提示但不代做。
