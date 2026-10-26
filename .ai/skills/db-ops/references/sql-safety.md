# SQL 静态守卫语义（`scripts/lib/sql-safety.ps1`）

本文件说明只读守卫**到底拦什么、为什么拦、以及它拦不住什么**。文档描述的是当前实现的实测行为，不是设计意图——行为改了，文件要跟着改。

## 定位：第二道防线

**第一道防线是数据库授权。** 守卫是一段正则，它不可能穷举 SQL 的所有写法。它存在的意义是「让误操作在发出前就被拦下」，不是「保证只读」。

由此推出一条硬约束：**不得用高权限账号跑只读查询**。用 `root` 跑只读，等于把唯一真正有效的防线拆掉，只留下一个正则在挡着。

## 判定顺序（短路）

```
空 → 掩码后为空 → 首关键字白名单 → 语句条数（必须恰好 1） → 拒绝清单 → 通过
```

顺序是刻意的：**每一条都短路**，所以报出的原因是**第一个**命中的原因，而不是全部原因。报「语句条数」时说明首关键字已经合法，报「拒绝清单」时说明种类与条数都已经过关。

| 阶段 | 判据 | 不通过的 `Reason` |
|---|---|---|
| 空 | `IsNullOrWhiteSpace(原文)` | `SQL 为空。` |
| 只剩注释 | 掩码后为空 | `SQL 里只有注释或空白，没有可执行语句。` |
| 首关键字 | ∈ `SELECT` / `SHOW` / `DESCRIBE` / `DESC` / `EXPLAIN` / `WITH` | `只读模式只接受 … 开头的语句，当前是 {Kind}。` |
| 语句条数 | 掩码上按 `;` 切分，非空段数 `= 1` | `一次只允许一条语句，检测到 N 条。` |
| 拒绝清单 | 掩码上全文正则不命中 | `SQL 含被拒绝的写法：'{命中片段}'。` |

`Kind` 为 `EMPTY` / `OTHER` 时都走「首关键字不合法」这一条；只有掩码全空才单独报「只有注释」。

## 掩码（`Get-MaskedSql`）

单趟字符扫描，输出**与原文等长**的文本：

- 注释（`-- `、`#`、`/* */`）与字符串字面量（`'…'`、`"…"`、`` `…` ``）的内部字符 → 空格；
- **换行原样保留**。理由不是美观：行号一旦漂移，`InvocationInfo` 与报错定位就失去意义。
- 三种引号都掩，**反引号也掩**——表名叫 `` `update` `` 不该触发误报。
- 只按 MySQL 方言处理，不按「通用 SQL」猜：`--` 后面必须跟空白或行尾才算注释（`SELECT a--b` 不是注释）；字符串里 `\x` 是转义、`''` 是一个单引号。

### 为什么必须先掩码

旧实现在**原文**上跑关键字黑名单，于是这句完全正常的只读查询被拒：

```sql
SELECT * FROM t WHERE note = 'please update the record'
```

误报的代价不是「多拦一次」。**误报会训练使用者绕开守卫**，而绕过守卫的那次，拦不住的是真写操作。掩码消除误报，守卫才有人愿意遵守。

### 为什么两份文本都要留

掩码**只**用于关键字与分号判定。原文必须留着，用于错误回显、阶段 2 的 `LIMIT` 追加、以及给用户看「你提交的到底是哪句」。在掩码上做这些会把 `LIMIT 10` 里的数字一起抹掉。

## 拒绝清单（`Get-SqlBlockedPattern`）

在掩码上**全文匹配**，命中即拒。分四类：

| 类别 | 命中项 | 为什么要拒 |
|---|---|---|
| 写与 DDL / DCL / 会话 | `ALTER` `CREATE` `DROP` `TRUNCATE` `INSERT` `UPDATE` `DELETE` `REPLACE` `MERGE` `CALL` `GRANT` `REVOKE` `RENAME` `HANDLER` `PREPARE` `EXECUTE` `DEALLOCATE` `SAVEPOINT` `XA` | 直接改结构或数据 |
| 锁语义 | `LOCK` `UNLOCK` `FOR UPDATE` `FOR SHARE` `LOCK IN SHARE MODE` `GET_LOCK` / `RELEASE_LOCK` / `IS_FREE_LOCK` / `IS_USED_LOCK` | 只读查询也会阻塞线上业务 |
| 会话与事务副作用 | `SET` `USE` `BEGIN` `COMMIT` `ROLLBACK` `START TRANSACTION` / `START REPLICA` / `START SLAVE` / `STOP REPLICA` / `STOP SLAVE` / `CHANGE MASTER`、`INTO` | 改会话状态或影响复制拓扑 |
| 服务器文件与资源消耗 | `LOAD` `LOAD_FILE(` `INTO OUTFILE` / `INTO DUMPFILE`（由 `INTO` 覆盖）、`SLEEP(` `BENCHMARK(`、`PURGE` `ANALYZE` `OPTIMIZE` `REPAIR` `FLUSH` `RESET` `KILL` `SHUTDOWN` `INSTALL` `UNINSTALL`、`PROCEDURE ANALYSE` | 读服务器本地文件、把查询变成压测、或影响实例 |

`INTO` 是**整体拒绝**的：纯 `SELECT` / `SHOW` / `DESC` / `EXPLAIN` / `WITH` 里不会合法地出现 `INTO`。这一条同时覆盖了 `SELECT … INTO @var`（会话副作用）与 `INTO OUTFILE`（写服务器文件）。

关于 `FOR UPDATE` / `LOCK IN SHARE MODE`：旧守卫其实**拦得住**它们，但拦住的方式不可靠——`FOR UPDATE` 命中 `\bUPDATE\b`，`LOCK IN SHARE MODE` 命中 `\bLOCK\b`，也就是说它同时拦掉了上面那句 `WHERE note = '… update …'`。这里把它们显式列出来，让「拦住」与「只拦该拦的」同时成立。**真正被旧守卫漏掉、本清单补上的**是：`FOR SHARE`（MySQL 8 的共享锁，没有 UPDATE/LOCK 字样）、`INTO @var`、`GET_LOCK` 系列、`SLEEP`/`BENCHMARK`、`PROCEDURE ANALYSE`、`LOAD_FILE`。

## 白名单与黑名单的分工（`WITH … DELETE` 的实测结论）

白名单只判**首关键字**，因此在 MySQL 8 里合法、但其实是写操作的下面这句，首关键字是 `WITH`：

```sql
WITH x AS (SELECT Id FROM t) DELETE FROM t WHERE Id IN (SELECT Id FROM x)
```

它被拦下了——**靠的是拒绝清单里的 `DELETE`，不是白名单**。实测：

```
WITH + DELETE（CTE 写语句）   Ok=False Kind=WITH  条数=1   SQL 含被拒绝的写法：'DELETE'。
WITH + SELECT                Ok=True  Kind=WITH  条数=1   只读语句通过静态校验（WITH，1 条）。
```

这说明两件事：白名单**不构成**安全保证，黑名单才是最后一道文本防线；两者都必须留着。

## `LIMIT` 追加（`Add-SqlLimitIfMissing`）

**判断在掩码上做，追加在原文上做**，分工不能串。

- `Test-SqlHasTopLevelLimit` 在掩码上判断结尾是否已有 `LIMIT n`（允许带 `OFFSET n`）。旧实现用 `-notmatch '\bLIMIT\s+\d+\s*;?\s*$'`，有两个缺陷：`LIMIT 10 OFFSET 5` 判不出来，会再追加一个 `LIMIT` 让语句直接语法错误；结尾有注释时同样判不出来，追加的结果会把注释吃掉。
- 追加保留原有结尾分号的位置，实测：

```
输入：SELECT Id FROM t;   -- tail
输出：SELECT Id FROM t;   -- tail
      LIMIT 50;
```

`-Limit 0` 表示**明确不追加**，需要给出理由（见 `workflows/query-flow.md`）。

## 返回对象

`Test-ReadOnlySql` **返回对象，不抛异常**——调用方需要同时拿到「结论」和「为什么」，`Validate` 模式要把二者一起报给用户。需要「失败即中止」的调用方用 `Assert-ReadOnlySql`。

| 字段 | 含义 |
|---|---|
| `Ok` | 是否通过 |
| `Kind` | 首关键字（大写）；`EMPTY` / `OTHER` 表示无法识别 |
| `StatementCount` | 掩码上的非空语句段数 |
| `Reason` | **可直接展示给用户**的中文说明（含修复方向） |
| `Masked` | 掩码结果，供诊断 |
| `TextHash` | 原文的短摘要（`Get-Sha256Short`，16 位），用于留痕而不落 SQL 原文 |

`Test-WriteSql` 是阶段 2 的 Exec 闸门预留：只做分类（`IsWrite` / `Kind` / `StatementCount`），不执行任何东西。

## 已知边界（不做的，别指望）

- **不做语义解析**：不建语法树，不知道表名、列名、权限、行数。
- **不校验对象存在性**：表不存在、列拼错、字段权限不足，都要等真正查库才知道。
- **看不进可执行体**：存储过程/函数体内如果藏了写操作，文本上只是一个 `CALL`——`CALL` 已被整体拒绝，所以这里是靠「拒绝整类」而不是靠「看懂」。
- **不防资源消耗的一般形式**：只挡了 `SLEEP`/`BENCHMARK` 这种显式写法；不带 `LIMIT` 的大范围扫描仍然会打满库。控制它靠 `workflows/query-flow.md` 的收窄要求与 `policy.output.maxRows`，不靠守卫。
- **阶段 1 完全不连库**：`EXPLAIN` 在允许清单里，但阶段 1 不会真的执行它（`ExplainPlan` 恒为 `null`）。放进白名单是为阶段 2 留位。
- **不做 SQL 改写**：守卫只判定，不改写用户提交的语句（唯一的例外是 `LIMIT` 追加，且它是独立函数，不在守卫里）。

## 改守卫的规矩

1. **先加或改用例**，再改实现。`tests/run-offline-tests.ps1` 必须全绿且条数与期望一致（见 `rules/db-ops.rules.md` R9）。
2. 每条拒绝项都要能说清「它在只读模式下为什么没有合法用法」。说不清的，多半是误报。
3. **被守卫拒绝时的正确动作是改 SQL，不是改守卫。** 如果确有合法用途，先补用例说明它为什么合法，再动实现。
