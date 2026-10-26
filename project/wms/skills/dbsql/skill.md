---
name: dbsql
description: WMS 数据库只读查询与 SQL 脚本管理：按正式/开发/从库/BI/日志/立库路由，结合实体字段生成可验证 MySQL 查询
---

# DbSql — WMS Database Query

@rules/dbsql.rules.md

## Trigger

当提词包含以下任一意图时调用：查数据库/查表/查单号/查标签/查库存/查日志、SQL 查询或生成、表结构/字段关系、入库/收货/上架、出库/拣料/发货、BI 报表、立库/自动化仓库、从库/只读库、正式库/开发库，或归档/维护 SQL 脚本。

以下提词应映射到目标路由：

- “正式库/生产库/线上库 + 据点名”：`prod.<site>`，如 `prod.lebg`。
- “开发库/测试库”：`dev`，默认 `wms_lebg`。
- “从库/只读库”：`replica`，必须使用 `.env` 中显式配置的只读连接，不得回退主库。
- “BI/报表分析”：`bi`，按配置识别 MySQL 或 Oracle；不能把 BI 当 WMS 业务库。
- “日志/接口日志/操作日志”：`logs`。
- “立库/自动化仓”：`warehouse`。
- 未指定路由：先根据问题中的环境、据点、业务关键词判断；仍不明确时使用开发库并在输出中明确目标库。

## Responsibilities

- 只从 `~/.claude/skills/dbsql/.env` 读取连接；项目 `appsettings*.json` 只用于核对主机、库名、租户和实体映射，不复制密码到任何输出或文件。
- 所有实际连接必须使用用户指定的只读账号。若目标连接没有配置只读账号，停止并报告“缺少只读连接配置”，不得使用 `root`、写账号或从应用连接字符串推导账号。
- 使用 `scripts/dbsql-mysql.ps1` 执行 MySQL 检查和只读查询；不在命令行参数中传密码。
- 默认只执行读操作：`SELECT`、`SHOW`、`DESCRIBE/DESC`、`EXPLAIN`、`WITH`。写 SQL 只能生成、预检、归档和说明回滚，不执行。
- 根据代码实体上的 `[SugarTable]`、属性名、`[SugarColumn]`、`[Tenant]` 和软删除字段反推表名、列名与关系；不要臆造字段。优先引用实体文件路径和行号。
- 查询前先限制目标范围（库、表、单号/日期/据点），优先 `LIMIT`、索引字段和必要列，避免无条件全表扫描。

## Database Routes

| 路由 | 目标 | 配置约定 | 适用问题 |
|---|---|---|---|
| `prod.lebg` | 正式库 LEBG | `PROD_LEBG_*` | LEBG 线上业务 |
| `prod.lebgty` | 正式库 LEBGTY | `PROD_LEBGTY_*` | LEBGTY 线上业务 |
| `prod.lebgjs` | 正式库 LEBGJS | `PROD_LEBGJS_*` | LEBGJS 线上业务 |
| `prod.lebgch` | 正式库 LEBGCH | `PROD_LEBGCH_*` | LEBGCH 线上业务 |
| `prod.labg` | 正式库 LABG | `PROD_LABG_*` | LABG 线上业务 |
| `prod.bpbg` | 正式库 BPBG | `PROD_BPBG_*` | BPBG 线上业务 |
| `dev` | 开发库 | `DEV_*`，库默认 `wms_lebg` | 开发验证、结构核对 |
| `replica` | 从库 | `REPLICA_*` | 只读分析、生产报表核对 |
| `bi` | BI 库 | `BI_*` | 报表、聚合、分析 |
| `logs` | 日志库 | `LOGS_*` | 接口/审计/操作日志 |
| `warehouse` | 立库库 | `WAREHOUSE_*` | 自动化仓、立库同步和快照 |

库名必须显式配置，不根据路由名自动拼接；生产库可能是 `lebg` 或 `wms_lebg`，以当前 `.env` 配置为准。所有路由都必须配置 `*_DB_HOST`, `*_DB_PORT`, `*_DB_USER`, `*_DB_PASS`, `*_DB_NAME`；BI 若是 Oracle，不要传给 MySQL 脚本，应停止并提示使用对应 Oracle 只读驱动/连接配置。

## Decision Flow

1. **识别提词**：抽取环境/据点/库类型、业务对象、单号/物料/标签、时间范围和“只生成 SQL/实际执行”。
2. **建立路由**：按上表选择唯一目标；正式库多据点查询一次只连接一个库，除非用户明确要求逐库汇总，并逐库执行、分别标记结果。
3. **实体核对**：从 `references/wms-mysql-reference.md` 查常用模板；需要新字段时搜索实体 `[SugarTable]`、属性和对应服务/仓储查询，确认表列、关联键及 `IsDeleted` 语义。
4. **连接检查**：首次使用路由或连接状态未知时运行 `-Mode Check -Environment <route>`。检查只输出主机/端口/库/只读用户的脱敏信息。
5. **准备 SQL**：默认单库、不写 schema 前缀；涉及软删除时加入 `IsDeleted = 0` 或项目实际 `DeletedAt IS NULL`，以实体/接口代码为准。
6. **执行查询**：短 SQL 用 `-Mode Query`，长 SQL 用 `-Mode File`；必要时传 `-Limit`。脚本拒绝写操作、危险多语句和不安全导出。
7. **输出结果**：说明路由、数据库名、实体/表依据、SQL 意图、关键结果、时间范围和限制；不输出密码。查询失败只给明确的修复动作。
8. **维护脚本**：沉淀 SQL 时同步 `sql/README.md`、`sql/index.md` 和 `sql/logs/yyyy-MM-dd/`；脚本文件按版本归档，记录路由和实体依据。写 SQL 必须带预检、备份、事务、更新、验证、回滚说明，但不执行。

## Loading Strategy

- 路由、只读账号、环境变量和失败处理：读取 `rules/dbsql.rules.md`。
- 查询执行顺序与脚本参数：读取 `workflows/mysql-query-flow.md`。
- 数据库目标与环境变量前缀：读取 `references/wms-routing-reference.md`。
- 实体到表、租户和 ORM 查询过滤差异：读取 `references/wms-orm-query-boundaries.md`。
- WMS 实体关系和模板：读取 `references/wms-mysql-reference.md`。
- 本地无网络路由/SQL 校验：使用 `scripts/dbsql-mysql.ps1 -Mode Validate`；连接配置维护和联网检查才使用 `-Mode Check`；仅用户明确要求实际查询时执行 Query/File。

## Common Commands

```powershell
# 检查开发库
& "$env:USERPROFILE/.claude/skills/dbsql/scripts/dbsql-mysql.ps1" -Mode Check -Environment dev

# 检查指定正式据点；正式库路由必须在 .env 中有独立只读配置
& "$env:USERPROFILE/.claude/skills/dbsql/scripts/dbsql-mysql.ps1" -Mode Check -Environment prod.lebg

# 只读查询（目标路由由 .env 前缀解析）
& "$env:USERPROFILE/.claude/skills/dbsql/scripts/dbsql-mysql.ps1" -Mode Query -Environment replica -Sql 'SELECT 1 AS ok;'

# 长 SQL 文件查询
& "$env:USERPROFILE/.claude/skills/dbsql/scripts/dbsql-mysql.ps1" -Mode File -Environment logs -SqlPath '.\query.sql' -Limit 100
```

## Output Contract

每次实际查询至少输出：`Route`、`Database`、`ReadOnlyUser`（仅用户名）、`EntityEvidence`、`QueryScope`、`Result`。密码、完整连接串和配置文件中的敏感字段永不输出。
