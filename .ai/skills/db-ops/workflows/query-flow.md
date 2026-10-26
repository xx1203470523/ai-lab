# 只读查询流程

适用：`-Mode Query`（短 SQL）与 `-Mode File`（长 SQL / SQL 文件）。
阶段 1 的执行器未实现，因此本文件描述的是**流程契约**；阶段 1 能实际跑的是第 2 步（状态）与第 3 步（静态守卫）。

## 0 前置

- 已经拿到用户的**目标**（环境 + 据点/租户）与**业务意图**（想知道什么）。
- 有明确的收窄条件：单号、物料、标签、时间范围、状态之一。没有收窄条件的查询要先回去问，不要用 `LIMIT` 假装收窄。

## 1 定路由

1. 把「环境 + 据点/租户」映射成**一条**路由 id（`dev.lebgjm`、`prod.lebg`、`prod.shared`…）。
2. 映射不上 → 走 SKILL.md 的「未匹配命令」：给候选路由 id + 状态，问清是据点还是租户。**不得**挑一个最接近的继续。
3. 多据点汇总：**逐库分别执行、分别标注**，禁止跨库 JOIN，也不要把多库结果合成一张表再报。

## 2 看状态（不允许跳过）

```powershell
powershell -NoProfile -File "$sk\db-ops.ps1" -Mode Validate -Target prod.lebg
```

- 状态不是 `ready` → **停**，把 `依据`（`statusReason`）原样转述，并说明下一步需要什么（配凭据 / 人工确认据点与库的对应 / 该引擎没有执行器）。
- `ready` 只表示配置与权限齐备，**不表示**已经连通过。真实连通的结论只能来自一次成功的查询。

## 3 备 SQL

- **单库、不带 schema 前缀、不带库名限定**（库名由路由决定，写进 SQL 反而会掩盖路由错误）。
- 优先索引字段与必要列；不要 `SELECT *`。
- 软删除：按**实体是否实现 `IDeletedFilter`** 决定加不加 `IsDeleted = 0`；不要无条件给每张表都加。见 `references/projects/wms/orm-boundaries.md`。
- 先离线自检，能省一次往返：

```powershell
powershell -NoProfile -File "$sk\db-ops.ps1" -Mode Validate -Target dev.lebgjm -Sql 'SELECT Id FROM instock_order WHERE Code = @code'
```

守卫会报语句种类、语句条数、拒绝原因。**被拒绝就改 SQL，不要去改守卫。**

## 4 执行（阶段 2）

```powershell
# 短 SQL
... -Mode Query -Target dev.lebgjm -Sql 'SELECT ...' -Limit 100

# 长 SQL / 需要留档的 SQL
... -Mode File -Target dev.lebgjm -SqlPath '.\sql\pending\q_xxx.sql' -Limit 100
```

- `-Limit` 缺省取 `policy.output.maxRows`；`0` 表示明确不追加 `LIMIT`（需要理由）。
- 结构化结果用 `-Format Json`；要贴给人看用默认 `Table`。

## 5 输出

报告必须包含：目标路由、数据库名、SQL 意图（一句话）、关键结果、范围与限制、以及**是否被截断**。

- `RowsReturned` 达到 `Limit` 时必须说「可能还有更多」，**不得**说成「就这么多」。
- 输出里不得出现口令与完整连接串；账号只显示首字母。
- 失败时只给修复动作（改配置 / 改 SQL / 补凭据），不要把原始连接错误整段贴出来（可能带连接串）。

## 6 留痕

- 需要复用的查询按 `sql/README.md` 的规范归档；一次性的临时查询不进 `sql/`。
- 归档时记录：路由、库名、意图、实体依据、验证时间。

## 禁止

- 禁止为拿总行数自动跑 `COUNT(*)`。
- 禁止自动加宽范围（去掉 `WHERE`、跨库、全表）。
- 禁止把写 SQL 放进本流程（→ `exec-flow.md`）。
- 禁止在目标不是 `ready` 时「先试一下」。
