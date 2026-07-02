---
name: dbsql
description: WMS MySQL 查询与 SQL 脚本管理：开发/生产环境只读查询、快速检查工具，默认参考 .env 配置环境
---

# DbSql — WMS MySQL Query

@rules/dbsql.rules.md

## Trigger

Use this skill when the user asks to query WMS database data, inspect table relationships, generate MySQL SQL, or archive WMS SQL scripts.

## Responsibilities

- 快速确认 `.env` 与 MySQL 执行驱动是否可用（优先 `mysql` CLI；无 CLI 时可用 Java + DBeaver MySQL JDBC 驱动）。
- 使用脚本执行可重复的 MySQL 只读查询，减少手工拼接连接命令。
- 默认使用开发环境 `dev` / `wms_lebg`；可用 `-Environment` 临时切换已配置环境。
- 强调 `/dbsql` 只有查询权限语义：脚本只允许只读 SQL，数据变更 SQL 只产出脚本和验证步骤，不自动执行写操作。

## Decision Flow

1. **快速检查**：首次数据库操作或连接状态不明时，优先运行 `scripts/dbsql-mysql.ps1 -Mode Check`；默认环境由 `.env` 的 `DBSQL_DEFAULT_ENV` 决定。
2. **只读查询**：用户要查数据时，直接用脚本执行 `-Mode Query -Sql '<SQL>'`；SQL 较长时先写临时 `.sql` 后用 `-Mode File -SqlPath <path>`。
3. **SQL 生成**：用户只要 SQL 时，不连接数据库；按规则生成单库 MySQL SQL。
4. **脚本归档**：用户要沉淀 SQL 文件时，按仓库 `sql/` 规范处理；写操作 SQL 只归档，不执行。
5. **失败处理**：缺 `.env`、缺 MySQL 执行驱动、连接失败或 SQL 被只读保护拦截时，停止并给一个明确修复动作；只在 MySQL CLI 与 MySQL JDBC 两种方式内切换。

## Loading Strategy

- 查询执行流程：按需读取 `workflows/mysql-query-flow.md`。
- WMS 入库/上架表关系和常用模板：按需读取 `references/wms-mysql-reference.md`。
- 脚本入口：`scripts/dbsql-mysql.ps1`，只在用户请求查询或检查时使用。

## Common Commands

```powershell
# 快速检查 .env、MySQL 执行驱动、目标库配置；默认 dev / wms_lebg，Auto 会优先 mysql CLI，缺失时使用 DBeaver JDBC
& "C:\Users\xx120\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode Check

# 开发环境只读查询；/dbsql 只做查询，不自动执行 INSERT/UPDATE/DELETE 等写操作
& "C:\Users\xx120\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode Query -Sql 'SELECT 1 AS ok;'

# 临时切换目标据点库或已配置环境
& "C:\Users\xx120\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode Query -Environment 'dev' -Database 'wms_lebg' -Sql 'SHOW TABLES;'

# 生产环境只读检查/查询；生产库名不确定时先用 information_schema 验证连接，再显式传 -Database
& "C:\Users\xx120\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode Check -Environment 'prod' -Database 'information_schema'
```
