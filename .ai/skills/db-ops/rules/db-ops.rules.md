# db-ops 强约束

本文件是 **约束**，不是建议。与技能内其他文档冲突时，以本文件为准。
每条约束后面都写了「为什么」——一条没有理由的禁止，会在下一次「就这一次」时被绕过去。

## R1 配置驱动：JSON 是唯一事实源

- 库名、主机、端口、账号前缀、静态状态**只能**来自 `config/routes.json`；策略**只能**来自 `config/policy.json`。
- 脚本里**不得**新增库名、主机名、账号名、表名的字面量。要加一个库/换一个账号/关一个环境，改 JSON。
- **禁止用命令行覆盖库名**（`-Database` 一律拒绝）。需要另一个库 = 在 `routes.json` 里加一条路由。
- **禁止在运行期推导连接信息**：不许按据点名拼库名（`'wms_' + $site` 这种），不许从应用连接串反推账号。推导出的库名一旦与直觉相反（本项目就有一个），错误会静默发生。

## R2 默认只读

- `Query` / `File` 只接受 `SELECT` / `SHOW` / `DESCRIBE` / `DESC` / `EXPLAIN` / `WITH`，且**一次只允许一条语句**。
- 拒绝清单（写锁语义与会话副作用，旧实现只查首关键字，这些全都能通过）：
  `FOR UPDATE`、`LOCK IN SHARE MODE`、`FOR SHARE`、`SELECT ... INTO @var`、`SLEEP(`、`BENCHMARK(`、`LOAD_FILE(`、`INTO OUTFILE`、`INTO DUMPFILE`。
- **关键字拦截是第二道防线，不是第一道。** 真正兜底的是数据库授权。只读查询**允许**使用现有账号（包括 `root`），但必须经过本技能的静态守卫、单语句限制与行数上限；不要因此认为账号权限可以被忽略。
- **高权限账号永远不得用于写操作。** 写操作必须走 `Exec` 的摘要确认。
- **禁止为了拿总行数自动执行 `COUNT(*)`**，也禁止自动去掉用户的 `WHERE` 去「看看全表」。
- `Validate` / `ListTargets` **完全不连库**；`Check` / `Query` / `File` 只执行只读语句，不做 `EXPLAIN` 之外的分析。

## R3 受控执行：写操作只有一个入口

- 写操作**只能**走 `-Mode Exec`，且必须**同时**满足：
  1. 全局闸门 `policy.exec.allowWrite = true`；
  2. 该路由的 `allowWrite = true`（当前只有 `dev.lebgjm` 打开）；
  3. SQL 是**写语句**且只有一条（只读语句会被拒回 `Query`）；
  4. 第一次运行不带 `-Confirm`：只打印路由、库、账号、语句类型、SQL 原文与摘要，`exit 3`；
  5. 人工核对计划后，把摘要原样传回 `-Confirm <摘要>`；摘要覆盖「路由 + 库 + SQL 原文」；
  6. 摘要不匹配 `exit 4`，不执行。
- **缺任意一项即拒绝**，且**不提供** `-Force` / `-Yes` / `--non-interactive` 之类的免确认开关。
- **禁止**把写 SQL 塞进 `Query` / `File`「先试试看」。
- **尚未实现**：执行前自动备份、独立审计日志、影响行数上界预估。因此写操作只应在开发库使用；正式库的写操作继续走「人工在数据库客户端执行 + 按 `sql/` 规范归档」。

## R4 凭据保护

- 凭据文件**只有一处**：`policy.credentialsPath`。任何脚本都不得硬编码另一条路径。
- 凭据值**不得**出现在：技能目录内的任何文件、SQL 文件、日志、任务报告、命令行参数、环境变量、会话输出。
- **凭据迁移必须由人明确指示。** 经用户要求，可以把 `dbsql/.env` 的现有条目导入 `%LOCALAPPDATA%\db-ops\credentials.env`；导入只写 db-ops 自己的文件、收紧 ACL，不修改 `dbsql/.env`，也不在输出里回显值。未经指示不得自行迁移。
- 账号命中 `policy.credentials.highPrivilegeUserPattern`：只读查询**允许**，状态依据里追加告警；写操作仍受 `Exec` 摘要确认约束。不再判 `blocked`。
- 凭据文件必须「仅当前用户可访问」；收紧或复验失败**必须报错退出**，**不得**声称已保护。
- 输出里的账号只显示首字母（`root` → `r***`）。完整连接串与口令永不输出。
- **不自动把现有生产凭据重新归属到其他路由**，也不自动创建、覆盖、删除凭据文件。

## R5 失败闭合

- 未实现的功能、未指定的目标、未知路由、非法配置：**明确报错 + 非零退出码**。
- **禁止**「返回 0 行」这种看起来成功的形态——一个静默成功的查询入口会被当成「查到了，就是没有数据」。
- **禁止路由近似匹配**：不做前缀匹配、不做大小写归一、不做「最接近的一条」。未命中就是未命中。
- **禁止在配置非法时打印半张路由表**（半个表格看起来像一次成功的列举）。
- 错误信息里**不得回显凭据文件的可疑行内容**（坏行里可能带明文口令），只报行号与键名。

## R6 退出码契约

| 码 | 语义 | 典型触发 |
|---|---|---|
| `0` | 成功 | Validate 通过、ListTargets 成功、Check/Query/File 执行成功、Exec 执行成功、setup 成功 |
| `1` | 硬失败 | JSON 非法、`schemaVersion` 未知、未知字段、SQL 被只读模式拒绝、Exec 收到只读 SQL 或多条语句 |
| `2` | 需要确认 | `setup-credentials.ps1 -Force` 未同时给 `-ConfirmReset` |
| `3` | 缺少确认摘要 | Exec 写操作没有 `-Confirm`（只打印计划） |
| `4` | 摘要不匹配 | Exec 的 `-Confirm` 与当前「路由 + 库 + SQL 原文」不符 |
| `5` | 目标就绪度不足 | `unconfigured` / `unsupported` / `disabled` / `needs-review` / `blocked` / `permission-warning` |
| `6` | 输入非法 | 未知路由、未指定目标、参数组合非法、凭据文件 `invalid`、ACL 设置或验证失败、Query 缺少 `-Sql`/`-SqlPath` |
| `7` | 无法交互 | 非交互环境调用 `setup-credentials.ps1` |

两条不能合并的区分（合并会让调用方修错地方）：

- `5` ≠ `1`：**去改配置** vs **去改代码**。
- `2` ≠ `5`：**等你点头** vs **你还没配**。

## R7 路由状态语义

- 静态 `status`（写在 `routes.json`，表示证据是否充分）与运行期 `effectiveStatus`（脚本算出，表示现在能不能用）**是两件事**。凭据变化**不得**导致 `routes.json` 被感知为「需要更新」。
- `ready` 只表示「配置与权限齐备」，**不表示**已连通过数据库。
- 目标不是 `ready` 就**停下**，把 `statusReason` 原样转述给用户；不得「先查了再说」。
- `unsupported` 与 `disabled` 必须分开：前者是「配上也不能用」，后者是「刻意关掉」。

## R8 输出与证据

- 每条结论都要能追到证据：目标路由、库名、SQL 意图、范围限制、影响行数。
- `Route` / `Database` / `RowsReturned` / `ElapsedMs` / 截断状态**必须来自脚本实际返回**；AI 不得自行填写这些字段（`EntityEvidence` 与 `QueryScope` 可以由 AI 补充）。
- **不得把「被截断」说成「就这么多」**。截断状态由脚本给出，AI 负责如实转述。
- 报告里不得出现密码、完整连接串、凭据文件的完整内容。

## R9 维护

- 改脚本行为前，**先加或改离线用例**；`tests/run-offline-tests.ps1` 必须全绿（当前 49 条）且**用例条数**与期望一致，否则本次改动不算完成。
- **离线用例不得连真实数据库。** 涉及执行的用例只覆盖连接之前的闸门：未配置 → 5、Exec 只读 → 1、缺摘要 → 3、摘要错 → 4。
- `dbsql` 是回退路径：只做让只读查询可用的必要修复，不扩大改动面。
- 发现范围外的可优化点：**记录，不顺手改**。
- 路由要升级为 `ready`，必须有配置级证据或人工确认；只凭「工具 ini」或「历史文档」一律维持 `needs-review`。

## R10 平台约束（Windows PowerShell 5.1）

- `.ps1` 必须 **UTF-8 with BOM**；`.json` / `.md` 必须 UTF-8 **无 BOM**。无 BOM 的 `.ps1` 会被按 ANSI 读，中文提示变乱码，甚至因引号被吃掉而语法错误。
- 不使用 `??` / `?.` / 三元运算符。
- **`@()` 不得作用于 `System.Collections.Generic.List[object]`**（会抛 `ArgumentException: Argument types do not match`）。用 `.ToArray()` 或走管道。`List[string]` / `List[int]` / `ArrayList` 不受影响。
- **`$host` 是只读自动变量**（`AllScope`），而变量名大小写不敏感：任何作用域里写 `$host = ...` 都会抛「Cannot overwrite variable Host」。要存主机名请用 `$hostName`。
- `param` 块默认值里 **`$PSScriptRoot` 为空**，路径解析一律放在脚本体内。
- 交互性判断的唯一可靠依据是 `[Console]::IsInputRedirected`；**不得用 `$Host.Name`**（agent 派生进程里它仍是 `ConsoleHost`）。
- 凭据文件 ACL **只写 DACL**（`[IO.File]::SetAccessControl` + 只含 DACL 的 `FileSecurity`）。**不得用 `Set-Acl`**：它会把 SACL 一并写回，写 SACL 需要 `SeSecurityPrivilege`，于是「对已收紧的文件再次收紧」必定失败；而且该失败是**非终止**错误，在 `$ErrorActionPreference='Continue'` 的调用方那里会被 `try/catch` 漏掉，报成「成功」。
- 函数返回单元素数组时，管道会把数组解包成裸元素，调用方的 `.Count` 在 `Set-StrictMode 2.0` 下会抛错。返回列表写 `return , @(...)`。
