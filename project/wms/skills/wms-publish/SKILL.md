---
name: wms-publish
description: "WMS 发布编排技能（配置驱动重构版）。把 .NET 后端、AdminUI 前端、PDA Web（H5）、PDA APK 四类产物按 JSON 配置构建、归档、落盘。仅在需要执行 WMS 发布、打包、出包、预检发布计划时触发；触发关键词：WMS发布、出包、打版本、Web发布、前端打包、后端发布、PDA打包、PDA web、H5、publish、release、/wms-publish"
shell: powershell
version: 1.0.0
---

<!-- task-log: disabled -->
<!-- task-log-paths: IMTC.WMS.AdminWebApi/**/bin/**/publish/**; IMTC.WMS.AdminUI/dist/** -->
<!-- PDA APK 构建另会改动 IMTC.WMS.PDA/manifest.json 与 release/simpleDemo/build.gradle，这两个文件由 .ai/project/skills/wms-pda-release/SKILL.md 的 task-log-paths 按路径覆盖，与本技能是否驱动无关。 -->
<!-- PDA Web（H5）构建不触碰任何 git 跟踪文件（HBuilderX 产物落在 .gitignore 覆盖的 unpackage/* 与 release/output 之下），因此它不需要 task-log-paths 豁免，也不会让工作区变脏。与 APK 构建相反，别把两者混为一谈。 -->

# WMS Publish（配置驱动）

## 这个技能的设计前提

**日常维护发布流程时，只改 JSON，不改 PowerShell。**

- 版本号规则、输出目录、归档命名、工具路径、要构建哪些项目、构建参数，全部在 `config/` 下的 JSON 里。
- 脚本只读配置、做判断、派生进程。脚本里不应该出现任何项目名、输出路径或构建参数的字面量。
- 因此：**用户提出新的发布需求时，先问「这是配置能表达的，还是需要改脚本」**。绝大多数情况——加一个项目、换输出目录、改归档名、改版本号——都是改 JSON。

## 目录结构

```
config/release.json          版本、目标环境、归档命名、打包、日志、安全门禁
config/projects/dotnet.json  .NET 后端：项目根、configuration/framework/runtime、项目清单
config/projects/web.json     前端：项目根、buildCommand、mode
config/projects/pdaweb.json  PDA Web（H5）：HBuilderX CLI、manifest、config.js
config/projects/pda.json     PDA APK：委托 release/scripts/build-apk.ps1
scripts/publish.ps1          编排层：算版本与选择、算 digest、按序派生生产者、调 package.ps1
scripts/invoke-publish.ps1   同一进程内串起预检+执行，并用不继承句柄的方式捕获输出
scripts/publish-<kind>.ps1   四个生产者：只负责把源码变成 outputDir 里的东西
scripts/package.ps1          唯一的落盘者：归档、命名、重复发布、搬进版本目录
scripts/lib/                 common（路径/配置断言/版本/命名）、log（JSONL 事件）、exec（唯一的进程捕获）
rules/publish.rules.md       强约束：门禁、命名、版本语义、安全边界
```

## 入口

优先用 `invoke-publish.ps1`：它在**同一个进程内**先预检再执行（消除 digest 漂移窗口），并且用不继承句柄的方式捕获子进程输出。

```powershell
$sk = "$env:USERPROFILE\.claude\skills\wms-publish\scripts"

# 1) 预检（完全只读，不写任何文件、不跑任何构建）——先给用户看，让用户确认
powershell -NoProfile -File "$sk\invoke-publish.ps1" -Mode Preflight -Target test -Only admin,frontend

# 2) 用户确认后执行。把上一步的 PlanDigest 传回来，digest 不一致会自动中止（exit 4）
powershell -NoProfile -File "$sk\invoke-publish.ps1" -Mode Publish -Target test -Only admin,frontend -ConfirmPublish -ExpectedDigest '<预检的 PlanDigest>'
```

`-Only` / `-Kind` 只能写成**逗号分隔的一个 token**（`-Only admin,frontend`）：`powershell -File` 不解析逗号，用空格写成多个参数会被绑到别的参数上。

只读地看计划时可以直接调 `publish.ps1`（同样的参数，`-Mode Preflight`）；真实执行请走 `invoke-publish.ps1`。

- 退出码：`0` 成功；`2` 预检被阻塞；`3` 缺少 `-ConfirmPublish`；`4` digest 漂移；`1` 硬失败。
- `-Json` 输出单个信封对象（`Mode`/`Target`/`PlanDigest`/`BatchStamp`/`Preflight`/`Publish`/`ExitCode`）。
- **禁止用管道读 `publish.ps1` 的输出**（`2>&1 | Out-String`、`| Select-String` 一律不行）：PDA 构建派生的 Gradle 守护进程会继承管道写端，发布**成功之后**读端仍永远等不到 EOF（2026-09-23 实测挂死 24 分钟）。要么走 `invoke-publish.ps1`，要么把输出重定向到文件。

## 选择发布内容

先与用户确认这次发哪些项，再据此传 `-Only`。

| `-Only` 取值 | 类别 | 内容 |
|---|---|---|
| `admin` | dotnet | Admin.WebApi |
| `report` | dotnet | Admin.WebApi.Report |
| `automation` | dotnet | AutomationWarehouse.WebApi |
| `ai` | dotnet | Admin.WebApi.AI |
| `frontend` | web | AdminUI 前端（`pnpm build`） |
| `pdaweb` | pdaweb | PDA Web（H5）站点（HBuilderX `publish web`，约 4 分钟） |
| `pda` | pda | PDA 离线 APK（委托 `build-apk.ps1`，产出原始 APK） |

- 多个值用逗号分隔：`-Only admin,report,ai,frontend`。不传 `-Only` 时用 `-Kind` 选类别，仍不传则取 `release.json` 的 `defaultKinds`（当前是 `dotnet` + `web`）。
- **`pdaweb` 与 `pda` 都不在 `defaultKinds` 里**，这是有意的：裸跑不应触发约 4 分钟的 HBuilderX 构建或 APK 构建。
- 选择结果进入 `PlanDigest`，改了选择必须重新预检。未知取值在预检阶段直接报错并列出可选值。

## 版本号

| 场景 | 参数 | 行为 |
|---|---|---|
| 同版本重发（默认） | 无 | **复用**当前最大版本号，产物在同一个版本目录里重写 |
| 正常递增 | `-BumpVersion` | 最大版本号末段 +1（超过 9 归零并向左进位） |
| 指定版本 | `-Version v1.4.1.20` | 就用这个号 |
| 同版本修复重发 | `-VersionSuffix _fix` | 只给版本标签加后缀，**版本号本身不变**，不影响下一次续号 |

- 版本真值取 `version.scanRoots` 与两个环境的输出根下**版本目录名**的最大值（`v` + 四段数字）。**判据是目录名，不看任何状态文件**。
- `version.scanRoots` 里的历史根（桌面 `dev`、`publish`）是**必须保留的**：新结构把产物放在 `publish/<环境>/` 之下，只扫新结构会让版本号倒退到 `initialVersion`。
- 测试线与生产线**共用一条版本线**，所以两边的输出根都要扫。
- **不允许因为「同版本文件已存在」就自动递增版本号。** 正常递增与指定同版本重发是两件事，版本号只由上表决定。

## 落盘与重复发布

- 输出根按环境隔离：`test` → `{desktop}/publish/test`，`production` → `{desktop}/publish/production`。两个环境各自独立判断重复发布，互不影响。
- 落盘结构：`<输出根>/<版本标签>/<发布包>`——版本目录下**平铺**最终交付物，不再建 `<项目 id>/` 子目录。运行状态：`<输出根>/_logs/<runId>/`。
- **一个项目 = 一个最终发布包，包内不带目录层**。`archiveNaming.prefixes` 是 **项目 id → 包名前缀**（按项目配，不按 kind），包名模板 `{prefix}_{version}{duplicate}.zip`，于是每个项目都拿到各不相同的名字：

  | `-Only` | 包名 |
  |---|---|
  | `admin` | `publish_v1.4.1.14.zip` |
  | `report` | `publish_report_v1.4.1.14.zip` |
  | `automation` | `publish_automation_v1.4.1.14.zip` |
  | `ai` | `publish_ai_v1.4.1.14.zip` |
  | `frontend` | `web_v1.4.1.14.zip` |
  | `pdaweb` | `pda_v1.4.1.14.zip` |

- **包内是该项目 `outputDir` 的内容本身**（`Admin.WebApi.dll`、`appsettings.json`、`index.html` 直接躺在包根），**不带 `<项目 id>/` 目录层**：归档直接以该项目的 `outputDir` 为源目录，解压即得到可部署的目录内容，不需要先剥一层。版本目录同理**平铺**，不建 `<项目 id>/` 子目录。
- **每个项目的前缀必须唯一**：配重了会让两个项目写到同一个包名上互相覆盖，预检与 `package.ps1` 都会在动手之前直接报错。
- `targets.<环境>.duplicateMode`：
  - `suffix`（默认）：同版本包已存在时给文件名加 `_yyyyMMddHH` 批次时间戳；同一小时内再次重发会**覆盖那个文件**，不产生 `_1`/`_2`。同一次发布里所有包共用**同一个**批次时间戳。suffix 作用于**最终包**（`publish_v1.4.1.14_2026092317.zip`）。
  - `overwrite`：直接覆盖同版本包。
- **重发只影响被发的项目**：每个项目只覆盖**它自己**的目标名，同版本目录里别的项目的包与 APK 不受影响。（聚合模型时期相反：那时重发任一成员都会整体重建该族的包。）
- **PDA APK 不参与这套命名、聚合与重复发布规则**：它的文件名由 `build-apk.ps1` 自带时间戳决定（同版本号会重复出现，去掉时间戳会让内容不同的两个包互相覆盖），`package.ps1` 只把它原样复制进版本目录，不并入任何 zip。

## 流程

1. 先与用户确认本次要发哪些项，据此决定 `-Only` / `-Kind`。
2. 跑 `Preflight`，把**计划、将被删除/覆盖的原产物、警告、阻塞原因**展示给用户；预检不写任何文件、不执行任何构建。
3. 用户确认后跑 `-Mode Publish -ConfirmPublish -ExpectedDigest <预检 digest>`。
4. 编排层按 `kindOrder` **串行**派生生产者：`dotnet` → `web` → `pdaweb` → `pda`。**顺序不是小事**：pdaweb 必须排在任何 APK 构建之前，因为 H5 包会把 `manifest.json` 的 `versionName` 编进 `__uniConfig.appVersion`，而 APK 构建第一步就自增 manifest。改 `kindOrder` 前先把这件事想清楚。
5. 全部生产者成功后，`package.ps1` 逐个项目归档：直接以该项目的 `outputDir` 为源目录压到暂存（包内因此不带目录层），通过完整性测试与清单比对，再搬进版本目录。
6. 全过程写入 `<输出根>/_logs/<runId>/` 下的 `publish.jsonl`、`publish.status.json`、各阶段的 `*.result.json`，以及本次 run 的 `manifest.json`。**`manifest.json` 每个 run 一份**，其 `artifacts` 只描述最终交付物（各项目的发布包 + APK），不列生产者中间产物。

## 安全边界

- 预检**只读**：不执行构建/发布/压缩/删除/版本递增，不派生任何构建工具，不在输出根留下任何文件（含日志）。读取 `manifest.json`、`config.js`、`version.txt` 属只读展示，允许。**工具链版本不做探测**——探测需要执行 `cli.exe`，违反本行；`hbuilderxCli` 在预检中只做 `Test-Path`。
- 真实执行必须同时提供 `-Mode Publish` 与 `-ConfirmPublish`，并校验 `PlanDigest` 未变化。
- 分支白名单（`main` / `production` / `stag`）与脏工作区门禁按 `release.json` 的 `safety.allowDirty`/`targets.<环境>.requireCleanWorktree` 执行；越界需 `-ConfirmBranch` / `-AllowDirty`。**不自动 stash、reset、切分支、commit 或 push。**
- 输出根必须落在仓库之外（默认在桌面），且必须是展开 token 后的绝对路径。
- 归档一律走 Bandizip CLI，不存在时停止，**禁止静默退回 `Compress-Archive` / 7z / Python zipfile**。该门禁只在本次确实要产出归档时生效（纯 PDA APK 发布不需要 Bandizip）。
- 原生命令写到 stderr 的内容只记日志，成败一律以**退出码**判定；退出码缺失时判为失败。禁止让 stderr 输出中止发布。
- 详细强约束见 `rules/publish.rules.md`。

## 已知坑

- **`$PSScriptRoot` 在 `param` 块里是空的**（有 `[CmdletBinding()]` 时参数绑定早于它赋值），所以默认值必须留空、在脚本体内解析。旧技能 `wms-publish` 的两个脚本都有这个问题：不传 `-Config` 会报「配置不存在：`\..\config\...`」。
- **跨函数返回空数组会被解包成 `$null`**：`Split-List` 无输入时返回空数组，调用方必须写 `@(Split-List $x)`，否则 `$x.Count` 在 `Set-StrictMode 2.0` 下抛「属性 'Count' 不存在」。
- **`.ps1` 必须存成 UTF-8 带 BOM**：Windows PowerShell 5.1 把无 BOM 的 `.ps1` 当 ANSI 读，中文注释会变成乱码并连带把字符串终止符吃掉，报出一堆看似语法错误的东西。新建脚本后务必确认有 BOM。
- 报告对象里**不要**直接放 `Get-Content` 的返回值：它带 `PSPath`/`PSDrive`/`PSProvider` 装饰属性，末尾的 `ConvertTo-Json` 会连带遍历整个 provider 对象图，输出按深度指数膨胀（实测 depth=6 已 23MB，depth=12 吃满数 GB 并卡死）。读文件内容一律用 `[IO.File]::ReadAllLines` / `ReadAllText`。
- **管道读输出会挂死**（见上文入口一节的禁止项）。修复点在**派生方式**：`UseShellExecute=$true` 走 ShellExecuteEx（`bInheritHandles=FALSE`），整棵子进程树从根上就拿不到调用方句柄。清自己标准句柄的 `HANDLE_FLAG_INHERIT` **无效**（实测标志已由 1 变 0，管道用例照样挂死）。
- **PowerShell 变量名大小写不敏感**：脚本参数 `[string]$ResultFile` 与局部循环变量 `$resultFile` 是**同一个变量**。旧实现里 `foreach ($resultFile in @($ItemResults))` 循环结束后把参数值改成了最后一个生产者结果文件的路径，于是 `package.ps1` 把自己的 payload 写进了别人的结果文件、`package.result.json` 从未生成——发布实际成功却报成假失败，还静默污染了一个真实结果文件（2026-09-23 实测）。给局部变量取名前先看它是否与任何参数同形（现名 `$resultFilePath`）。**同类第二次**（同日）：`package.ps1` 规划块的 `$target = Join-Path $versionDir $resolved.Name` 覆盖了环境参数 `[string]$Target`，发布全程零报错，只有 `manifest.json` 与 payload 的 `target` 字段被写成**最后一个发布包的路径**而不是 `test`/`production`（现名 `$targetPath`，与 `publish.ps1` 一致）。这类缺陷不抛错、只在末端产物里显现，排查时先看产物字段再看逻辑。自查手段：把「脚本级 param 名 + 各函数 param 名」与「脚本体内所有 `$同名 = ...`、`foreach ($同名 in ...)`」对撞（函数体内的同名局部变量只影响该函数自身作用域，不影响脚本级参数——两者要分开判）。
- PDA 产物按 `CreationTime` 定位，**不按 `LastWriteTime`**：新 APK 与上一轮 sha256 完全相同、`LastWriteTime` 停在上一轮构建时刻，都是正常结果。
- **PDA APK 工具链版本配对未经验证**：参考文档记录的配对是 `Android-SDK@5.24.82669_20260813` ↔ HBuilderX `5.24.2026081301`，本机 HBuilderX CLI 自报 `5.07`。预检每次打这条警告，**只提示不阻塞**；打包成功 ≠ 运行时兼容，建议装真机冒烟（扫码头、蓝牙、是否白屏）。该警告**只针对 APK**，不要套到 PDA Web 上。
- **PDA Web 部署前提（本技能只归档，不部署也不验证）**：产物 `router.mode` 是 `history` 且 `h5.router.base` 为空，必须部署在 web 服务器**根路径**并配置 history 回退，否则刷新与深链会 404。包内 `appVersion` 是 PDA `manifest.json` 的号，与产物名的 Web 版本号**本来就不相等**，不要据此判断发布出错。
- PDA 相关运行请带 `-Json`：Gradle 与 HBuilderX 输出冗长，不带时子进程输出会混进 stdout。

## 路由

| 目标 | 入口 |
|---|---|
| 预检 + 执行（推荐） | `scripts/invoke-publish.ps1` |
| 只读地看发布计划 | `scripts/publish.ps1 -Mode Preflight` |
| 单类产物的构建细节 | `scripts/publish-<kind>.ps1` |
| 归档、命名、重复发布、落盘 | `scripts/package.ps1` |
| 强约束（门禁、命名、版本语义） | `rules/publish.rules.md` |
| 配置字段 | `config/release.json`、`config/projects/*.json` |
| PDA APK 打包细节 | 项目 `wms-pda-release` + `IMTC.WMS.PDA/release/scripts/build-apk.ps1`（**仅委托**，不复制其逻辑） |

## 未匹配命令

若用户意图不是 WMS 发布编排，使用通用知识处理，不加载本技能的发布脚本。
