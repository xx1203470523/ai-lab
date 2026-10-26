# 结果契约

本文件说明 `db-ops` 出去的**到底是什么形状**，以及哪些字段是事实、哪些是补充。改契约前先读「修订规则」一节。

## 两个通道

| 通道 | 内容 | 谁看 |
|---|---|---|
| 人读文本（stdout 默认） | `Lines`：多行说明/表格 | 人 |
| 结构化信封（`-Json` 时的 stdout） | `Envelope`：固定字段的结果对象 | 脚本、后续处理、留痕 |
| 错误文本（stderr） | `StderrLines`，每行前缀 `ERROR: ` | 人；**不混进 stdout** |

**stdout 只承载结果，stderr 只承载错误。** 这一条不能破：一旦诊断信息混进 stdout，`-Json` 的输出就不再可解析，而「解析失败」在下游通常表现为「没有结果」——正是本技能最想避免的静默形态。

## 退出码是主契约

**先看退出码，再看信封。** 信封在硬失败时可能为 `$null`（脚本还没走到构造信封那一步），此时 stdout 为空、原因只在 stderr。反过来，**有信封不等于成功**——`Success` 字段可能是 `false`。

| 码 | 语义 |
|---|---|
| `0` | 成功 |
| `1` | 硬失败（配置非法、调用未实现功能、SQL 被只读模式拒绝） |
| `2` | 需要确认 |
| `3` | 缺少确认摘要 |
| `4` | 摘要不匹配 |
| `5` | 目标就绪度不足（`unconfigured` / `unsupported` / `disabled` / `needs-review` / `blocked` / `permission-warning`） |
| `6` | 输入非法（未知路由、未指定目标、参数组合非法、凭据文件结构非法、ACL 失败） |
| `7` | 无法交互 |

两条不能合并的区分（合并会让调用方修错地方）：`5` ≠ `1`（**去改配置** vs **去改代码**）、`2` ≠ `5`（**等你点头** vs **你还没配**）。完整触发点见 `rules/db-ops.rules.md` R6。

## 信封字段

`New-ResultEnvelope` 产出的字段是**固定**的：缺的字段也存在（值为 `$null` / `@()` / `false` / `0`）。这样消费者不必区分「没有这个字段」和「这个字段是空的」——后者是配置演化时最容易踩的坑。

| 字段 | 类型 | 含义 | 来源 |
|---|---|---|---|
| `Success` | bool | 本次是否成功 | 脚本 |
| `Mode` | string | `Validate` / `ListTargets` / … | 脚本 |
| `Route` | string | 路由 id | 脚本 |
| `Database` | string | 库名 | 脚本（来自 `routes.json`） |
| `ReadOnlyUser` | string | 账号，**只显示首字母** | 脚本 |
| `RowsReturned` | int | 实际返回行数 | 脚本 |
| `Limit` | int | 本次生效的 `LIMIT` | 脚本 |
| `LimitReached` | bool | 行数达到上限 | 脚本 |
| `PossiblyTruncated` | bool | 可能还有更多行 | 脚本 |
| `ElapsedMs` | int | 耗时 | 脚本 |
| `Columns` / `Rows` | array | 列名与数据 | 脚本 |
| `ResultFile` | string | 结果落盘路径（若走文件） | 脚本 |
| `Warnings` | array | 告警（如证据层交叉核对失败） | 脚本 |
| `ErrorType` / `ErrorMessage` / `Remediation` | string | 错误分类、信息、修复动作 | 脚本 |
| `RunId` | string | 本次运行的 id，用于把输出与日志对上 | 脚本 |
| `Timestamp` | string | 生成时间（ISO 8601） | 脚本 |
| `EntityEvidence` | string | 「表/列是怎么推断出来的」——实体文件路径与行号 | **AI 补充** |
| `QueryScope` | string | 查询范围的一句话说明（据点、时间窗、状态） | **AI 补充** |
| `Details` | object | 各模式特有的扩展信息 | 脚本 |

**不得由 AI 填写的字段**：`Route`、`Database`、`ReadOnlyUser`、`RowsReturned`、`ElapsedMs`、`LimitReached`、`PossiblyTruncated`。这些是「事实」，只能来自脚本实际返回。AI 手填这些字段等于把证据换成叙述——而这份技能存在的意义正是让结论可追溯。

模式特有信息一律放 `Details`，**不往顶层加字段**：

- `Validate` → `Details`：`SkillRoot`、`CredentialsPath`、`CredentialsFileState`、`CredentialsErrors`、`TargetStatus`、`TargetStatusReason`、`RouteCount`、`ReadyCount`、`ProdReadyCount`、`Routes`、`SqlCheck`、`NonRoutes`。
- `ListTargets` → `Details`：`CredentialsFileState`、`RouteCount`、`Routes`、`NonRoutes`。

`Validate` 另有顶层 `ExplainPlan`，阶段 1 **恒为 `null`**（没有执行器，不做 EXPLAIN）。

## 阶段 1 的实际形状（重要）

阶段 1 只有 `Validate` 与 `ListTargets`，因此：

- **不存在** `Success = true` 且带 `Rows` 的信封。`-Mode Check/Query/File/Exec` 直接 `exit 1` 且信封为 `null`。这是刻意的：一个「什么都没做但返回 0 行」的查询入口，会被当成「查到了，就是没有数据」。
- 其余执行相关字段（`RowsReturned` / `Limit` / `ElapsedMs` / `ResultFile` …）**保持初值**，它们的存在只为让消费者不必改代码。

看到 `RowsReturned = 0` 时**不要**理解为「查了，没有数据」——阶段 1 里它只是初值。

## 截断语义

三个字段必须一起读，任何一个都不能单独用：

- `RowsReturned` 达到 `Limit` → **必须**说「可能还有更多」，不得说成「就这么多」。
- `LimitReached` 由脚本判定；`PossiblyTruncated` 是给使用者看的结论。
- `-Limit 0` 表示**明确不追加** `LIMIT`（需要理由），此时 `Limit` 与截断判定都不适用。

AI 负责**如实转述**，不得修饰、不得推断「大概就这些」。

## 脱敏

- 账号只显示首字母（`root` → `r***`）；完整连接串与口令**永不输出**。
- 展示用连接信息是 `库名@主机:端口`（见 `Get-RedactedRouteInfo`）——库名与 host:port 是诊断信息，可以显示。
- **「输出里没有凭据值」是一条可执行检查**，不是文档里的承诺：`Assert-NoSecretInOutput` 在拿得到凭据值的那一层（`db-ops.ps1` 的 `Invoke-DbOpsMain`）对「stdout 行 + stderr 行 + JSON 信封」的等价渲染文本断言，命中即 `throw`。
- **长度 < 8 的值不参与判定**。取舍：短串会在正常文本里随处误命中（同一个理由也用在 `Protect-SecretText` 上）。代价是**短口令不会被这条断言覆盖**——所以它是补充检查，不是唯一防线；真正的防线是「凭据值根本不往上传递」。
- 断言自身**不回显那个值**（只报长度）：否则断言自己变成泄漏点。

## 渲染格式

| `-Format` | 用途 | 说明 |
|---|---|---|
| `Table` | 默认，给人看 | 定宽表格，单元格内的换行/回车替换为空格 |
| `Tsv` | 粘进表格软件 | 制表符分隔，同样压平单元格内换行 |
| `Json` | 给机器/后续处理 | 完整信封 |

- 未指定 `-Format` 时取 `policy.output.defaultFormat`。
- JSON 一律用 `ConvertTo-Json **-InputObject**`：少了它，`ConvertTo-Json` 会把单元素数组展开成裸对象，于是「只有一条 `Columns`」和「只有一行结果」的形状会与多元素时不同——消费者按数组处理就会失败。这条已在离线用例 T20 覆盖。
- 表格渲染**不做对象属性反射**：`$Rows` 是「字符串数组的数组」。反射会把 `PSCustomObject` 的 provider 属性也带出来，正是要避免的那类膨胀。

## 修订规则

- **允许**：新增顶层字段（消费者必须容忍未知字段）、在 `Details` 里加模式特有信息。
- **不允许**：删除字段、改变已有字段的语义或类型、把 `Details` 里的东西提到顶层而破坏既有消费者。
- 破坏性改动必须同时改三处：`New-ResultEnvelope`、本文件、以及 `tests/run-offline-tests.ps1` 里覆盖该形状的用例。
