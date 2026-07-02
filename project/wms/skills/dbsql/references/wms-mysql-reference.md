# WMS MySQL Reference

## Multi-site Database Model

- WMS 是多据点部署，每个据点使用独立数据库。
- 默认参考数据库为 `wms_lebg`，因为数据量较大，适合验证字段、关联关系、性能和结果分布。
- 查询其他据点时，不改 SQL 主体，只切换连接数据库。
- 不要把 `wms_lebg` 的业务数据结论直接当作所有据点结论。

## Inbound → Receipt → Up Shelves Chain

```text
instock_arn_head (ARN单主表)
  └── instock_arn_detail (ARN单明细)
        └── instock_receipt_head (收货主表, Status: 0=草稿 1=收货中 2=已收货)
              └── instock_receipt_detail (收货明细)
              └── instock_receipt_label (收货标签/扫描记录)
                    └── instock_up_shelves (上架单, UpStatus: 0=待上架 1=已上架 2=上架中)
                          └── instock_up_shelves_detail (上架明细)
```

## Key Tables

| 表名 | 说明 | 关键字段 |
|---|---|---|
| `instock_arn_head` | ARN 单主表 | `ArnNo`, `Status` |
| `instock_arn_detail` | ARN 单明细 | `ArnHeadId`, `MaterialCode`, `MaterialName` |
| `instock_receipt_head` | 收货主表 | `ReceiptNo`, `Status`, `ArnHeadId` |
| `instock_receipt_detail` | 收货明细 | `ReceiptHeadId`, `MaterialCode`, `ReceivedNum` |
| `instock_receipt_label` | 收货标签 | `ReceiptHeadId`, `LabelCode`, `LabelId`, `ShippingNum` |
| `instock_up_shelves` | 上架单 | `UpShelvesNo`, `UpStatus`, `ReceiptHeadId` |
| `instock_up_shelves_detail` | 上架明细 | `UpShelvesId`, `UpStatus`, `ReceiptDetailId`, `MaterialCode`, `ReceivedNum`, `UpNum` |
| `instock_sorting_order` | 分拣单 | 分拣任务 |
| `instock_rejection_order` | 验退单 | 验退处理 |

## Common Field Conventions

- `*Id`: 主键/外键。
- `*No`: 单号。
- `*Code`: 编码。
- `*Name`: 名称。
- `*Num` / `*Qty`: 数量。
- `*Status`: 状态。
- `DeletedAt`: 软删除时间，`NULL` 表示未删除。
- `CreatedAt` / `UpdatedAt`: 创建/更新时间。

## Query Templates

### 已扫描未上架：标签维度

```sql
SELECT
    rl.ReceiptNo        AS 收货单号,
    rl.ArnNo            AS ARN单号,
    rl.LabelCode        AS 标签码,
    rl.ShippingNum      AS 预收数量,
    rl.WarehouseName    AS 仓库,
    rl.PurchaseNo       AS 采购单号,
    rl.ShippingNo       AS 送货单号,
    us.UpShelvesNo      AS 上架单号,
    us.UpStatus         AS 上架状态,
    us.UpNum            AS 已上架数量,
    rl.CreatedAt        AS 扫描时间
FROM instock_receipt_label rl
LEFT JOIN instock_up_shelves us
    ON us.ReceiptHeadId = rl.ReceiptHeadId
    AND us.DeletedAt IS NULL
WHERE rl.DeletedAt IS NULL
    AND (us.Id IS NULL OR us.UpStatus <> 1)
ORDER BY rl.CreatedAt DESC
LIMIT 100;
```

### 已扫描未上架：物料汇总

```sql
SELECT
    ud.MaterialCode     AS 料件编号,
    ud.MaterialName     AS 料件名称,
    ud.Standards        AS 规格型号,
    SUM(ud.ReceivedNum) AS 收货数量,
    SUM(ud.UpNum)       AS 已上架数量,
    SUM(ud.ReceivedNum - IFNULL(ud.UpNum, 0)) AS 未上架数量,
    COUNT(DISTINCT us.ReceiptNo) AS 涉及收货单数
FROM instock_up_shelves_detail ud
INNER JOIN instock_up_shelves us
    ON us.Id = ud.UpShelvesId
    AND us.UpStatus <> 1
    AND us.DeletedAt IS NULL
WHERE ud.DeletedAt IS NULL
GROUP BY ud.MaterialCode, ud.MaterialName, ud.Standards
ORDER BY 未上架数量 DESC;
```

### 上架单状态分布

```sql
SELECT
    CASE UpStatus
        WHEN 0 THEN '待上架'
        WHEN 1 THEN '已上架'
        WHEN 2 THEN '上架中'
        ELSE CONCAT('未知(', UpStatus, ')')
    END AS 状态,
    COUNT(*) AS 单据数,
    SUM(ReceivedNum) AS 总收货数量,
    SUM(UpNum) AS 总上架数量
FROM instock_up_shelves
WHERE DeletedAt IS NULL
GROUP BY UpStatus;
```

### 收货单完整链路

```sql
SELECT
    rh.ReceiptNo,
    rh.Status AS 收货状态,
    rh.ArnNo,
    rl.LabelCode,
    rl.ShippingNum,
    us.UpShelvesNo,
    us.UpStatus AS 上架状态,
    us.UpNum,
    us.ReceivedNum
FROM instock_receipt_head rh
LEFT JOIN instock_receipt_label rl
    ON rl.ReceiptHeadId = rh.Id
    AND rl.DeletedAt IS NULL
LEFT JOIN instock_up_shelves us
    ON us.ReceiptHeadId = rh.Id
    AND us.DeletedAt IS NULL
WHERE rh.DeletedAt IS NULL
    AND rh.ReceiptNo = '{单号}';
```

## SQL Archive Reminder

仓库 SQL 归档仍按用户偏好执行：

```text
sql/
├── README.md              # SQL 编写与维护规范
├── index.md               # SQL 变更文件索引
├── logs/yyyy-MM-dd/        # 详细变更背景
└── {version}/              # 版本 SQL 脚本
```

数据变更 SQL 需包含：预检查询 → 备份 → 事务 → 更新 → 验证 → 回滚说明。
