# ARN 单的部门显示为「无」（部门字段是导入原文，不是部门 Id）

```
状态：已验证（依据为代码引用链核查，2026-09-17 落地修复；本次未用真实查询复核——阶段 1 不连库）
最后验证时间：2026-09-17
适用路由：任意 WMS 据点库（表在 DBTenant.Default，与 sys_user / sys_dept 同库）
```

## 识别条件

- 症状：ARN 单（预收货通知）列表里**部门列显示「无」**，或按部门筛 ARN 单筛不出任何数据。
- 报错/关键输出：**无报错**。查询正常返回，只是部门取不到值——这正是它难查的原因。
- 涉及对象：`instock_arn_head`（预收货通知主表）。
- 可复现条件：数据来自 Excel 导入的 ARN 单必然如此；ASN→ARN 自动生成的单同样没有部门。

## 为什么会出现

`InStockArnHead.Dept`（`Domain/Domain.Warehouse/Entities/InStock/InStockArnHead.cs:59`，`string?`）**形似部门外键，实际存的是 Excel 导入原文**：

| 写入路径 | 写入内容 | 证据 |
|---|---|---|
| ASN→ARN 自动生成 | 恒写 `""` | `InstockArnHeadService`Factory.cs:100` |
| Excel 导入 | 导入文件里的部门字段原文（可能是中文部门名、可能是空） | 前端 `arn-import-map.ts:17,26`（部门/业务部门 → `dept`）→ `import-dialog/index.vue:130` `Dept: details[0]['dept']`，**全程没有编码→Id 的解析** |

全仓库**没有任何读取 `Dept` 的地方**——它是只写字段。因此：

- `@Dept` 里既不是 `sys_dept.Id`，也不保证是 `sys_dept.DeptCode`，**不能拿来关联**。
- 按 Id 匹配的写法（`join sys_dept on Dept = Id`）**不抛异常、不报错，只是恒返回「无」**。静默失效，所以排查成本高。
- 旧设计曾用 `SysUser.DeptId`（`InstockArnHeadService`Command.cs:53`，已注释），但 `SysUser` 现在只有 `DeptCode`/`DeptName`，**没有 `DeptId`**，该设计已废弃。
- ⚠ `InstockArnHeadRepository.cs:58` 有一句**注释态的** `left join sys_dept de on T1.Dept = de.Id`，它会把人往 Id 方向带。**注释不是证据。**

另外别被同类字段误导：`InStockArnHead` 上还有一整套部门字段，语义各不相同——

- 有 `...Name` 伴生列（值已反规范化，可直接读）：`ApplyDept` / `ApplyDeptName`、`ReceiveDeptCode` / `ReceiveDeptName`、`MakeBillDeptCode` / `MakeBillDeptName`。
- **没有**伴生列的：就是 `Dept` 这一个。

表名与列名来自实体，不要按字段名的相似度猜。

## 诊断 SQL

单库、不带 schema 前缀、只用单号收窄（`instock_arn_head` 数据量大，先定位到一张单再放大范围）。

```sql
-- 问：这张单的 Dept 里到底存了什么？（是空串、中文原文，还是数字）
SELECT Id, ArnNo, Dept, ApplyDept, ApplyDeptName, CreateBy
FROM instock_arn_head
WHERE ArnNo = '<单号>' AND IsDeleted = 0
```

```sql
-- 问：按 Id 匹配是不是恒空？（本剧本的核心验证）
SELECT h.ArnNo, h.Dept, d.Id AS MatchedDeptId, d.DeptName AS MatchedDeptName
FROM instock_arn_head h
LEFT JOIN sys_dept d ON d.Id = h.Dept AND d.IsDeleted = 0
WHERE h.ArnNo = '<单号>' AND h.IsDeleted = 0
```

```sql
-- 问：走「创建人 → 部门」这条路能不能拿到部门名？
SELECT h.ArnNo, h.CreateBy, u.UserName, u.DeptCode, u.DeptName AS UserDeptName,
       d.DeptCode AS CodeFallback, d.DeptName AS DeptNameFallback
FROM instock_arn_head h
LEFT JOIN sys_user u ON u.UserName = h.CreateBy AND u.IsDeleted = 0
LEFT JOIN sys_dept d ON d.DeptCode = u.DeptCode AND d.IsDeleted = 0
WHERE h.ArnNo = '<单号>' AND h.IsDeleted = 0
```

三条表都在 `DBTenant.Default`，同一条路由内即可完成，**不需要跨库 JOIN**。

## 判定

| 诊断结果 | 结论 |
|---|---|
| 第 1 条：`Dept` 为 `''` 或中文部门名（非数字） | 命中本剧本：该字段是导入原文 |
| 第 2 条：`MatchedDeptId` / `MatchedDeptName` 为 NULL | 命中本剧本：按 Id 匹配恒空 |
| 第 3 条：`UserDeptName` 有值 | 处置方向明确：走创建人取部门 |
| 第 1 条 `Dept` 是**纯数字**且第 2 条能 join 上 | **不是**本剧本的成因：该行数据来自另一条写入路径，先查清它是谁写的，不要套用本剧本的处置 |
| 都不符合 | 新情况：按普通排查继续，并考虑更新本剧本 |

## 处置

- **显示层**：ARN 部门名走创建人——`CreateBy` → `sys_user`（按 `UserName` 关联，`InstockArnHeadService`Query.cs:63-64` 证实这个关联键）→ 取 `DeptName`；`DeptName` 为空时再用 `sys_user.DeptCode` → `sys_dept.DeptCode` 兜底。这就是 2026-09-17 落地的做法。
- **筛选层**：按部门筛 ARN 单时，同样走「创建人 → 部门」，**不要**拿 `Dept` 当条件。
- **数据层**：不改。`Dept` 是导入原文，改动它等于篡改导入凭据；如果确有必要，转 `workflows/exec-flow.md` 的受控执行流程。

## 回滚

不涉及（只读处置）。

## 验证

重跑第 3 条诊断语句，`UserDeptName`（或兜底的 `DeptNameFallback`）应当有值；界面上的部门列随之不再是「无」。

## 残留不确定性

- **`CreateBy` 的语义**：确认它存的是账号（与 `sys_user.UserName` 对应），依据是写入侧统一取 `WMSApp.GetUserName()`，以及 `InstockArnHeadService`Query.cs:64` 的 `a.UserName == parm.CreateBy`。导入路径未逐条核对，若某批数据的 `CreateBy` 写成别的形态，第 3 条会返回 NULL，此时**不要**改判为「数据没有部门」。
- **同名/停用账号**：`sys_user` 若存在多个同名记录，关联会放大行数；诊断时注意 `COUNT` 的变化。
- **`SysUser.DeptName` 本身可能为空**（用户没有部门），此时依赖 `DeptCode` 兜底；两条都空时应显示为空，而不是显示「无」——「无」是取不到值的表现，与「确实没有部门」是两件事。
- 本剧本依据代码引用链得出，**未经真实查询复核**。首次在真实库上执行诊断后，请把实测结果补进来并更新「最后验证时间」。
