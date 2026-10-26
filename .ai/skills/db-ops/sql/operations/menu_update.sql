-- =============================================================================
-- 模板：更新菜单（WMS sys_menu）
-- =============================================================================
-- 用途：改一行菜单的显示名 / 路由 / 显隐 / 排序等字段。**这是写模板，技能不会执行它。**
-- 适用：WMS；表名/列名与路由契约见 references/projects/wms/menu-management.md
-- 软删除：sys_menu 实现 IDeletedFilter，所有写条件都带 IsDeleted = 0
-- 幂等：只写固定值，可重复执行（重复执行不产生额外效果）
--
-- 字段白名单（只允许改这些；其它列不要顺手写进 SET）
--   MenuName / Path / Component / Icon / IsCache / IsFrame / MenuType / Visible / Status / OrderNum / Perms
-- 明确不要改：Id、ParentId（改层级请单独评估子树路由）、IsDeleted、CreateBy、CreateOn
--
-- 三个必须先确认的点
--   1. 改 Path 会连带改变子树路由：子行路由 = 父 Path + '/' + 子 Path（MenuName 无关，路由只认 Path）。
--      父行 Path 一动，其下所有页面的 URL 一起变。
--   2. 改 Component 前，先确认对应的前端页面文件存在：
--      IMTC.WMS.AdminUI/src/views/<Component>.vue —— 解析不到不会报错，页面直接白屏。
--   3. 改 Component 前，先确认全库没有第二行挂着同一个 Component（否则两个菜单指向同一页面）。
--
-- 反向核对：改完用 file 末尾的复核段，而不是只看「影响行数 1」。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 段0 改前快照 + 冲突预检（只读）
-- -----------------------------------------------------------------------------
-- SET @menu_id := <菜单Id>;
SET @menu_id := <菜单Id>;

-- 0.1 改前原值（贴回核对，并作为手工回滚依据）
SELECT Id, MenuName, ParentId, OrderNum, MenuType, Path, Component, Icon,
       Visible, IsCache, IsFrame, Status, Perms, IsDeleted
FROM `sys_menu` WHERE Id = @menu_id;

-- 0.2 目标 Component 是否已被别的行占用（必须为 0）
SET @new_component := <新的Component>;   -- 例：'instock/up-shelves-opt/index'
SELECT COUNT(*) AS ComponentConflict
FROM `sys_menu`
WHERE IsDeleted = 0 AND Component = @new_component AND Id <> @menu_id;

-- 0.3 目标 Path 在同级下是否已被占用（必须为 0；Path 是同级内的相对段）
SET @new_path := <新的Path>;             -- 例：'up-shelves-opt'
SELECT COUNT(*) AS SiblingPathConflict
FROM `sys_menu`
WHERE IsDeleted = 0 AND Path = @new_path
  AND ParentId = (SELECT ParentId FROM (SELECT ParentId FROM `sys_menu` WHERE Id = @menu_id) t)
  AND Id <> @menu_id;

-- 0.4 该行是否有子树（有的话，改 Path 前想清子行路由会一起变）
SELECT COUNT(*) AS ChildCount FROM `sys_menu` WHERE IsDeleted = 0 AND ParentId = @menu_id;


-- -----------------------------------------------------------------------------
-- 段1 更新（必须带 Id + IsDeleted 收窄，禁止无条件全表更新）
-- -----------------------------------------------------------------------------
START TRANSACTION;

UPDATE `sys_menu`
SET MenuName  = <新显示名>,   -- 不改就删掉这一行，不要写回原值
    Path      = @new_path,
    Component = @new_component,
    IsCache   = '0',          -- 注意语义反直觉：'1' 才是不缓存，列表页要 '0'
    IsFrame   = '0',
    MenuType  = 'C',
    Visible   = '0',          -- 0=显示 1=隐藏
    Status    = '0',          -- 0=正常 1=停用
    UpdateBy  = 'script',
    UpdateOn  = CURRENT_TIMESTAMP(6)
WHERE Id = @menu_id AND IsDeleted = 0;

SELECT ROW_COUNT() AS UpdatedRows;   -- 应为 1

COMMIT;


-- -----------------------------------------------------------------------------
-- 段2 复核
-- -----------------------------------------------------------------------------
-- 2.1 改后终值
SELECT Id, MenuName, ParentId, OrderNum, MenuType, Path, Component, Icon,
       Visible, IsCache, IsFrame, Status, Perms, IsDeleted
FROM `sys_menu` WHERE Id = @menu_id;

-- 2.2 组件唯一性复核（必须为 0）
SELECT COUNT(*) AS ComponentStillUnique
FROM `sys_menu`
WHERE IsDeleted = 0 AND Component = @new_component AND Id <> @menu_id;

-- 2.3 子树路由影响面（改了 Path 才需要看）
SELECT Id, ParentId, MenuName, MenuType, Path, Component
FROM `sys_menu` WHERE IsDeleted = 0 AND ParentId = @menu_id ORDER BY OrderNum, Id;


-- -----------------------------------------------------------------------------
-- 段3 回滚（默认注释）：把段0.1 的原值填回去
-- -----------------------------------------------------------------------------
/*
START TRANSACTION;
UPDATE `sys_menu`
SET MenuName = <原MenuName>, Path = <原Path>, Component = <原Component>,
    Icon = <原Icon>, IsCache = <原IsCache>, IsFrame = <原IsFrame>,
    MenuType = <原MenuType>, Visible = <原Visible>, Status = <原Status>, OrderNum = <原OrderNum>,
    UpdateBy = 'rollback', UpdateOn = CURRENT_TIMESTAMP(6)
WHERE Id = @menu_id AND IsDeleted = 0;
COMMIT;
*/
