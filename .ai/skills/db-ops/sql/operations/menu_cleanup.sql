-- =============================================================================
-- 模板：清理菜单（WMS sys_menu / sys_role_menu）
-- =============================================================================
-- 用途：删除一行菜单及其名下子树，并清理相关的角色分配。**这是写模板，技能不会执行它。**
-- 适用：WMS；表名/列名契约与守卫依据见 references/projects/wms/menu-management.md
-- 软删除：sys_menu 与 sys_role_menu 都实现 IDeletedFilter；本模板按「物理删除」处理，
--         因此**必须先建备份表**，回滚只能靠备份表反写。
-- 非幂等：删除段重复执行第二次无行可删；备份表用 IF NOT EXISTS 不会覆盖首次快照。
-- 事务性：备份段是 DDL，会隐式提交，必须在 START TRANSACTION 之前。
--
-- 执行前必读
--   1. 先只跑「段0 预检」，把待删子树、角色差异、将被删除的权限串列出来核对。
--   2. 若待删子树里某条权限串是唯一载体（保留行侧没有），删掉会让非超管账号丢按钮权限，
--      此时应改走「迁移」而不是删除——见文件末尾的备用分支。
--   3. 「角色不失去入口」的前提是段3先补齐授权；不想补就不要用本模板的删除顺序。
--
-- 应用侧守卫（本模板与之一致）：SysMenuService.DeleteMenuById
--   ① 有子菜单不删 ② 有角色分配不删 ③ 应用删除不做级联，且从不物理删除
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 段0 预检（只读）
-- -----------------------------------------------------------------------------
-- SET @menu_id := <待删菜单Id>;
SET @menu_id := <待删菜单Id>;

-- 0.1 该行本身
SELECT Id, ParentId, OrderNum, MenuName, MenuType, Path, Component, Visible, Status, Perms, IsDeleted
FROM `sys_menu` WHERE Id = @menu_id;

-- 0.2 整棵子树（任意层级）——将被一并删除的菜单行
WITH RECURSIVE sub AS (
    SELECT * FROM `sys_menu` WHERE Id = @menu_id
    UNION ALL
    SELECT c.* FROM `sys_menu` c JOIN sub p ON c.ParentId = p.Id
)
SELECT Id, ParentId, OrderNum, MenuName, MenuType, Path, Component, Visible, Status, Perms, IsDeleted
FROM sub ORDER BY ParentId, OrderNum, Id;

-- 0.3 将被一并删除的权限串（留档：后续若按钮权限缺失，先对照这份清单）
WITH RECURSIVE sub AS (
    SELECT * FROM `sys_menu` WHERE Id = @menu_id
    UNION ALL
    SELECT c.* FROM `sys_menu` c JOIN sub p ON c.ParentId = p.Id
)
SELECT s.Id, s.MenuName, s.MenuType, s.Perms,
       (SELECT COUNT(DISTINCT rm.role_id) FROM `sys_role_menu` rm
        WHERE rm.IsDeleted = 0 AND rm.menu_id = s.Id) AS RoleCount
FROM sub s
WHERE s.Perms IS NOT NULL AND s.Perms <> ''
ORDER BY s.Id;

-- 0.4 分配了待删行、需要先补到保留行的角色（无保留行时跳过段3）
--      注意：sys_role_menu 的列是蛇形 menu_id / role_id，写成 MenuId 会报 Unknown column
SET @keep_id := <保留菜单Id>;
SELECT DISTINCT rm.role_id
FROM `sys_role_menu` rm
WHERE rm.IsDeleted = 0 AND rm.menu_id = @menu_id
  AND rm.role_id NOT IN (SELECT role_id FROM `sys_role_menu`
                         WHERE IsDeleted = 0 AND menu_id = @keep_id)
ORDER BY rm.role_id;

-- 0.5 补授权 Id 段空闲校验（必须为 0，否则换一个 @id_base）
SET @id_base := <补授权Id基址>;   -- 例：202610131200000001
SELECT COUNT(*) AS IdRangeOccupied FROM `sys_role_menu`
WHERE Id BETWEEN @id_base AND @id_base + 200;


-- -----------------------------------------------------------------------------
-- 段1 备份（DDL，必须在 START TRANSACTION 之前；备份范围=整棵子树+其全部分配）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `bak_sys_menu_menu_cleanup` LIKE `sys_menu`;
CREATE TABLE IF NOT EXISTS `bak_sys_role_menu_menu_cleanup` LIKE `sys_role_menu`;

INSERT INTO `bak_sys_menu_menu_cleanup`
WITH RECURSIVE sub AS (
    SELECT * FROM `sys_menu` WHERE Id IN (@menu_id, @keep_id)
    UNION ALL
    SELECT c.* FROM `sys_menu` c JOIN sub p ON c.ParentId = p.Id
)
SELECT * FROM sub;

INSERT INTO `bak_sys_role_menu_menu_cleanup`
SELECT rm.* FROM `sys_role_menu` rm
WHERE rm.menu_id IN (SELECT b.Id FROM `bak_sys_menu_menu_cleanup` b);

SELECT (SELECT COUNT(*) FROM `bak_sys_menu_menu_cleanup`) AS BakMenuRows,
       (SELECT COUNT(*) FROM `bak_sys_role_menu_menu_cleanup`) AS BakRoleMenuRows;


-- -----------------------------------------------------------------------------
-- 段2 清理（一个事务内；任一句报错就手动 ROLLBACK）
-- -----------------------------------------------------------------------------
START TRANSACTION;

-- 2.1 先补齐授权：只挂待删行、未挂保留行的角色，补一条到保留行（幂等）
INSERT INTO `sys_role_menu`
    (`Id`, `role_id`, `menu_id`, `CreateBy`, `CreateOn`, `UpdateBy`, `UpdateOn`, `IsDeleted`, `Remark`)
SELECT @id_base + ROW_NUMBER() OVER (ORDER BY t.role_id), t.role_id, @keep_id,
       'script', CURRENT_TIMESTAMP(6), 'script', CURRENT_TIMESTAMP(6), 0, '菜单合并补齐授权'
FROM (SELECT DISTINCT rm.role_id FROM `sys_role_menu` rm
      WHERE rm.IsDeleted = 0 AND rm.menu_id = @menu_id
        AND rm.role_id NOT IN (SELECT role_id FROM `sys_role_menu`
                               WHERE IsDeleted = 0 AND menu_id = @keep_id)) t;
SELECT ROW_COUNT() AS FixupInsertedRows;

-- 2.2 清掉子树内所有菜单行的角色分配（含历史软删行，避免留孤儿）
DELETE FROM `sys_role_menu`
WHERE menu_id IN (SELECT Id FROM `bak_sys_menu_menu_cleanup` WHERE Id <> @keep_id);
SELECT ROW_COUNT() AS DeletedRoleMenuRows;

-- 2.3 先删子孙行（任意层级，不假设只有两层）
DELETE FROM `sys_menu`
WHERE Id IN (SELECT Id FROM `bak_sys_menu_menu_cleanup` WHERE Id NOT IN (@menu_id, @keep_id));
SELECT ROW_COUNT() AS DeletedDescendantRows;

-- 2.4 再删待删行本身；守卫内联应用的两条前置（无子菜单 + 无角色分配）
--     派生表包一层是为了绕开 MySQL ERROR 1093（不能在 DELETE 的子查询里直接读同一张表）
DELETE FROM `sys_menu`
WHERE Id = @menu_id
  AND NOT EXISTS (SELECT 1 FROM (SELECT Id FROM `sys_menu` WHERE ParentId = @menu_id) t1)
  AND NOT EXISTS (SELECT 1 FROM (SELECT Id FROM `sys_role_menu` WHERE menu_id = @menu_id) t2);
SELECT ROW_COUNT() AS DeletedMenuRows;   -- 必须为 1；为 0 说明守卫拦住了，先查原因

COMMIT;


-- -----------------------------------------------------------------------------
-- 段3 复核
-- -----------------------------------------------------------------------------
-- 3.1 待删子树残留（三项都必须为 0）
SELECT (SELECT COUNT(*) FROM `sys_menu` WHERE Id = @menu_id) AS MenuLeft,
       (SELECT COUNT(*) FROM `sys_menu` WHERE ParentId = @menu_id) AS ChildLeft,
       (SELECT COUNT(*) FROM `sys_role_menu`
        WHERE menu_id IN (SELECT Id FROM `bak_sys_menu_menu_cleanup` WHERE Id <> @keep_id)) AS RoleMenuLeft;

-- 3.2 角色授权并集：保留行现有角色数应 >= 执行前两行并集，MissingRoleCount 应为 0
SELECT (SELECT COUNT(DISTINCT role_id) FROM `bak_sys_role_menu_menu_cleanup`
        WHERE menu_id IN (@menu_id, @keep_id)) AS OrigUnionRoleCount,
       (SELECT COUNT(DISTINCT role_id) FROM `sys_role_menu`
        WHERE IsDeleted = 0 AND menu_id = @keep_id) AS KeepRoleCountNow,
       (SELECT COUNT(DISTINCT b.role_id) FROM `bak_sys_role_menu_menu_cleanup` b
        WHERE b.menu_id IN (@menu_id, @keep_id)
          AND b.role_id NOT IN (SELECT role_id FROM `sys_role_menu`
                                WHERE IsDeleted = 0 AND menu_id = @keep_id)) AS MissingRoleCount;


-- -----------------------------------------------------------------------------
-- 段4 回滚（默认注释；在确认运行期无问题前不要删备份表）
-- -----------------------------------------------------------------------------
/*
START TRANSACTION;
DELETE FROM `sys_role_menu`
WHERE Remark = '菜单合并补齐授权' AND CreateBy = 'script'
  AND menu_id = @keep_id AND Id BETWEEN @id_base AND @id_base + 200;

INSERT INTO `sys_menu`
SELECT b.* FROM `bak_sys_menu_menu_cleanup` b
LEFT JOIN `sys_menu` m ON m.Id = b.Id WHERE m.Id IS NULL;

INSERT INTO `sys_role_menu`
SELECT b.* FROM `bak_sys_role_menu_menu_cleanup` b
LEFT JOIN `sys_role_menu` rm ON rm.Id = b.Id WHERE rm.Id IS NULL;
COMMIT;
*/


-- -----------------------------------------------------------------------------
-- 备用分支（默认注释）：子树里的权限节点必须保留时，改走「迁移」而不是删除
-- 做法 = 把子孙挂到保留行，再删待删行；执行位置在段2.2 之后、段2.3 之前，并跳过 2.3
-- -----------------------------------------------------------------------------
/*
UPDATE `sys_menu`
SET ParentId = @keep_id, UpdateBy = 'script', UpdateOn = CURRENT_TIMESTAMP(6)
WHERE Id IN (SELECT Id FROM `bak_sys_menu_menu_cleanup` WHERE Id NOT IN (@menu_id, @keep_id));
*/
