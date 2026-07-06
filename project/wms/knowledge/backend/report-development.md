# WMS 报表开发参考

> 最后更新: 2026-07-06

## 查询策略（可选方案，由用户/场景定夺）

WMS 报表分页和导出可采用不同查询策略，无需强制统一：

### 方案A：分页单表 + 导出 JOIN（推荐大数据量）

| 路径 | 策略 | 适用场景 |
|------|------|----------|
| 分页 | 主表单表查询 → 分页 → 按ID后填充关联表 | 分页行数少（15~800），单表分页走索引快 |
| 导出 | 联表 JOIN → COUNT → ToList → 共享后填充 | 导出需全量数据，JOIN 减少往返 |

共享方法提取：
- `CollectFilterIdsAsync`：预查询条件ID统一收集
- `ApplyWhereConditions`：条件拼接（可分单表/JOIN两个版本）
- `LoadRelatedDataAsync`：按ID批量加载关联数据
- `FillDtoRows`：逐行填充DTO字段

### 方案B：统一 JOIN（适合小数据量表）

分页和导出都用 JOIN 查询，简单直接，适合主表数据量 < 10w 的场景。

### 选择依据

- 主表 > 50w 且有 1:N 关联表 → 方案A
- 主表 < 10w 且关联简单 → 方案B
- 标签级报表（千万级）→ 必须方案A，分页走标签表+明细两表JOIN

## 导出数量限制

- **必须**先 `CountAsync` 判断总数，符合阈值再 `ToList`
- **禁止**使用 `pageSize=100000` 等 hack 方式限制导出数量
- 阈值默认 500000，抛出明确提示引导用户缩小查询范围

## 路由规范

- 查询：`report/{domain}/{entity}/{report-type}`
- 导出：`report/{domain}/{entity}/{report-type}/export`

示例：
- `report/instock/receipt/order` — 入库收货单综合报表
- `report/instock/receipt/order/export` — 导出入库收货单综合报表

## 命名规范

- Service 方法：`Get{Domain}{Entity}{Type}ReportListAsync` / `Export{Domain}{Entity}{Type}ReportAsync`
- DTO：`{Domain}{Entity}{Type}ReportDto` / `QueryDto` / `ExportDto`
- 前端 API 函数：`get{Domain}{Entity}{Type}ReportList` / `export{Domain}{Entity}{Type}Report`
- 其中 `{Type}` 表示报表类型，由具体业务命名

## 禁止事项

- 禁止使用 `dynamic` 类型
- 禁止使用反射/元数据（`GetType()`、`GetProperties()`、`PropertyInfo` 等）
- 禁止在匿名类型 Select 中使用 `new { }`，改为具名私有类承接
- 禁止在报表 Service 中引入新的外部依赖

## 导出注意事项

- 导出路径**不加** `ORDER BY`，大数据量排序开销大
- 大 `IN (ids)` 查询必须分批（2000/批）+ `Task.WhenAll` 并行，避免 MySQL 全表扫

## 后置填充性能

- 关联数据用 `ILookup<long, T>` 承接，`FillDtoRows` 中用索引器 `[key]` 替代 `.Where()` 扫描
- 禁止在循环体内对 `List<T>` 做 `.Where()` 线性查找（O(n×m) → O(n)）

## 默认排序

- 分页和导出均应 `ORDER BY Id DESC`，雪花主键自带时间排序
- 走主键聚簇索引反向扫描，零额外成本（无 filesort）
- 叠加其他排序字段时，`Id DESC` 作为次级排序保证稳定顺序

## 列标签规范

- 人员字段必须区分工号和名称，如 `提交人工号` / `提交人名称`
- 禁止工号和名称共用同一个 label

## 注释规范

- 禁止在注释中写 `@author`、`@date` 等作者信息
- `/// <summary>` 保持一行，不写实现细节

## Build 验证

- `dotnet build <project> /p:WarningLevel=0` — 抑制全量警告，仅看错误
- 错误必须清零，警告不阻塞
