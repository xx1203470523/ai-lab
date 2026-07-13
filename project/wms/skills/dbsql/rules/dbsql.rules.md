---
description: "dbsql 的 MySQL-only、安全和单据点查询底线。"
---

# DbSql Rules

## Scope

- 当前只支持 MySQL；不要尝试 SQL Server、PostgreSQL、SQLite、ODBC 或项目内其它数据库工具。
- 连接配置只从 `~/.claude/skills/dbsql/.env` 读取，除非用户明确给出临时覆盖参数。
- 默认环境是 `.env` 中的 `DBSQL_DEFAULT_ENV`；当前支持 `dev` 和 `prod`，其中 `prod` 使用原默认生产连接数据。
- 默认目标数据库是所选环境的 `DB_NAME`；未指定时按所选环境的库名处理，开发环境通常以 `wms_lebg` 作为参考库语义。

## Connection Safety

- 不读取、复述、记录或写入数据库密码。
- 不把密码写进 skill、SQL 文件、task log、命令输出或 Git 可见文件。
- 执行查询时优先通过 `scripts/dbsql-mysql.ps1`；脚本优先使用 `mysql` CLI，未安装 CLI 时允许使用 Java + DBeaver MySQL JDBC 驱动。
- CLI 模式使用 `MYSQL_PWD` 临时环境变量，JDBC 模式使用临时进程环境变量传递连接信息；不要把密码放进命令参数。

## Query Rules

- SQL 默认面向单个据点数据库，不写跨库 UNION、跨库 JOIN 或一次查全据点脚本。
- SQL 默认不带 `wms_lebg.` 这类 schema 前缀；切换据点只换连接数据库或 `-Database` 参数。
- `/dbsql` 只有查询权限语义；可执行查询必须是只读语句：`SELECT`、`SHOW`、`DESCRIBE/DESC`、`EXPLAIN`、`WITH`。
- 数据变更 SQL 只能生成或归档，不自动执行；需要包含预检、备份、事务、更新、验证和回滚说明。

## Failure Rules

- `Check` 未通过时，先报告缺失项和唯一下一步，不继续猜测其它工具路径。
- `mysql` CLI 不存在时，先尝试 Java + DBeaver MySQL JDBC 驱动；两者都不可用时，再停止并提示安装 MySQL client 或配置 JDBC jar。
- 连接失败时，只报告主机、端口、用户、库名和错误摘要；不要输出密码。
