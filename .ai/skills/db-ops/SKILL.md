---
name: db-ops
description: "通用数据库操作技能（配置驱动）。按 routes.json 声明的路由做只读查询与受控写执行，凭据外置于技能目录，路由状态显式化并可离线自检。触发关键词：数据库、查库、查表、SQL、执行 SQL、改数据、订正数据、排查重复问题、db-ops、/db-ops"
shell: powershell
version: 1.0.0
---

<!-- 本技能全部文件位于用户级技能目录（%USERPROFILE%\.claude\skills\db-ops\），不在任何 Git 仓库内。
     后果有两面，不要只记一面：
     1. 这里的改动不会出现在任何仓库的 git diff / 暂存区里，因此不触发仓库的 commit-msg 日志门禁，
        也不会被仓库的 Stop hook 计入「Git 可见改动」。
     2. 但「这次会话产出了文件改动」这件事，仍要在工作所在的仓库留一份任务日志——日志记的是
        这次会话做了什么，不是仓库里改了什么。按 D:\Project\WMS 的规则写在 logs/{git-user}/{date}/ 下。 -->

# db-ops — 通用数据库操作（配置驱动）

## 这个技能的设计前提

**要加一个库、换一个账号、改一条策略，只改 JSON，不改 PowerShell。**

- 路由（环境、租户、据点、引擎、库名、主机、凭据前缀、静态状态）全部在 `config/routes.json`。
- 非秘密策略（凭据路径、行数上限、临时目录、日志、执行闸门）全部在 `config/policy.json`。
- 脚本里不应该出现任何库名、主机名、账号名或表名的字面量。
- 因此：**用户提出新的数据库需求时，先问「这是配置能表达的，还是需要改脚本」**。加一个据点、加一个只读账号、关掉某个环境——都是改 JSON。

**本技能不绑定任何业务系统。** 顶层只放引擎无关契约（路由模型、凭据模型、SQL 安全、结果契约）；业务知识降级为可插拔 profile，放在 `references/projects/<name>/`。

**安全基线是分层的：默认只读 + 受控执行。**

| 层 | 模式 | 语义 |
|---|---|---|
| 只读层 | `Query` / `File` | 只允许 `SELECT` / `SHOW` / `DESCRIBE` / `DESC` / `EXPLAIN` / `WITH`，且拒绝写锁语义与多语句 |
| 受控执行层 | `Exec` | 写操作唯一入口：全局 `exec.allowWrite` 闸门 + 计划摘要 + 显式确认 + 事务 + 备份 + 回滚 + 审计 |

**阶段 1 只交付只读层与全部离线能力，`Exec` 与真实连库留到阶段 2。** 本轮不连接任何数据库。

## 当前阶段（阶段 1）能力边界

| 模式 | 阶段 1 状态 |
|---|---|
| `Validate` | **可用**。离线校验配置、路由、SQL 守卫、凭据文件，不连库 |
| `ListTargets` | **可用**。列出每条路由的可用状态与依据 |
| `Check` / `Query` / `File` | **未实现**，明确报「阶段 2 未实现」并 `exit 1`，不静默成功 |
| `Exec` | **未实现**且全局写闸门 `exec.allowWrite=false` |
| 菜单/权限操作模板 | **仅生成，不执行**。`sql/operations/` 是泛化写模板（不含真实 Id），技能不会执行它们；实例化后进项目仓库、由人在数据库客户端跑。本阶段写操作唯一的合法路径见 `workflows/exec-flow.md` |

`scripts/setup-credentials.ps1` 本阶段可用（只写凭据文件，不连库）。

## 目录结构

```
SKILL.md                          入口：设计前提、模式、流程、安全边界、已知坑
config/routes.json                唯一路由定义：环境/租户/据点/引擎/库名/主机/凭据前缀/静态状态
config/policy.json                非秘密策略：凭据路径、输出上限、临时目录、日志、执行闸门
rules/db-ops.rules.md             强约束：默认只读、受控执行、凭据保护、失败闭合
workflows/query-flow.md           只读查询流程
workflows/exec-flow.md            受控写执行流程（阶段 2）
workflows/troubleshoot-flow.md    场景剧本排查流程（重复问题定位）
references/sql-safety.md          引擎无关：守卫语义、多语句、注释与字面量边界
references/result-contract.md     结果契约：退出码、信封字段、哪些字段必须来自脚本实测
references/projects/wms/routes.md          据点语义、DBTenant 映射、DefaultSite 陷阱
references/projects/wms/orm-boundaries.md  实体→表、按 IDeletedFilter 判定软删除
references/projects/wms/menu-management.md 菜单/权限边界：列名契约、路由契约、删除守卫、操作顺序
references/projects/wms/scenarios/          WMS 专属排查剧本
scenarios/_TEMPLATE.md            通用剧本格式样板
scripts/db-ops.ps1                唯一公开入口
scripts/setup-credentials.ps1     首次/重建外置凭据文件
scripts/lib/                      common / log / config / credentials / sql-safety / output
sql/README.md                     归档规范（含「项目发布 SQL 归项目仓库」「operations/ 是模板不是发布脚本」的边界）
sql/index.md                      归档索引（只登记 queries/）
sql/queries/                      归档的只读查询（首次归档时创建）
sql/operations/                   写操作模板（泛化、不含真实 Id、技能不执行、不登记索引）
tests/run-offline-tests.ps1       离线用例套件（不连库、不写仓库文件）
```

## 入口与参数

```powershell
$sk = "$env:USERPROFILE\.claude\skills\db-ops\scripts"

# 离线校验（不连库、不写文件）
powershell -NoProfile -File "$sk\db-ops.ps1" -Mode Validate -Target dev.lebgjm

# 看每条路由为什么可用/不可用
powershell -NoProfile -File "$sk\db-ops.ps1" -ListTargets

# 只校验一段 SQL 的只读性（不连库）
powershell -NoProfile -File "$sk\db-ops.ps1" -Mode Validate -Target dev.lebgjm -Sql 'SELECT 1'

# 首次建立外置凭据（只应在交互式终端里跑）
powershell -NoProfile -File "$sk\setup-credentials.ps1"

# 离线用例套件：改完脚本先跑它（不连库、不写仓库文件）
powershell -NoProfile -File "$env:USERPROFILE\.claude\skills\db-ops\tests\run-offline-tests.ps1"
```

| 参数 | 说明 |
|---|---|
| `-Mode` | `Validate`（默认）/ `ListTargets` / `Check` / `Query` / `File` / `Exec` |
| `-Target` | 路由 id，例如 `dev.lebgjm`。**精确匹配，无前缀匹配、无模糊回退** |
| `-Environment` | **只是 `-Target` 的别名**，不是独立维度。据点与环境一律通过路由 id 表达 |
| `-Sql` / `-SqlPath` | 待校验或执行的 SQL 文本 / 文件 |
| `-Limit` | 行数上限，缺省取 `policy.output.maxRows`；`0` 表示不追加 |
| `-Format` | `Table`（默认）/ `Tsv` / `Json` |
| `-Database` | **默认禁止**。库名是 `routes.json` 的事实，不允许在命令行覆盖 |
| `-Json` | 输出单个 JSON 信封 |
| `-Root` | 覆盖技能根目录（仅供测试） |

## 路由状态

**静态 `status`（写在 `routes.json` 里，表示证据是否充分）与运行期 `effectiveStatus`（脚本算出来，表示现在能不能用）是两件事。** 凭据变化不会让配置文件显得「需要更新」。

| 静态 `status` | 含义 |
|---|---|
| `ready` | 有应用配置（`appsettings*.json`）直接证据，引擎有执行器，与据点→库映射不冲突 |
| `needs-review` | 库名只来自单一非配置来源（工具 ini、注释、历史文档），需人工确认 |
| `unsupported` | 引擎没有执行器（Oracle），或后端能力本身不存在 |
| `disabled` | 策略显式关闭 |

运行期 `effectiveStatus` 按序取首个命中：`unsupported` → `needs-review` → `disabled` → `unconfigured` → `blocked` → `permission-warning` → `ready`。

- `unconfigured`：凭据文件缺失/不可解析，或该路由的前缀键不全。
- `blocked`：账号命中高权限黑名单，或凭据声明的主机/端口与 `routes.json` 不一致。**不提供绕过开关。**
- `permission-warning`：凭据文件 ACL 不是「仅当前用户」。
- `ready`：以上都不命中，且凭据齐备。**`ready` 只表示「配置与权限齐备」，不表示已连通过数据库。**

## 流程

1. **确定目标**：从用户提词抽出环境、据点、租户；映射成一条路由 id。映射不上就报「未匹配命令」，**不要**猜一个最接近的。
2. **看状态**：跑 `-ListTargets`，或直接 `-Mode Validate -Target <id>`。状态不是 `ready` 就停，把 `statusReason` 原样告诉用户，不要继续往下走。
3. **准备 SQL**：默认单库、不写 schema 前缀、带 `LIMIT`、优先索引字段收敛。
4. **执行**（阶段 2）：`-Mode Query`（短 SQL）/ `-Mode File`（长 SQL）。
5. **输出**：说明路由、数据库、SQL 意图、关键结果、范围限制；输出里不得出现密码或完整连接串。

## 安全边界

- **凭据永不进入技能目录、SQL 文件、日志、任务报告或命令行参数。** 唯一位置由 `policy.credentialsPath` 决定（当前 `%LOCALAPPDATA%\db-ops\credentials.env`），两个脚本都从 policy 读，任何脚本都不得硬编码另一条路径。
- **不允许把密码写进命令参数。** 执行由脚本自身从凭据文件读取，会话内不落明文变量。
- **路由回退一律禁止**：`-Target` 未给且 `defaultRoute` 为 `null` 时报错退出，不静默选开发库；`-Database` 不允许覆盖。
- **高权限账号一律拒绝**：账号命中 `policy.credentials.highPrivilegeUserPattern` 即 `blocked`，不因环境是开发库而放宽。
- **失败闭合**：配置非法、凭据不可解析、ACL 无法收紧/无法验证，一律报错退出，**不得声称成功**。
- **不主动扩大范围**：发现别的可优化点时只记录，不在本阶段顺手改。

## 已知坑

- **Windows PowerShell 5.1 把无 BOM 的 `.ps1` 当 ANSI 读。** 本技能所有 `.ps1` 必须 UTF-8 **带 BOM**；`.json` / `.md` 必须 UTF-8 **不带 BOM**。
- **`$PSScriptRoot` 在 `param` 块默认值里为空。** 路径解析一律放在脚本体内。
- **`[Console]::IsInputRedirected` 是判断交互性的唯一可靠依据。** `$Host.Name` 在 agent 下仍然是 `ConsoleHost`，用它判断会误判。
- **空数组跨函数边界会解包成 `$null`。** 返回列表要写成 `@(...)`。
- **`ConvertTo-Json` 会展开单元素数组。** 需要保留数组形状时用 `-InputObject` / 显式 `@()`。
- **数据文件不得带 BOM**，否则别的工具解析时会多出一个 `U+FEFF`。
- **`@(...)` 套在 `System.Collections.Generic.List[object]` 上会抛 `ArgumentException: Argument types do not match`。** 用 `@()` 兜空数组只对 `$null` 和数组安全；函数返回的是 `List` 时要先 `.ToArray()`。这个坑会让脚本在最外层 `trap` 里整体中止，表现为「什么都没输出就退出」，非常难往回找。
- **单元素数组会解包，`.Count` 因此不可信。** 只返回一个元素时 `(Get-X).Count` 是 `$null` 而不是 `1`；要数数量写成 `@(Get-X).Count`。
- **`Set-Acl` 会连 SACL 一起写，普通权限下是「非终止失败」。** 收紧凭据文件权限只写 DACL：构造 `FileSecurity` → `SetAccessRuleProtection($true, $false)` → `[IO.File]::SetAccessControl()`。用 `Set-Acl` 时没有 `SeSecurityPrivilege` 会报「拒绝访问」但不抛异常，于是出现「以为收紧了、实际没动」——所以写完必须 `Test-CredentialsFileAcl` 复验，失败即硬失败。
- **`$host` 是 AllScope + ReadOnly 的自动变量。** 不要拿来当局部变量名或函数参数名，会被静默影响且报错信息与真正的原因无关。

## 未匹配命令

用户的提词匹配不上任何路由时，回复要包含：候选路由 id（带状态）、当前 `-ListTargets` 的摘要、以及「需要确认的是据点还是租户」。**不要**近似匹配到某条路由后继续执行。
