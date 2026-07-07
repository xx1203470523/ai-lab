# WMS 报表开发参考

> 最后更新: 2026-07-07
> 来源：入库综合报表多轮性能优化实战

---

## 一、规范（必须遵守）

### 1.1 查询门禁

- **必须**有时间或其他高选择性条件兜底，禁止无条件全表分页/导出。
- 推荐默认近一个月 `CreateOn` 范围，时间跨度不超过一个月。
- 查询条件不足时，后端直接抛业务异常提示用户补充条件。

### 1.2 导出数量限制

- **必须**先 `CountAsync` 判断总数，符合阈值再 `ToList`。
- **禁止**使用 `pageSize=100000` 等 hack 方式限制导出数量。
- 阈值建议 100000，抛出明确提示引导用户缩小查询范围。

### 1.3 禁止事项

- 禁止 `dynamic` 类型
- 禁止反射/元数据（`GetType()`、`GetProperties()`、`PropertyInfo`）
- 匿名类型 `new { }` 改为具名私有类承接
- 禁止报表 Service 引入新外部依赖

### 1.4 导出排序

- 导出路径**不加** `ORDER BY`，大数据量排序开销大，且导出无需排序。

### 1.5 分页默认排序

- `ORDER BY Id DESC`（雪花主键自带时间排序，聚簇索引反向扫描零成本）。
- 导出不加排序。

### 1.6 列标签

- 人员字段必须区分工号和名称：`提交人工号` / `提交人名称`。
- 禁止工号和名称共用同一个 label。

### 1.7 注释

- 禁止 `@author`、`@date` 等作者信息。
- `/// <summary>` 保持一行，不写实现细节。

### 1.8 Build 验证

- `dotnet build <project> /p:WarningLevel=0` — 抑制全量警告，仅看错误。
- 错误必须清零，警告不阻塞。

---

## 二、路由与命名规范

### 2.1 路由

- 查询：`report/{domain}/{entity}/{report-type}`
- 导出：`report/{domain}/{entity}/{report-type}/export`

示例：
- `report/instock/receipt/order` — 入库收货单综合报表
- `report/instock/receipt/order/export` — 导出

### 2.2 命名

- Service 方法：`Get{Domain}{Entity}{Type}ReportListAsync` / `Export{Domain}{Entity}{Type}ReportAsync`
- DTO：`{Domain}{Entity}{Type}ReportDto` / `QueryDto` / `ExportDto`
- 前端 API：`get{Domain}{Entity}{Type}ReportList` / `export{Domain}{Entity}{Type}Report`
- `{Type}` 由具体业务命名（如 Receipt、Detail、Label）

---

## 三、查询策略（按场景选择）

### 3.1 策略对比

| 策略 | 分页 | 导出 | 适用 |
|------|------|------|------|
| **A. 单表 + 后填充** | 主表单表 WHERE → 分页 → 按 ID 后填充 | — | 主表 < 50w，分页行数少 |
| **B. JOIN + 后填充** | — | 4 表 JOIN → COUNT → ToList → 后填充 | 导出需全量数据 |
| **C. 统一 JOIN** | 分页和导出都 JOIN | 分页和导出都 JOIN | 主表 < 10w，关联简单 |

### 3.2 选择依据

- 主表 > 50w 且有 1:N 关联 → 策略 A+B（分页单表 + 导出 JOIN）
- 主表 < 10w 且关联简单 → 策略 C（统一 JOIN）
- 标签级报表（千万级）→ 必须策略 A+B
- 无论如何，分页和导出**共享**后填充方法，只改主查询结构

### 3.3 EXISTS vs 预查询 IN

**规范**：跨表筛选条件优先使用 `EXISTS` 子查询，**禁止**预查 ID + 大 IN 列表。

| 场景 | 做法 | 原因 |
|------|------|------|
| 上架状态/时间筛选 | `WHERE EXISTS(SELECT 1 FROM up_shelves WHERE ReceiptHeadId=h.Id AND ...)` | 避免预查 40w ID |
| 收货人筛选 | `WHERE EXISTS(SELECT 1 FROM printcenter WHERE SourceHeadId=h.Id AND UpdateBy IN (...))` | 同上 |
| 质检单号筛选 | `WHERE EXISTS(SELECT 1 FROM qualchecklistdetail WHERE ReceiptId=h.Id AND ...)` | 同上 |
| T100 单号筛选 | `WHERE EXISTS(detail WHERE SourceNo=?) OR EXISTS(arn_head WHERE Source=?)` | 同上 |
| 供应商/状态/日期（主表字段） | 直接 `WHERE h.SupplierName LIKE ...` | 主表字段无需子查询 |

**保留预查询的场景**（数据量小、可并行）：
- 字典数据（BusinessType 等）
- 人员 UserName/NickName 查询（走 sys_user 索引，结果通常 < 100）

---

## 四、后置填充性能模式

### 4.1 ILookup 替代 List.Where（**必须**）

```csharp
// ❌ O(n×m)：每行循环内全量扫描
var details = detailList.Where(d => d.HeadId == item.Id).ToList();

// ✅ O(1)：预建 Lookup，循环内索引取值
var lookup = detailList.ToLookup(d => d.HeadId);
var details = lookup[item.Id].ToList();
```

`RelatedData` 中用 `ILookup<long, T>` 承接明细/质检/标签，`FillDtoRows` 中走索引器。

### 4.2 导出跳过冗余数据加载

导出路径主查询已 JOIN 获取的字段，后填充**不再重复查询**：

| 数据 | 分页 | 导出 | 原因 |
|------|:--:|:--:|------|
| ArnHead/AsnHead/QualChecklist | ✅ | ❌ | 导出 SELECT 已有 |
| 收货明细 | ✅ | ❌ | 导出走 JOIN+GROUP BY 聚合 |
| 标签 | ✅ | ❌ | 大 IN 列表跳过 |
| 上架单 | ✅ | ✅ | 导出仍需填充上架字段 |
| 质检明细 | ✅ | ✅ | 导出仍需填充质检字段 |
| 用户字典 | ✅ | ✅ | 导出仍需昵称转换 |

### 4.3 明细聚合：JOIN + GROUP BY 替代关联子查询

导出路径明细数据（COUNT/SUM）用 `INNER JOIN receipt_head + GROUP BY ReceiptHeadId` 单次查询，**禁止**在 SELECT 中写 10w×4 次 `SqlFunc.Subqueryable` 关联子查询。

---

## 五、内存控制

- 导出路径 `LoadRelatedDataAsync` 传入 `skipDetailQuery: true`，跳过 ArnHead/AsnHead/QualChecklist 三张大字典加载（导出 SELECT 已有）。
- 标签查询同样受 `skipDetailQuery` 控制，避免 1000w 表 `WHERE IN(10w)` 全表扫。
- 上架后填充保留（数据量相对可控，且导出需要上架字段）。

### 预期内存（10w 行导出）

| 组件 | 旧 | 新 |
|------|:--:|:--:|
| 主查询结果 | ~300MB | ~300MB |
| ArnHead/AsnHead/QualChecklist 字典 | ~500MB | 0 |
| 标签查询 | ~500MB | 0 |
| 明细聚合 | ~100MB | ~100MB |
| UpShelves + 用户 | ~200MB | ~200MB |
| **总计** | **~1.6GB** | **~0.6GB** |

---

## 六、反模式（禁止）

| 反模式 | 为什么不行 |
|--------|-----------|
| 预查 ID + `WHERE Id IN (40w)` | MySQL 优化器弃索引走全表扫 |
| 分批次 IN 查询替代大 IN | 网络往返抵消、MySQL 仍需解析多个 IN |
| `pageSize=100000` 做导出 | 语义混乱、内存不可控 |
| 导出 `ORDER BY Id DESC` | 大结果集排序无意义且开销大 |
| SELECT 中 4 个关联子查询 × N 行 | N×4 次子查询，10w 行=40w 次 |
| `List.Where()` 在循环内 | O(n×m) 线性退化 |
| 导出复用分页方法 | 入口语义不清、后填充策略不可控 |
