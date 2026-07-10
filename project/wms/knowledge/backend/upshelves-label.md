# 上架标签：仓库与储位来源

> 最后更新: 2026-07-07
> 来源：上架标签仓库来源优先级修正 + 储位逻辑排查

---

## 一、两条创建路径

### 路径 A：`InStockUpShelvesCommonService.AutoCreateUpShelvesAsync`（主力）

调用方：`InstockReceiptService`、`ErpIQCResultSyncService`、`InstockUpShelvesService`

代码：`InStockUpShelvesCommonService.cs` 第 773~1172 行

### 路径 B：`InstockUpShelvesDomainService`（新服务）

调用方：分选上架等新流程

代码：`InstockUpShelvesDomainService.cs` 第 196~259 行

---

## 二、仓库来源

### 2.1 总体优先级（路径 A）

```
ERP仓库(ERPWarehouseId)
  > 质检标签仓库(item.WarehouseId, IQC判定结果)
    > 收货仓库(warehouseId)
```

代码：`InStockUpShelvesCommonService.cs` 第 1093~1133 行

| 优先级 | 来源 | 条件 | 说明 |
|:---:|------|------|------|
| ① | **质检标签仓库** `item.WarehouseId` | `> 0` 时使用 | IQC 判定阶段按 qcbc012 分配的仓库 |
| ② | **收货仓库** `warehouseId` | ①为空/0 时兜底 | 取值链路：`receiptDetail.WarehouseId` → `materialWarehouse.WarehouseId` → `receiptHead.WarehouseId` |
| ③ | **ERP仓库** `item.ERPWarehouseId` | `> 0` 时覆盖①② | 行 1126~1133，最终覆盖 |

### 2.2 收货仓库 (warehouseId) 取值链路

代码：`InStockUpShelvesCommonService.cs` 第 944~1004 行

```
采购单：receiptHead.WarehouseId
非采购单（委外）：receiptDetail.WarehouseId → materialWarehouse.WarehouseId → receiptHead.WarehouseId
非采购单（其他）：同上
```

### 2.3 路径 B 的仓库

代码：`InstockUpShelvesDomainService.cs` 第 207~234 行

- 先通过 `GetWarehouseByBillType(qualCheck.BusinessType, unqualType, warehouseId)` 按业务类型+判定区分获取仓库
- 再通过 `RecommendBin(warehouseId, ...)` 推荐储位，**储位的仓库可能覆盖上一步的仓库**

### 关键修正（2026-06-27）

提交 `fix/lyp/iqc-result-warehouse-assignment`：将路径 A 从"默认收货仓库，标签仓库覆盖"改为"**以质检标签仓库为主，收货仓库仅兜底**"。

---

## 三、储位来源

### 3.1 路径 A（主力）

**推荐储位逻辑已注释**，储位直接从质检标签拷贝。

代码：`InStockUpShelvesCommonService.cs` 第 1100~1110 行

```csharp
// 第 1100-1107 行：推荐储位已注释
//long wareBinId = item.WarehouseBinId.GetValueOrDefault();
//if (isRecommendBin) {
//    RecommendBinDto bin = RecommendLocalBin(stockLabels, qualDetail, lebelWareId);
//    wareBinId = bin.WarehouseBinId;
//}

// 第 1110 行：直接从质检标签拷贝
var label = item.Adapt<BaseMaterialPrintcenter>();
```

**储位 = 质检标签的 `WarehouseBinId` 原样继承。**

### 3.2 路径 B（新服务）

调用 `RecommendBin(warehouseId, stockManageFeature, materialNo)` 匹配已有库存标签。

代码：`InstockUpShelvesDomainService.cs` 第 433~448 行

匹配规则：**同仓库 + 同库存管理特征 + 同物料 + 在库状态 + 储位非空**，取匹配到的库存标签的储位。

匹配不到 → `WarehouseBinId = 0`。

### 3.3 储位后续覆盖

生成上架标签后，还有 `UpdateBinForRecommend`（行 1286~1298）按推荐逻辑批量更新标签储位。

---

## 四、总结

| 维度 | 路径 A（主力） | 路径 B（新服务） |
|------|--------------|--------------|
| 仓库 | 质检标签仓库 > 收货兜底 > ERP覆盖 | GetWarehouseByBillType 按业务类型+判定区分 |
| 储位 | 质检标签原样拷贝 | RecommendBin 推荐匹配 |
| 推荐储位 | 已注释（不生效） | 生效 |

**两个路径的仓库和储位都不直接等于收货仓库。**
