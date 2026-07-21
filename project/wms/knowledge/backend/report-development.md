# WMS 报表开发参考

> 最后更新: 2026-07-21
> 来源：入库综合报表多轮性能优化实战 + COUNT/数据查询分离重构
> 变更：COUNT 与数据查询分离原则；移除 Clone/MergeTable 模式；ToPageAsync 双查询说明

---

## 一、规范

### 1.1 查询门禁（最高优先级）

- **必须**有时间条件兜底，禁止任何无时间条件的全表查询/导出。
- 查询入口统一校验：无时间条件 → 自动补默认范围；超出最大跨度 → 抛业务异常。
- 默认时间范围应设计为使预估数据量不超过 10w，在此基础上提供合理的查询体验。
- **时间范围限制前后端均需校验**：后端抛异常拦截，前端禁用导出按钮 + 弹出提示。
- 时间条件是防全表扫的核心机制，JOIN 数量不是。

| 数据量级         | 默认时间 | 最大跨度 |
| ---------------- | -------- | -------- |
| 千万级（标签表） | 近一周   | 一个月   |
| 百万级（明细表） | 近一个月 | 一个月   |
| 十万级以下       | 近一个月 | 三个月   |

### 1.2 导出保护

- **必须**先 `CountAsync` 判断总数，符合阈值再执行。
- **禁止**使用 `pageSize=100000` 等 hack 方式限制导出数量。
- 阈值 100000，超出抛出明确提示引导用户缩小查询范围。
- **报表级用户锁**：锁 Key = `报表标识 + 用户 ID`，同一用户在同一报表上的操作未完成前禁止重复触发。用 `ICachingService.LockAsync` 加锁，操作结束后 `finally` 释放。不同报表之间不互斥。

### 1.3 禁止事项

- 禁止 `dynamic` 类型
- 禁止反射/元数据（`GetType()`、`GetProperties()`、`PropertyInfo`）
- 匿名类型 `new { }` 改为具名私有类承接
- 禁止报表 Service 引入新外部依赖

### 1.4 排序

- 查询**不加** `ORDER BY`。雪花 ID 主键 + 聚簇索引自然有序，避免排序开销。

### 1.5 列标签

- 人员字段必须区分工号和名称：`提交人工号` / `提交人名称`。
- 禁止工号和名称共用同一个 label。

### 1.6 注释

- 禁止 `@author`、`@date` 等作者信息。
- `/// <summary>` 保持一行，不写实现细节。

### 1.7 Build 验证

- `dotnet build <project> /p:WarningLevel=0` — 抑制全量警告，仅看错误。
- 错误必须清零，警告不阻塞。

---

## 二、核心模式

### 2.1 统一查询：最小 JOIN + 后置填充

分页和导出**共用同一个查询构建器**。性能不由"分页少 JOIN / 导出多 JOIN"决定，而由时间条件决定。

查询构建器规则：

- **最小 JOIN**：只 JOIN 筛选条件（WHERE）需要的表，SELECT 字段不驱动 JOIN。
- **跨表筛选用 EXISTS**：关联表条件通过 `SqlFunc.Subqueryable<T>().Where(...).Any()` 内联。
- **SELECT 只取主表 + JOIN 表的核心字段**，其余字段后置 Fill 补齐。
- 分页走 `BuildQuery().ToPageAsync()` → `FillDataAsync()`（ToPageAsync 内置 COUNT + 数据双查询）。
- 导出走 `BuildCountQuery().CountAsync()` 先判断阈值 → 通过后 `BuildDataQuery().ToListAsync()` → `FillDataAsync()`。
- 大数据量场景 COUNT 和数据查询**分离**，避免 Clone/MergeTable 的 SQL 膨胀。

关键约束：

- **禁止**分页和导出各写一个查询构建器
- **禁止**为 SELECT 字段而 JOIN 表（走 Fill）

### 2.2 EXISTS 替代预查 ID + IN

先查 ID 列表再 `WHERE Id IN (40w)`，ID 上万后 MySQL 优化器弃索引走全表扫。用 `SqlFunc.Subqueryable<T>().Where(...).Any()` 内联 EXISTS，每个条件独立推入数据库。

| 维度     | 预查 ID + IN               | EXISTS 子查询            |
| -------- | -------------------------- | ------------------------ |
| DB 往返  | N 次（每个条件一次）       | 0 次                     |
| 索引利用 | ID 上万后优化器弃索引      | 优化器正常走索引         |
| 可维护性 | 预查和主查询分离，逻辑割裂 | 条件内聚在 BuildQuery 中 |

保留预查询的场景：字典数据、用户 UserName/NickName（结果 < 100）。

### 2.3 导出分批游标

导出不一次 `ToList()`，用 `CreateOn + Id` 复合游标分批取数，禁止 OFFSET 深分页。

- `ExportBatchSize` 常量，调大减少游标轮次。
- 每批 `FillDataAsync` 补齐后再写入文件，避免内存峰值。
- 游标推进：上一批最后一条的 `CreateOn` + `Id` 作为下一批的起始条件。

---

## 三、路由与命名规范

### 3.1 路由

- **控制器级**：`[Route("report/{domain}")]`，提供业务域前缀，如 `report/instock`
- **动作级**：`{entity}[/{subtype}]`，表达具体业务，如 `receipt/order`、`label`
- 导出：动作路由 + `/export`
- 动作级路由**禁止**重复控制器基路由已有的路径段

示例：

- 控制器 `[Route("report/instock")]`，动作 `[HttpGet("receipt/order")]` → `report/instock/receipt/order`
- 控制器 `[Route("report/instock")]`，动作 `[HttpGet("label")]` → `report/instock/receipt/label`
- 导出在动作路由后追加 `/export`

### 3.2 命名

- Service 方法：`Get{Domain}{Entity}{Type}ReportListAsync` / `Export{Domain}{Entity}{Type}ReportAsync`
- DTO：`{Domain}{Entity}{Type}ReportDto` / `QueryDto` / `ExportDto`
- 前端 API：`get{Domain}{Entity}{Type}ReportList` / `export{Domain}{Entity}{Type}Report`

---

## 四、后置填充

### 4.1 ILookup 替代 List.Where（必须）

循环内 `List.Where()` 导致 O(n×m) 退化。用 `ToLookup()` 做 O(1) 索引查找。

### 4.2 Fill 数据范围

主查询已 SELECT 的字段不再重复查询，Fill 仅加载主查询未覆盖的关联数据。

| 数据        | Fill 加载 | 原因                 |
| ----------- | :-------: | -------------------- |
| 用户字典    |    ✅     | 不 JOIN，数据量小    |
| 物料/仓库   |    ✅     | 不 JOIN，Fill 批量查 |
| 关联单据    |    ✅     | 1:N 关系，避免膨胀   |
| 标签/明细   |    ✅     | 数据量大，Fill 可控  |
| 状态字典    |    ✅     | 缓存友好             |

### 4.3 明细聚合

明细聚合用 `JOIN + GROUP BY` 单次查询，禁止 SELECT 中写 N×4 次关联子查询。

---

## 五、COUNT 与数据查询分离

### 5.1 ToPageAsync 双查询

系统封装的 `ToPageAsync()` 一次调用同时执行 COUNT + 分页数据查询，适合常规分页列表。大数据量导出场景应**分离**。

### 5.2 分离原则

COUNT 查询和数据查询**需求不同**，不应共用构建器：

| | COUNT 查询 | 数据查询 |
|---|---|---|
| SELECT | `SqlFunc.AggregateCount` 即可 | 业务字段 |
| JOIN | 仅筛选条件表 | 筛选条件表 + 展示字段表 |
| ORDER BY | 不需要 | 不需要（雪花 ID 自然有序） |
| Fill | 不跑 | 需 Fill |

分离后各自方法：
- `BuildCountQuery()` — 最简 COUNT，不 JOIN 展示表
- `BuildDataQuery()` — 按需 JOIN，返回数据列

### 5.3 Clone/MergeTable 问题

SqlSugar 的 `Clone()` 和 `MergeTable()` 看似方便复用查询，实际引入问题：

- **Clone()**：深拷贝整个 Queryable 对象树，大查询开销显著。
- **MergeTable()**：将原查询包装为 `SELECT * FROM (原SQL) AS a`，多一层子查询嵌套，MySQL 优化器可能生成非预期执行计划。
- 两者组合 `Clone().MergeTable().CountAsync()` 相当于深拷贝 + 子查询包裹 + COUNT，写法取巧但 SQL 膨胀。

**正确做法**：直接写独立的 `BuildCountQuery()`，返回 `ISugarQueryable<T>`，Select 只含聚合函数，避免 Clone/MergeTable。

### 5.4 导出阈值

- COUNT 常量 `ExportMaxRows` 建议 100000。
- GROUP BY 聚合报表 COUNT 需单独处理去重逻辑。

---

## 六、反模式

| 反模式                        | 为什么不行                                  |
| ----------------------------- | ------------------------------------------- |
| 无时间条件查询                | 全表扫，数据量大时直接打挂 DB               |
| 分页和导出各写查询构建器      | 重复逻辑，维护成本翻倍                      |
| 为 SELECT 字段 JOIN 表        | JOIN 膨胀主查询，时间条件才是筛选关键       |
| 预查 ID + `WHERE Id IN (40w)` | MySQL 优化器弃索引走全表扫                  |
| `pageSize=100000` 做导出      | 语义混乱、内存不可控                        |
| SELECT 中 N×4 关联子查询      | 10w 行 = 40w 次子查询                       |
| `List.Where()` 在循环内       | O(n×m) 线性退化                             |
| `Clone().MergeTable()` 做 COUNT | 深拷贝 + 子查询嵌套，SQL 膨胀                |
| COUNT 复用数据查询构建器       | COUNT 不需要展示字段和展示 JOIN，应独立构建  |

---

## 七、CommonService 通用逻辑抽取

多报表共用的处理逻辑**必须**抽入 `CommonService`，禁止在各 `{Domain}ReportService` 中重复实现相同的辅助方法。

### 7.1 典型归属

| 类别      | 示例                                                 | 入 CommonService 理由            |
| --------- | ---------------------------------------------------- | -------------------------------- |
| 日期处理  | 默认时间范围计算、跨度校验、`DateTime?`→格式化字符串 | 每个报表入口都调用               |
| 名称解析  | 用户字典批量填充（UserId→NickName、CreateBy→姓名）   | 后置填充几乎所有报表复用         |
| 名称拼接  | 多个字段组装显示名（`工号/名称` 格式）               | 列标签规范化要求一致             |
| 字典映射  | 状态码→中文描述、枚举值→前端展示文本                 | 导出行内容一致性依赖             |
| 数量/阈值 | `ExportMaxRows` 检查、`CountAsync` 阈值判断          | 门禁规则统一，禁止各报表各自定义 |

### 7.2 约束

- **禁止**在 CommonService 中写业务判断逻辑（如"质检状态是 A 则显示 X"），业务逻辑留在各 Domain Service
- **禁止**在 CommonService 中引入报表专用 DTO 依赖——参数用基础类型或通用接口
- CommonService 方法的单元测试必须覆盖所有使用该方法的报表场景

---

---

## 八、查询从库

报表 SELECT 查询建议走只读从库，降低主库压力：

- `BuildCountQuery` / `BuildDataQuery` 走从库数据源。
- 导出锁、文件写入等非查询操作走主库。
- 从库连接串独立配置（如 `SqlSugarClient` 双实例或 `ConnectionConfig` 多库切换）。
- 新增报表时在 Service 层注入从库 `ISqlSugarClient`，不与主库业务混用。
- 从库同步延迟敏感的场景（如"刚入库立即查报表"），可在入口处降级走主库。

---

核心原则总结

禁止：

- 无时间条件查询
- 一个 SQL 解决所有问题
- 分页和导出两套查询构建器
- 为 SELECT 字段 JOIN 表
- 明细表无限 Join
- 大量 ID IN 查询
- 深分页
- 同步大数据导出
- Clone/MergeTable 做 COUNT
- COUNT 复用数据查询构建器

建议：

- 时间门禁兜底
- 最小 JOIN
- 查询模型统一
- COUNT 与数据查询分离
- 小表驱动大表
- 明细先聚合
- 维度后关联
- 游标分批导出
- 异步导出
- 文件中心管理
- 报表数据模型独立化
- 查询走从库
