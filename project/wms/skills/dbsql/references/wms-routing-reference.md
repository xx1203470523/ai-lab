# WMS 数据库路由参考

本文件只维护非秘密路由语义，不复制项目连接串、账号、密码或报表连接密文。实际目标必须在用户级 `.env` 中配置对应只读连接。

| 逻辑目标 | `dbsql` 目标 | 环境变量前缀 | 当前代码依据 | 状态 |
|---|---|---|---|---|
| 开发 WMS | `dev` | `DEV_` | `DBTenant.Default` / WMS 实体 | 可用前提是只读账号 |
| 正式 LEBG | `prod.lebg` | `PROD_LEBG_` | WMS 主业务部署 | 需显式配置 |
| 正式 LEBGTY | `prod.lebgty` | `PROD_LEBGTY_` | 据点独立库 | 需显式配置 |
| 正式 LEBGJS | `prod.lebgjs` | `PROD_LEBGJS_` | Staging 配置出现该库名 | 需显式配置 |
| 正式 LEBGCH | `prod.lebgch` | `PROD_LEBGCH_` | 用户指定据点 | 需显式配置 |
| 正式 LABG | `prod.labg` | `PROD_LABG_` | 用户指定据点 | 需显式配置 |
| 正式 BPBG | `prod.bpbg` | `PROD_BPBG_` | 用户指定据点 | 需显式配置 |
| 从库 | `replica` | `REPLICA_` | 应用 `WMS_ReadOnly`/Slave 语义 | 未配置不得回退主库 |
| BI | `bi` | `BI_` | `DBTenant.BI`；项目当前为 Oracle 配置 | MySQL 脚本不执行 |
| 日志库 | `logs` | `LOGS_` | `DBTenant.Logs` | 需显式配置 |
| 立库库 | `warehouse` | `WAREHOUSE_` | `DBTenant.AutomationWarehouse` | 需显式配置 |

## 配置契约

每个 MySQL 目标需要：`<PREFIX>DB_HOST`、`DB_PORT`、`DB_USER`、`DB_PASS`、`DB_NAME`。账号必须是经授权的只读账号；账号名包含 `read`、`readonly` 或 `rd` 只是本地约束提示，不是数据库权限证明。

正式库必须按据点单独配置，禁止把 `PROD_DB_NAME` 隐式解释为所有正式据点。`-Target` 是首选路由入口；任意数据库名覆盖不得绕过目标配置。

`report-site` 不属于静态路由：应用从共享库 `sys_site` 读取并解密报表连接后动态建立版本化 Scope。dbsql 不读取该密文，也不尝试恢复动态连接。
