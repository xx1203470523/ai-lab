# 质检判定与仓库分配

> 最后更新: 2026-07-07
> 来源：质检判定切换 qcbc002→qcbc012 实战 + 上架标签仓库来源排查

---

## 一、T100 字段映射

| T100 字段 | 示例值 | WMS 实体属性 | 所属表 | 含义 | 当前使用 |
|-----------|--------|-------------|--------|------|:---:|
| `qcbc002` | `"05"` = 合格 | `QualityStatus` (string) | `qual_check_list_label` / `qual_checklist_detail` | 判定结果（旧） | ❌ 已废弃 |
| `qcbc012` | `"1"` = 良品 | `UnqualifiedType` (EQualJudgment) | `qual_check_list_label` | **判定区分**（新） | ✅ 当前使用 |

> 2026-05-27 切换：质检判定逻辑从 `qcbc002`（判定结果）改为 `qcbc012`（判定区分），仓库分配更精确。

---

## 二、判定区分枚举 (EQualJudgment)

代码：`Domain.Shared/Enums/EQualJudgment.cs`

| qcbc012 值 | 枚举 | 中文 | 分组 |
|:---------:|------|------|------|
| 1 | `Qualified` | 良品 | Qualified |
| 2 | `DefectiveWarehouse` | 不良品入库 | DefectiveWarehouse |
| 3 | `ScrapWarehouse` | 报废入库 | DefectiveWarehouse |
| 4 | `Rejection` | 验退 | Unqualified |
| 5 | `PQCDestructive` | PQC破坏性检验下线 | Unqualified |
| 6 | `ReturnWIP` | 转回当站在制 | Unqualified |
| 7 | `ReturnScrap` | 转回当站报废 | Unqualified |

---

## 三、判定分组 (EQualJudgmentGroup)

代码：`Domain.Shared/Constants/EQualJudgmentGroup.cs`

| 分组 | 包含值 | 是否生成上架标签 |
|------|--------|:---:|
| `Qualified` | 1（良品） | ✅ |
| `DefectiveWarehouse` | 2、3（不良品/报废入库） | ✅ |
| `Unqualified` | 4、5、6、7（验退/PQC/转回） | ❌ 跳过 |

---

## 四、质检标签仓库分配

### 4.1 初始仓库

代码：`QualChecklistService.cs` 第 977~997 行（IQC 反审重置场景）

| 单据类型 | 初始仓库 | 代码逻辑 |
|---------|---------|---------|
| 采购单 (`IsPurchase="Y"`) | 收货单头仓库 `receiptHead.WarehouseId` | 直接取 |
| 非采购单 | 物料仓库 `materialWarehouse.WarehouseId` → 收货单头仓库 | 先查 `InStockMaterialWarehouse`，为空则兜底 |

### 4.2 IQC 判定覆盖仓库

代码：`ErpIQCResultSyncService.cs` 第 2076~2100 行

方法 `NoPurchaseOrderSetWarehouseAsync(EQualJudgment judgment, long warehouseId)`

| qcbc012 | 目标仓库 | 匹配规则 |
|:-------:|---------|---------|
| 1（良品） | **不变** | 保持初始仓库 |
| 2（不良品入库） | **不良品仓** | `BaseWarehouse.WareType == "REJECTS"` |
| 3（报废入库） | **报废仓** | `BaseWarehouse.WareType == "WAIT SCRAP"` |
| 4~7 | **不变** | 不生成上架标签，仓库无意义 |

### 4.3 完整决策链

```
T100 IQC 结果 qcbc012
  ├─ 1 (良品) → 初始仓库（收货仓库/物料仓库）
  ├─ 2 (不良品入库) → 系统不良品仓 (WareType="REJECTS")
  ├─ 3 (报废入库) → 系统报废仓 (WareType="WAIT SCRAP")
  └─ 4/5/6/7 → 不生成上架标签
```

---

## 五、关键代码位置

| 文件 | 行号 | 内容 |
|------|------|------|
| `EQualJudgment.cs` | 全文件 | 判定区分枚举定义 |
| `EQualJudgmentGroup.cs` | 全文件 | 判定分组（三组） |
| `QualCheckListLabel.cs` | 349~386 | 实体字段：UnqualifiedType(qcbc012)、QualityStatus(qcbc002) |
| `ErpIQCResultSyncService.cs` | 474~489 | IQC 结果同步：不合格时调 NoPurchaseOrderSetWarehouseAsync |
| `ErpIQCResultSyncService.cs` | 612~621 | 同上（另一分支） |
| `ErpIQCResultSyncService.cs` | 2076~2100 | NoPurchaseOrderSetWarehouseAsync：按判定区分匹配仓库 |
| `QualChecklistService.cs` | 977~1008 | IQC 反审重置：初始仓库来源 + 良品重置仓库 |
