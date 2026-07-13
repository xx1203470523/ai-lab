# WMS 报表开发参考

> 最后更新: 2026-07-09
> 来源：入库综合报表多轮性能优化实战

---

## 一、规范

### 1.1 查询门禁

- **必须**有时间或其他高选择性条件兜底，禁止无条件全表分页/导出。
- 查询条件不足时，后端直接抛业务异常提示用户补充条件。

### 1.2 导出数量限制

- **必须**先 `CountAsync` 判断总数，符合阈值再 `ToList`。
- **禁止**使用 `pageSize=100000` 等 hack 方式限制导出数量。
- 阈值建议 100000，超出抛出明确提示引导用户缩小查询范围。

### 1.3 禁止事项

- 禁止 `dynamic` 类型
- 禁止反射/元数据（`GetType()`、`GetProperties()`、`PropertyInfo`）
- 匿名类型 `new { }` 改为具名私有类承接
- 禁止报表 Service 引入新外部依赖

### 1.4 排序

- 分页和导出**均不加** `ORDER BY`。雪花 ID 主键 + 聚簇索引自然有序，避免排序开销。

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

## 二、核心优化模式

### 2.1 默认时间范围兜底

无时间条件时自动补全默认范围 + 跨度上限。`ValidateQueryScope` 中完成，Service 入口统一调用。

| 数据量级         | 默认时间 | 最大跨度 |
| ---------------- | -------- | -------- |
| 千万级（标签表） | 近一周   | 一个月   |
| 百万级（明细表） | 近一个月 | 一个月   |
| 十万级以下       | 近一个月 | 三个月   |

### 2.2 分页与导出查询分离

分页和导出使用**独立查询构建器**，各自优化目标不同。

| 维度          | 分页                          | 导出                                   |
| ------------- | ----------------------------- | -------------------------------------- |
| **目标**      | 快，一页 20-50 条             | 全量准确，内存可控                     |
| **JOIN 策略** | 最小 JOIN（2-3 表）           | 完整 JOIN（5-8 表）                    |
| **跨表筛选**  | EXISTS 子查询                 | EXISTS 子查询                          |
| **字段获取**  | 核心字段 + 分页后按 ID 后填充 | JOIN SELECT 一次性拿全，跳过冗余后填充 |
| **排序**      | 不加 OrderBy                  | 不加 OrderBy                           |
| **COUNT**     | 核心表 COUNT                  | 核心表 COUNT（不是导出 JOIN COUNT）    |

关键约束：

- 分页和导出**禁止**共用同一个查询构建器方法
- 导出**禁止**通过修改 `PageSize` 伪装成分页查询

### 2.3 EXISTS 替代预查 ID + IN

**问题**：先查 ID 列表再 `WHERE Id IN (40w)`，ID 上万后 MySQL 优化器弃索引走全表扫。

**方案**：用 `SqlFunc.Subqueryable<T>().Where(...).Any()` 内联 EXISTS，每个条件独立推入数据库。

```csharp
// ❌ 预查 ID + IN
query.WhereIF(ctx.QueryReceiptIds.Any(), a => ctx.QueryReceiptIds.Contains(a.Id));

// ✅ EXISTS 内联
query.Where(a => SqlFunc.Subqueryable<QualChecklistDetail>()
    .Where(cd => cd.ReceiptId == a.Id && cd.CheckNo!.StartsWith(parm.CheckNo))
    .Any());
```

| 维度     | 预查 ID + IN               | EXISTS 子查询            |
| -------- | -------------------------- | ------------------------ |
| DB 往返  | N 次（每个条件一次）       | 0 次                     |
| 索引利用 | ID 上万后优化器弃索引      | 优化器正常走索引         |
| 可维护性 | 预查和主查询分离，逻辑割裂 | 条件内聚在 BuildQuery 中 |

保留预查询的场景：字典数据、用户 UserName/NickName（结果 < 100）。

### 2.4 大数据 COUNT 优化

导出 COUNT 使用**核心表最小查询**（与分页查询相同的表集合），不跑完整导出 JOIN。

```csharp
// ❌ 导出 COUNT 跑全量 JOIN
var total = await BuildExportQuery(queryDto).CountAsync();  // 120 秒

// ✅ COUNT 跑核心表
var total = await BuildPagedQuery(queryDto).CountAsync();    // < 1 秒
```

注意事项：

- COUNT 用分页查询构建器，不是导出查询构建器
- GROUP BY 聚合的导出 COUNT 需单独处理去重逻辑
- 建立 `ExportMaxRows` 常量（建议 100000）

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

## 四、查询策略

| 策略                 | 分页                                 | 导出                                          | 适用                 |
| -------------------- | ------------------------------------ | --------------------------------------------- | -------------------- |
| **A. 单表 + 后填充** | 主表单表 WHERE → 分页 → 按 ID 后填充 | —                                             | 主表 < 50w           |
| **B. JOIN + 后填充** | —                                    | 4+ 表 JOIN → COUNT（核心表）→ ToList → 后填充 | 导出全量             |
| **C. 统一 JOIN**     | 分页和导出都 JOIN                    | 分页和导出都 JOIN                             | 主表 < 10w，关联简单 |

选择依据：

- 主表 > 50w 且有 1:N 关联 → 策略 A+B
- 主表 < 10w 且关联简单 → 策略 C
- 标签级报表（千万级）→ 必须策略 A+B
- 分页和导出**共享后填充方法**，只改主查询结构

---

## 五、后置填充

### 5.1 ILookup 替代 List.Where（必须）

```csharp
// ❌ O(n×m)
var details = detailList.Where(d => d.HeadId == item.Id).ToList();
// ✅ O(1)
var lookup = detailList.ToLookup(d => d.HeadId);
var details = lookup[item.Id].ToList();
```

### 5.2 导出跳过冗余加载

导出主查询已 JOIN 的字段不再重复查询：

| 数据                          | 分页 | 导出 | 原因                    |
| ----------------------------- | :--: | :--: | ----------------------- |
| ArnHead/AsnHead/QualChecklist |  ✅  |  ❌  | 导出 SELECT 已有        |
| 收货明细                      |  ✅  |  ❌  | 导出 JOIN+GROUP BY 聚合 |
| 标签                          |  ✅  |  ❌  | 大 IN 列表跳过          |
| 上架单                        |  ✅  |  ✅  | 导出仍需                |
| 质检明细                      |  ✅  |  ✅  | 导出仍需                |
| 用户字典                      |  ✅  |  ✅  | 导出仍需                |

### 5.3 明细聚合

导出明细聚合用 `JOIN + GROUP BY` 单次查询，禁止 SELECT 中写 N×4 次关联子查询。

---

## 六、内存参考

10w 行导出预期：

| 组件                          |     旧     |     新     |
| ----------------------------- | :--------: | :--------: |
| 主查询结果                    |   ~300MB   |   ~300MB   |
| ArnHead/AsnHead/QualChecklist |   ~500MB   |     0      |
| 标签查询                      |   ~500MB   |     0      |
| 明细聚合                      |   ~100MB   |   ~100MB   |
| UpShelves + 用户              |   ~200MB   |   ~200MB   |
| **总计**                      | **~1.6GB** | **~0.6GB** |

---

## 七、反模式

| 反模式                        | 为什么不行                                  |
| ----------------------------- | ------------------------------------------- |
| 预查 ID + `WHERE Id IN (40w)` | MySQL 优化器弃索引走全表扫                  |
| 分页和导出共用查询构建器      | 分页为 20 条跑了 8 表 JOIN                  |
| 导出 COUNT 用全量 JOIN        | COUNT 只需筛选条件，全 JOIN 浪费 100 倍时间 |
| `pageSize=100000` 做导出      | 语义混乱、内存不可控                        |
| SELECT 中 N×4 关联子查询      | 10w 行 = 40w 次子查询                       |
| `List.Where()` 在循环内       | O(n×m) 线性退化                             |
| 导出复用分页方法              | 入口语义不清、后填充策略不可控              |

---

## 八、CommonService 通用逻辑抽取

多报表共用的处理逻辑**必须**抽入 `CommonService`，禁止在各 `{Domain}ReportService` 中重复实现相同的辅助方法。

### 8.1 典型归属

| 类别       | 示例                                               | 入 CommonService 理由           |
| ---------- | -------------------------------------------------- | ------------------------------- |
| 日期处理   | 默认时间范围计算、跨度校验、`DateTime?`→格式化字符串 | 每个报表入口都调用              |
| 名称解析   | 用户字典批量填充（UserId→NickName、CreateBy→姓名） | 后置填充第五步几乎所有报表复用  |
| 名称拼接   | 多个字段组装显示名（`工号/名称` 格式）             | 列标签规范化要求一致            |
| 字典映射   | 状态码→中文描述、枚举值→前端展示文本               | 导出行内容一致性依赖            |
| 数量/阈值  | `ExportMaxRows` 检查、`CountAsync` 阈值判断         | 门禁规则统一，禁止各报表各自定义 |

### 8.2 约束

- **禁止**在 CommonService 中写业务判断逻辑（如"质检状态是 A 则显示 X"），业务逻辑留在各 Domain Service
- **禁止**在 CommonService 中引入报表专用 DTO 依赖——参数用基础类型或通用接口
- CommonService 方法的单元测试必须覆盖所有使用该方法的报表场景
