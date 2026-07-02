# MySQL Query Flow

## Purpose

用最少步骤完成 WMS MySQL 查询：快速检查 → 生成/选择 SQL → 脚本执行 → 汇总结果或失败动作。

## Inputs

- 用户问题、单号、日期范围、表名或目标 SQL。
- 可选环境名；未给出时使用 `.env` 的 `DBSQL_DEFAULT_ENV`，当前支持 `dev` / `prod`。
- 可选目标库名；未给出时使用所选环境的 `DB_NAME`，生产查询显式传 `-Environment 'prod'`。
- 是否只生成 SQL、是否需要实际查询。

## Flow

1. **分类请求**
   - 查数据：进入脚本只读查询；强调 `/dbsql` 只有查询权限，不执行写操作。
   - 只要 SQL：直接生成 MySQL SQL，不连接数据库。
   - 归档 SQL：按 `sql/` 目录规范生成文件；写操作 SQL 不执行。

2. **快速检查**
   - 同一轮未检查过时运行；默认 Auto 会优先 `mysql` CLI，缺失时使用 Java + DBeaver MySQL JDBC 驱动：

   ```powershell
   & "C:\Users\liyanpeng\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode Check
   ```

   - 检查失败就停止，输出缺失项和一个下一步动作。

3. **准备 SQL**
   - 优先写单库 SQL，不加 schema 前缀。
   - 复杂入库/上架问题按需读取 `references/wms-mysql-reference.md`。
   - 长 SQL 用临时 `.sql` 文件再传给脚本，避免命令行转义成本。

4. **执行只读查询**

   ```powershell
   & "C:\Users\liyanpeng\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode Query -Sql '<SQL>'
   ```

   或：

   ```powershell
   & "C:\Users\liyanpeng\.claude\skills\dbsql\scripts\dbsql-mysql.ps1" -Mode File -SqlPath '<file.sql>'
   ```

5. **输出结果**
   - 简短说明目标数据库、SQL 意图、关键结果。
   - 查询失败时只给一个可执行修复动作，不展开多套备用流程。

## Verification

- `Check` 成功代表 `.env` 和某个 MySQL 执行驱动可用：`mysql` CLI 或 Java + DBeaver MySQL JDBC；不代表业务 SQL 正确。
- 查询脚本的只读保护拦截 SQL 时，先改成预检 SELECT；不要关闭保护执行写操作。
