# WMS 项目路由语义（profile）

本文件是 **WMS 专属知识**，不是通用契约。通用部分（配置驱动、只读守卫、退出码、结果契约）在 `references/` 顶层与本技能根目录的 `rules/db-ops.rules.md`。

所有结论都标了证据。**证据会过期**——引用行号可能随提交漂移，值也可能被本地改动覆盖。用之前先按文件复核一遍。

## 三个正交维度

| 维度 | 取值来源 | 说明 |
|---|---|---|
| 环境 | `appsettings.<Environment>.json` | `dev` / `stag` / `prod` |
| 租户 | `DBTenant` 常量 → `ConfigId` | `WMS` / `AutomationWarehouse` / `Shared` / `Logs` / `BI` / `WMS_ReadOnly` |
| 据点 | **运行期**决定 | 请求头 / Token / `System.DefaultSite`，代码里**没有静态据点清单** |

`DBTenant`（`Domain/Domain.Shared/Constants/Database/DBTenant.cs:6-37`）只是**常量名册**，类内**不含任何库名映射**。真正的「ConfigId → 库名」映射在 `appsettings` 的 `ConnectionConfigs[].ConnectionString` 里的 `Database=`。因此：

- **不要**从 `DBTenant` 反推库名，也不要按据点名拼库名（`'wms_' + $site` 这种）。
- 据点与库名之间**没有任何推导关系**，映射只能来自证据。这条不是洁癖：正式环境的据点 `LEBGJM` 对应库 `wms_lebg`（同名后缀对不上），而据点 `LEBG` 对应的却是 `wms_lebgty`（见下）。

## 据点 → 库：唯一仓库内证据是工具侧 ini

`tools/库存比对/inventory_diff_config.ini` 的 `[site_db]` 段：

```
LEBGJM = wms_lebg      LEBGCH = wms_lebgch
LEBG   = wms_lebgty    LEBGJS = wms_lebgjs
LABG   = wms_labg      LEBGSZ = wms_lebgty
```

这是**工具侧配置，不是应用真值**。因此 `routes.json` 把它放在 `siteDatabaseMap` 里只作**证据层**，仅在 `Validate` 时做告警式交叉核对，**不参与运行期解析**。

两个必须知道的坑：

1. **`LEBG` → `wms_lebgty`，而 `LEBGJM` → `wms_lebg`**。「LEBG 是主据点」的直觉在这里是错的。旧技能文档把 `prod.lebg` 当作主库路由，使用者写 `prod.lebg` 会落到 `wms_lebgty`——**库选错不会报错**。本技能保留路由 id `prod.lebg`，但它的含义是「据点 LEBG 的库 `wms_lebgty`」，并在 `statusReason` 里显式告警；**不存在**「`prod.lebg` = `wms_lebg`」这种旧含义。
2. **多据点共库**：`LEBG` 与 `LEBGSZ` 都指向 `wms_lebgty`。这是合法结构，配置必须能表达它，不能假设「一据点一库」。

## `System.DefaultSite` 不能用来推断库

| 环境 | 提交版本的 `DefaultSite` | 该环境主库 |
|---|---|---|
| dev | `LEBGJM`（`appsettings.Development.json:118`） | `wms_lebg`@10.10.80.211 |
| stag | `LEBGJS`（`appsettings.Staging.json:54`） | `wms_lebgjs`@10.10.76.108 |
| **prod** | **`BPBG`**（`appsettings.Production.json:73`） | `wms_lebg`@10.10.76.167 |

**正式环境的默认据点（`BPBG`）与正式 WMS 主库（`wms_lebg`）不是一回事。** 而且 `DefaultSite` 会被本地环境切换覆盖：本仓库工作区就存在一处**未提交**改动把它改成了 `LEBGJM`（`git diff appsettings.Production.json` 可见）。

结论有三条：

- `DefaultSite` 是「运行期没指定据点时的兜底值」，**不是**据点↔库的映射，也不是「现在查的是哪个库」。
- 正式环境的据点↔库对应关系**因此没有应用配置佐证**，只有工具 ini。这就是 `prod.lebgjm` 停在 `needs-review` 的原因。
- 生产默认据点 `BPBG` 的库 `wms_bpbg` 只在**被注释的**配置里出现过（见下），所以「按默认据点查生产」这条路当前**无可用路由**。

## `WMS_ReadOnly` 这个 ConfigId 没有独立语义

三套 appsettings 里都有 `WMS_ReadOnly`，但状态与目标各不相同（均为提交版本）：

| 环境 | 是否启用 | 指向 | 与该环境主库的关系 |
|---|---|---|---|
| dev（`:22-33`） | 启用 | 10.10.80.211/`wms_lebg` | **同主机同库**——根本不是副本 |
| stag（`:24`） | 启用 | 10.10.76.166/`wms_lebgjs` | 同名库但**不同主机**（主库在 .108） |
| prod（`:18-29`） | **整段被注释** | 10.10.76.166/`wms_bpbg` | 库名与主库不同 |

并且 `DBTenant.ReadOnlyWMS`（`DBTenant.cs:36`）在 C# 代码中**零引用**。

因此：**不得**用「`WMS_ReadOnly` 指向哪里」推断只读库在哪里。它在开发环境指向主库本身、在正式环境被注释掉，说明这个 ConfigId 没有独立语义。10.10.76.166 是一台**独立服务器**（承载了多个同名/异名库的「只读」配置），在定位明确之前不为它单独建路由（见 `routes.json` 的 `nonRoutes`）。

## 没有从库（`replica` 是架构上不存在的能力）

- `DBTenant.ReadOnlyWMS` 零代码引用。
- **全部** `appsettings*.json` 里的 `SlaveConnectionConfigs` 都是 `[]`（实测 172 处，非空 0 处）——没有任何读写分离配置。

所以 `replica` 标记为 `unsupported`，**不是** `disabled`：`disabled` 会暗示「配上就能用」，而这里配了也不存在。

## BI 有两套完全不同的口径

| 口径 | 形态 | 本技能的处理 |
|---|---|---|
| 静态 `DBTenant.BI` / `ConfigId=BI` | Oracle（`Data Source=10.10.77.20:1521/ORCL`），正式环境提交版本里被注释 | `unsupported`（无 Oracle 执行器），路由保留只为让状态可见 |
| 运行期报表库 | 连接串从 `sys_site` 表按据点取 AES 密文解密，`ConfigId` 形如 `Report:{site}:{version}`，`DbType` **硬编码 MySql**（`ReportDbScopeProvider.cs:39-92`） | 不纳入路由：技能不解密该密文 |

**不要把两者当同一个东西。** 运行期报表库既不是静态 BI，也不在 appsettings 里，而且它是 MySQL 不是 Oracle。

## 路由 id 命名

一律 `环境.据点码`（据点无关的库用 `环境.租户`，如 `prod.shared`、`prod.logs`、`prod.warehouse`）。

- 精确匹配，**无前缀/近似/最接近匹配**（见 `Get-DbOpsRoute` 的注释）。
- `-Environment` 只是 `-Target` 的别名，不是第二个维度。
- **不存在** `dev`、`replica`、`bi`、`logs`、`warehouse` 这类裸路由名——它们要么被拆成 `环境.xxx`，要么是 `nonRoutes` 里的说明条目。

## 当前状态与升级条件

**阶段 1 的预期结果：可能没有任何一条 `prod.*` 达到 `ready`。** 这**不是**技能故障——`ready` 需要「配置齐备 + 一个具备只读权限的独立账号」，而仓库里所有 `appsettings` 连接串（**含被命名为 `WMS_ReadOnly` 的那条**）的用户都是 `root`，会被 `highPrivilegeUserPattern` 判 `blocked`。

| 路由 | 库 | 静态 status | 要升级为 ready 缺什么 |
|---|---|---|---|
| `dev.lebgjm` / `dev.warehouse` / `dev.shared` / `dev.logs` | dev 各库 | `ready`（配置层） | 补合规只读账号（当前全是 root → `blocked`） |
| `stag.lebgjs` / `stag.shared` | `wms_lebgjs` / `wms_lebg_shared` | `ready`（配置层） | 同上 |
| `prod.shared` / `prod.logs` / `prod.warehouse` | `wms_shared` / `wms_log` / `wms_lebgjm_automation_warehouse` | `ready`（配置层） | 同上。`prod.logs` 是仓库里**唯一**已用非 root 账号（`wms_log`）的连接，最有可能先达到可用 |
| `prod.lebgjm` | `wms_lebg`@10.10.76.167 | `needs-review` | 人工确认据点 LEBGJM 与 `wms_lebg` 的对应（提交版本 `DefaultSite=BPBG`，无佐证） |
| `prod.bpbg` | `wms_bpbg`@10.10.76.166 | `needs-review` | 人工确认 BPBG 是否在用、`wms_bpbg` 是否真实存在（配置里该段**被注释**） |
| `prod.lebg` / `prod.lebgsz` / `prod.lebgty` / `prod.lebgch` / `prod.labg` / `prod.lebgjs` | `wms_lebgty` 等 | `needs-review` | 只有工具 ini 证据，且无 host/port：需人工提供目标与库名对应 |
| `dev.bi` / `prod.bi` | Oracle | `unsupported` | 本技能不提供 Oracle 执行器 |
| `replica`（`nonRoutes`） | — | `unsupported` | 架构上不存在，不是配置问题 |

`prod.lebg` 这一行的 ⚠ 务必转述给使用者：**据点 `LEBG` 指向 `wms_lebgty`**，与直觉相反。
