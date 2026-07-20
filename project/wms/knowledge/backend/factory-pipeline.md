# 入库工厂管线：五层分离模式

> 最后更新: 2026-07-20
> 来源：InStockFactoryService 上架单生成方法重构 + 质检单生成方法重构

---

## 一、设计思路

入库工厂（`InStockFactoryService`）负责从 ASN→ARN→Receipt→Qual→UpShelves 链路生成下游单据。早期实现将数据加载、校验、构建、持久化混在一个方法中，导致 DB 写入穿插在 pipeline 中间。重构后拆为五层，每层有明确的**职责边界**和**DB 访问约束**。

核心原则：

1. **GenerateData 不落库**：构建实体纯内存操作，返回实体给调用方
2. **PersistData 自包含**：外部只需调一次，内部自动加载数据→构建→校验→落库
3. **ValidateData 纯内存**：校验只靠内存数据，不查库。如果需要查库校验，应在 LoadData 阶段预加载数据
4. **Adapt 优先**：实体间映射优先用 `Adapt<T>()`，仅覆写名称不匹配/来源不同/计算字段

---

## 二、五层职责

| 层级 | 签名模式 | DB 访问 | 职责 | 示例 |
|:---:|---|---|---|---|
| **LoadData** | `LoadData{Entity}Async` | ✅ 可查库 | 确保数据就绪：已传跳过 / 按 ID 查 DB / 否则抛异常 | `LoadQualAsync` |
| **FillData** | `FillData{Entity}Async` | ✅ 可查库 | 编排调用链：依次调 Load→Ensure→FillDictionaries，准备全量数据 | `FillDataUpshelvesAsync` |
| **ValidateData** | `ValidateData{Entity}` | ❌ 禁止 | 纯内存校验业务规则（状态、数量、防重） | `ValidateUpshelves`、`ValidateQual` |
| **GenerateData** | `GenerateData{Entity}` | ❌ 禁止 | 纯内存构建实体：Adapt + 覆写，返回实体/元组 | `GenerateQual`、`GenerateUpshelvesAsync` |
| **PersistData** | `PersistData{Entity}Async` | ✅ 可写库 | 自包含落库：内部调 Ensure→Generate→Validate→INSERT/UPSERT | `PersistQualAsync` |

### 详细说明

#### LoadData（数据就绪）

```
职责：确保某个实体已存在于 DTO 中
- 已传 → 直接返回
- 有 ID → 从 DB 加载
- 都没有 → 抛异常（调用方应先调 PersistData）
不负责：构建实体、写入 DB、校验业务规则
```

#### FillData（编排）

```
职责：按链路顺序加载所有数据 + 字典
调用顺序：下游（Qual）→ 上游（Receipt→Arn→Asn）→ 已有数据（ExistingUpShelves）→ 字典
不负责：构建实体、写入 DB
```

#### ValidateData（校验）

```
职责：校验内存数据是否满足生成条件
约束：纯内存，禁止查库
- 收货单状态（status==2）
- 质检状态（ischecked/nocheck、CheckResult）
- 数量一致性（CheckNum == QualifiedNum + UnQualifiedNum）
- 防重（是否全部已生成）
```

#### GenerateData（构建）

```
职责：从源实体构建目标实体
模式：Adapt<T>() → 覆写名称不匹配/计算字段 → ToCreate()
- 单头：源实体.Adapt<目标实体>() + 计算字段覆写
- 明细：源明细.Adapt<目标明细>() + ~20 个覆写
- 标签：源标签.Adapt<BaseMaterialPrintcenter>() + 上下文字段覆写
不负责：查库、落库、校验
```

#### PersistData（持久化）

```
职责：自包含落库，外部一步调用
内部流程：
  1. Ensure*Async（加载所需数据）
  2. FillDictionariesAsync（加载字典）
  3. GenerateData*（内存构建，当 GenerateData 调用需序列化时可为 async）
  4. ValidateData*（纯内存校验）
  5. DB 写入（INSERT/UPSERT + 混合场景补齐）
  6. 将结果写回 data DTO
```

---

## 三、Adapt + 覆写模式

```csharp
// 1. Adapt 批量映射
var detail = sourceDetail.Adapt<TargetDetail>();

// 2. 覆写（仅以下三类需要手动赋值）
detail.ParentId = head.Id;              // 父 FK（名称不匹配）
detail.SomeCount = source.SourceCount;  // 名称不匹配
detail.MaterialName = material?.Name;   // 来源不同（从字典取值）
detail.QualifiedNum = 0;                // 初始值
detail.Status = "unchecked";            // 初始值
detail.ToCreate();                      // Id/CreateBy/CreateOn/UpdateBy/UpdateOn/IsDeleted
```

覆写清单判断规则：
- 同名字段 → Adapt 自动映射，**不需要覆写**
- 名称不匹配 → 必须覆写（如 `ReceivedNum→CheckNum`、`MaterialNo→MaterialCode`）
- 来源不同 → 必须覆写（从 HEAD 取的 `ArnNo`、从物料表取的 `Standards`）
- 初始值 → 必须覆写（如 `QualifiedNum=0`、`CheckStatus="unchecked"`）
- [Obsolete] 字段 → **删除**，改用替代字段

---

## 四、调用链示例

### 上架单生成（CreateUpShelvesAsync）

```
PersistQualAsync            ← 自包含：EnsureReceipt→FillDictionaries→GenerateQual→ValidateQual→INSERT
  │                           将 QualHead/Details/Labels 写入 data
  ├── FillDataUpshelvesAsync ← 编排：LoadQual（跳过）→EnsureReceipt（跳过）→EnsureArn→EnsureAsn→...
  ├── GenerateUpNOAsync
  ├── ValidateUpshelves      ← 纯内存校验
  ├── GenerateUpshelvesAsync ← 纯内存构建
  └── Transaction: INSERT UpHead/Details/Labels
```

### 质检单生成（ConfirmReceipt，旧流程，待迁移）

当前 `ConfirmReceipt` 方法直接内联构建 Qual 实体并插入 DB，尚未使用工厂管线。

---

## 五、关键代码位置

| 文件 | 内容 |
|------|------|
| `Factory/InStockFactoryService`Qual.cs` | `LoadQualAsync`、`GenerateQual`、`ValidateQual`、`PersistQualAsync` |
| `Factory/InStockFactoryService`UpShelve.cs` | `FillDataUpshelvesAsync`、`ValidateUpshelves`、`GenerateUpshelvesAsync` |
| `Factory/InStockFactoryService`Receipt.cs` | `EnsureReceiptAsync` |
| `Factory/InStockFactoryService`Common.cs` | `FillDictionariesAsync` |
| `Implementations/InStock/InstockReceiptService.cs` | `CreateUpShelvesAsync`（调用方，展示 Persist→Fill→Generate 顺序） |
| `Interfaces/InStock/IInStockFactoryService.cs` | 接口定义 |
| `Extensions/Extension.Entity.cs` | `ToCreate()` 扩展方法 |
