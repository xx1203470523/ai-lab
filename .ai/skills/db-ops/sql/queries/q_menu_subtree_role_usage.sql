-- 用途：按菜单名 / Component 关键字找出相关菜单行，连同其子树与每行的角色分配数；
--       用于菜单合并、清理、改路由前的「影响面 + 谁在用」一次性摸底。
-- 路由：不限据点（sys_menu 是每库独立的一份数据）；最近一次拟定使用路由 dev.lebgjm（库名：wms_lebg）。
-- 实体依据：IMTC.WMS.AdminWebApi/Domain/Domain.System/Entities/SysMenu.cs（列名 PascalCase）
--           IMTC.WMS.AdminWebApi/Domain/Domain.System/Entities/Relationships/SysRoleMenu.cs:13,19
--           （sys_role_menu 的列是蛇形 menu_id / role_id，写 MenuId 会报 Unknown column）
-- 软删除：sys_menu 与 sys_role_menu 都实现 IDeletedFilter → 加 IsDeleted = 0（菜单行）；
--         sys_role_menu 的分配数按 IsDeleted = 0 统计，与登录时聚合权限的口径一致。
-- 收窄条件：<菜单名关键字>、<组件关键字> 必须替换；两处都支持模糊匹配，传空串会命中全部菜单。
-- 验证时间：未验证（2026-10-13 编写，尚未在真实库上跑通）
--
-- 已知局限：
--   1. 只按 MenuName / Component 匹配，匹配不到「权限串相同但名字与组件都不同」的行——
--      需要按权限串反查时改 WHERE 为 Perms LIKE '%<权限码>%' 并去掉子树展开。
--   2. 子树展开依赖 ParentId，如果库里存在 ParentId 断链的历史行，它们不会出现在结果里。
--   3. 前端页面文件是否存在 SQL 查不出来（Component 解析不到是白屏，不报错），需另行在仓库核对。
--   4. 只反映库内现状，不反映前端按钮实际用到哪些权限码（那要去 AdminUI 里搜 HasPermiButton）。

-- -----------------------------------------------------------------------------
-- 用法：只想看命中的那几行时跑 A；想看命中行 + 其子树 + 角色数时跑 B。
-- -----------------------------------------------------------------------------
SET @menu_keyword := '<菜单名关键字>';    -- 例：'上架'
SET @comp_keyword := '<组件关键字>';      -- 例：'upShelves' 或 'up-shelves'

-- A. 命中行（含其直接子行），带角色分配数
SELECT m.Id, m.ParentId, m.OrderNum, m.MenuName, m.MenuType, m.Path, m.Component,
       m.Visible, m.Status, m.Perms,
       COUNT(DISTINCT CASE WHEN rm.IsDeleted = 0 THEN rm.role_id END) AS RoleCount
FROM `sys_menu` m
LEFT JOIN `sys_role_menu` rm ON rm.menu_id = m.Id
WHERE m.IsDeleted = 0
  AND (m.MenuName LIKE CONCAT('%', @menu_keyword, '%')
       OR m.Component LIKE CONCAT('%', @comp_keyword, '%')
       OR m.ParentId IN (SELECT Id FROM (SELECT Id FROM `sys_menu`
                                         WHERE IsDeleted = 0
                                           AND (MenuName LIKE CONCAT('%', @menu_keyword, '%')
                                                OR Component LIKE CONCAT('%', @comp_keyword, '%'))) t))
GROUP BY m.Id, m.ParentId, m.OrderNum, m.MenuName, m.MenuType, m.Path, m.Component,
         m.Visible, m.Status, m.Perms
ORDER BY m.ParentId, m.OrderNum, m.Id;

-- B. 命中行 + 其全部子孙（任意层级），带角色分配数与将被波及的权限串
WITH RECURSIVE hits AS (
    SELECT * FROM `sys_menu`
    WHERE IsDeleted = 0
      AND (MenuName LIKE CONCAT('%', @menu_keyword, '%')
           OR Component LIKE CONCAT('%', @comp_keyword, '%'))
    UNION ALL
    SELECT c.* FROM `sys_menu` c JOIN hits p ON c.ParentId = p.Id
)
SELECT h.Id, h.ParentId, h.OrderNum, h.MenuName, h.MenuType, h.Path, h.Component,
       h.Visible, h.Status, h.Perms, h.IsDeleted,
       (SELECT COUNT(DISTINCT rm.role_id) FROM `sys_role_menu` rm
        WHERE rm.IsDeleted = 0 AND rm.menu_id = h.Id) AS RoleCount,
       (SELECT COUNT(*) FROM `sys_menu` c WHERE c.ParentId = h.Id) AS ChildCount
FROM hits h
ORDER BY h.ParentId, h.OrderNum, h.Id;

-- C. 这些行分别被哪些角色分配（判断「清理后谁会影响」）
WITH RECURSIVE hits AS (
    SELECT * FROM `sys_menu`
    WHERE IsDeleted = 0
      AND (MenuName LIKE CONCAT('%', @menu_keyword, '%')
           OR Component LIKE CONCAT('%', @comp_keyword, '%'))
    UNION ALL
    SELECT c.* FROM `sys_menu` c JOIN hits p ON c.ParentId = p.Id
)
SELECT r.Id, r.RoleName, r.RoleKey, r.Status AS RoleStatus,
       rm.menu_id, h.MenuName, h.MenuType, h.Perms
FROM `sys_role_menu` rm
JOIN hits h ON h.Id = rm.menu_id
JOIN `sys_role` r ON r.Id = rm.role_id
WHERE rm.IsDeleted = 0
ORDER BY r.Id, rm.menu_id;
