# WMS Publish 强约束

本文件是 `wms-publish` 的**约束层**：这里写的都是「不得违反」，不是「建议这样做」。
操作流程、参数用法、入口选择写在 `SKILL.md`；本文件只回答「什么绝对不能做」。

违反任一条即视为发布失败，必须停止并修配置或修脚本，**不得绕过**。

---

## R1. 配置是唯一意图源

- `config/release.json` 与 `config/projects/*.json` 是发布行为的**唯一**人类可改来源。
- 脚本里**不得**出现项目名、输出目录、构建参数、归档名模板、工具路径的字面量。新增一个项目、换一个输出目录、改一个归档名，都必须只改 JSON。
- **判断顺序固定**：收到新的发布需求时，先问「这是配置能表达的吗」。只有配置表达不了的（新类别、新校验、新平台）才动脚本。
- 脚本不得写入任何配置文件。发布过程对 `config/` 只读。
- 配置字段名一旦对外发布即视为契约：改名等同于破坏性变更，必须同时改所有生产者与 `Assert-NoUnknownFields` 的字段表。

## R2. 预检必须只读

`-Mode Preflight` 必须满足全部条件：

- **不执行**构建、发布、压缩、删除、版本递增。
- **不派生**任何构建工具（`dotnet`、`pnpm`、`cli.exe`、`gradlew`、`bz.exe` 一律不启动）。工具存在性只能用 `Test-Path` 判断，**不得执行工具去探测版本**。
- **不在**输出根留下任何文件或目录，**包括日志**。预检的运行日志只进内存与 stdout。
- 允许的只读动作：读配置、读 git 状态、扫版本目录、读 `manifest.json` / `config.js` / `version.txt` 用于展示。
- 预检报出的 `Plan` 必须是**即将真实发生**的那一份，不得为了让预检好看而省略破坏性动作。

## R3. 执行必须显式确认

- 真实执行必须同时给出 `-Mode Publish` **与** `-ConfirmPublish`；缺 `-ConfirmPublish` 时以退出码 `3` 终止。
- `-PlanDigest` 与本次重算结果不一致时以退出码 `4` 终止，**不得**「以本次为准继续跑」。
- `PlanDigest` 必须**不含** `Mode`（预检与执行是两次调用，含它则两者永远算不出同一个值）。
- `PlanDigest` 必须**不含**批次时间戳（墙上时钟；含它会让跨整点的预检无端漂移）。批次时间戳改由调用方从预检结果显式透传给执行阶段。
- 破坏性动作（删除/覆盖既有产物）必须**进入**计划与报告，并在确认摘要中单独展示。用户确认的是「会覆盖什么」，不是一个笼统的计划。

## R4. 版本号语义

- 版本号 `vX.X.X.X` 的**唯一**真值来源是 `version.scanRoots` 与各环境输出根下的**版本目录名**取最大值。**不得**读任何状态文件作为真值：运行状态文件（`_logs/<runId>/manifest.json`，旧实现叫 `version-state.json`）记录的是「本次 run 落了什么」，不是「发到哪个号了」，拿它当判据会让版本号跟着运行目录漂移。
- `v` 四段数字以外的目录名（如 `v1.4.1.13_fix`）**不是**版本候选。版本正则必须保持锚定（`^v(\d+)\.(\d+)\.(\d+)\.(\d+)$`）。
- **绝不允许**因为「同版本产物已存在」就自动把版本号递增到下一个版本。同版本重新发布与正常版本递增是两种场景：前者靠 `duplicateMode` 处理，后者只能由 `-BumpVersion` 触发。
- 测试线与生产线**共用一条版本线**。任何「只扫当前环境」的优化都会让另一个环境发过的号被重发，属于禁止项。
- `version.scanRoots` 中的历史根必须保留：删掉它们会让版本号倒退到 `initialVersion`。
- `-VersionSuffix` 只影响**版本标签**（目录名与归档名里的后缀），**不影响**版本号本身，也不影响下一次续号。

## R5. 归档命名

- 归档名只由 `archiveNaming.pattern` 决定，默认 `{prefix}_{version}{duplicate}.zip`。
- `archiveNaming.prefixes` 是 **项目 id → 包名前缀**，**按项目配，不按 kind**：
  `admin`→`publish`、`report`→`publish_report`、`automation`→`publish_automation`、`ai`→`publish_ai`、`frontend`→`web`、`pdaweb`→`pda`。于是同一版本产出 `publish_v1.4.1.14.zip`、`publish_report_v1.4.1.14.zip`、`publish_automation_v1.4.1.14.zip`、`publish_ai_v1.4.1.14.zip`、`web_v1.4.1.14.zip`、`pda_v1.4.1.14.zip`。
- **一个项目 = 一个最终发布包**，同一次发布里各后端/前端项目各自一个不同名的包是**预期行为**，不是冲突。
- **每个项目的前缀必须唯一**：前缀重复会让两个项目写到同一个包名上互相覆盖。预检与 `package.ps1` 都在动手之前拒绝，**不得**以「反正不会同时发」为由绕过。
- **包内不得带 `<项目 id>/` 目录层**：归档直接以该项目的 `outputDir` 为源目录，条目就是该目录的相对路径，解压即得到可运行目录的内容。版本目录同理，**平铺**最终交付物，不得建 `<项目 id>/` 平级子目录。
- 前缀**按项目 id 查表**（不是按 kind、也不是按项目名拼）。项目 id 是配置里的 `projects[].id`，与 `-Only` 取值同名。
- `{version}` 是版本标签（`v` + 四段数字 + 可选后缀）；`_{yyyyMMddHH}` 是重复发布记录后缀，**不属于版本号**，不得参与任何版本比较。
- 同一次发布中所有归档**必须共用同一个**批次时间戳。禁止逐包取当前时间。
- 归档一律走 `packaging.executable` 指定的 Bandizip CLI。工具不存在时**停止**。**禁止**静默退回 `Compress-Archive`、`7z`、`Python zipfile` 或任何其他压缩实现。
- 该工具门禁只在「本次确实要产出归档」时生效：纯 PDA APK 发布不产出归档，不得因此被阻塞。

## R6. 重复发布

- `duplicateMode` 由 `targets.<环境>.duplicateMode` 决定，默认 `suffix`。
  - `suffix`：目标名已被占用时，文件名追加 `_<批次时间戳>`。同一小时内重复发布**覆盖同一个后缀文件**，**禁止**产生 `_1`、`_2` 之类的递增序号。
  - `overwrite`：直接覆盖同版本产物。
- 两个环境**各自独立**判断重复：`test` 与 `production` 的输出根互不可见，任一侧的产物存在与否不得影响另一侧。
- **累积不做清理**：`suffix` 模式长期累积历史包是已接受的现状，不得自行加入清理/保留策略。
- **PDA APK 不适用**本节的命名与重复规则：其文件名由 `build-apk.ps1` 自带时间戳决定，`package.ps1` 只原样复制。不得为了「统一」而去掉 APK 的时间戳——同版本号 APK 会重复出现，去掉后内容不同的两个包会互相覆盖。

## R7. 生产者与编排层的边界

- 生产者（`publish-dotnet.ps1` / `publish-web.ps1` / `publish-pdaweb.ps1` / `publish-pda.ps1`）只负责「把源码变成 `outputDir` 里的东西」。**不得**归档、命名、搬进版本目录、决定重复发布——那些是 `package.ps1` 的独占职责。
- 生产者**不得**写入暂存目录或版本目录。
- `package.ps1` 是唯一落盘者。它必须先归档到暂存、通过完整性校验与清单比对，再搬进版本目录。
- **每个项目的落盘是独立的**：一个项目的包只覆盖**它自己**的目标名，同版本目录里别的项目的包与 APK 不受影响。重发一个项目不会重建别人的包。
- **归档源目录必须是项目自己的 `outputDir`**，**不得**先把产物复制进一个中转目录再压缩：Bandizip 的归档条目随源目录而定，中转目录名会变成包内顶层目录层，产出一个需要先剥目录才能部署的包。聚合模型时期那层复制是正确性要求（多个源目录的 basename 都是 `publish`，会塌进同一个顶层目录互相覆盖）；逐项目模型下一个包只有一个源目录，复制只剩副作用（2026-09-23 实测）。
- **不得**清空版本目录；**不得**写版本目录与运行日志目录以外的任何位置。
- 版本目录只放**最终交付物**（各项目的发布包 + APK）。运行状态、日志、digest、`manifest.json`、各生产者与打包脚本的 `*.result.json` 一律属于 run state，落在 `_logs/<runId>/` 下，**不得**放进版本目录。
- 每次 run 的 manifest 是 `<输出根>/<logs.dirName>/<runId>/<logs.manifestFile>`（默认 `manifest.json`），**每个 run 独立一份**：重复发布（`suffix` 累积多个包）时不得互相覆盖，也不得把多个批次的信息混进同一个文件。
- manifest 的 `artifacts` **只描述最终交付物**（各项目的发布包 + APK），**不得**描述生产者的中间产物。
- 编排层（`publish.ps1`）**不得**重复生产者对自身配置的字段校验。生产者是自己配置结构的权威，且在动手之前就断言；编排层再抄一份只会两边漂移，换不来额外安全。
- 生产者之间**不得**互相调用，**不得**共享可变的中间状态，只通过 `-ResultFile` 的 JSON 上报结果。
- 编排层**不得**复制、镜像或改写 PDA 的打包逻辑，只准委托 `release/scripts/build-apk.ps1`。

## R8. 执行顺序

- `kindOrder` 的顺序是**语义约束**，不是排序偏好：`pdaweb` **必须**排在任何 `pda`（APK）构建之前。H5 包会把 `manifest.json` 的 `versionName` 编进 `__uniConfig.appVersion`，而 APK 构建第一步就自增 `manifest.json`。
- 生产者**串行**执行。同一次发布内并发构建会让上面的顺序约束失效，也会让版本目录的落盘互相竞争。
- 任一生产者失败即**立即终止**整个发布，不得继续后续生产者，不得落盘半成品。

## R9. 产物校验

- 归档完成后必须通过完整性测试（可被标准 zip 读取、条目数 > 0）与**清单比对**（实际条目集合与构建清单一致），不通过即失败，不得搬运。
- PDA APK 必须验证：非空、含 `AndroidManifest.xml` 与 `classes.dex`。
- PDA 产物定位必须**恰好命中一个**候选，四条件同时满足：匹配 `expectedOutput`、文件名含 `_v<版本>_`、构建前快照中不存在、`CreationTime` 在构建窗口内。命中数 ≠ 1 时**抛错**。
- **禁止**用 `Select-Object -First 1` 之类的兜底把多候选变成单候选：那会把「配置或构建脚本坏了」静默降级成「发布了一个不知哪来的包」。
- PDA 候选判定**只看 `CreationTime`，不得叠加 `LastWriteTime`**：Gradle 在输入未变时判定 up-to-date 不重写 APK，新包与上一轮 sha256 可能完全相同、`LastWriteTime` 停留在上一轮构建时刻。
- 陈旧导出防护必须保留：PDA 与 H5 都必须校验导出目录的新鲜度（产物时间晚于构建开始）。版本号比对**拦不住**陈旧复用——源 `manifest.json` 被回退过时，陈旧复用与真导出产出的 `version.txt` 可以完全相同。
- H5 产物必须包含 `requiredEntries`（默认 `index.html`）以及至少一个 `.js`、一个 `.css`。

## R10. 进程与输出

- **禁止用管道读取 `publish.ps1` 的输出**（`2>&1 | Out-String`、`| Select-String` 一律不行）。PDA 构建派生的 Gradle 守护进程会继承管道写端，发布**成功之后**读端仍永远等不到 EOF（2026-09-23 实测挂死 24 分钟）。
- 需要捕获输出时，只能走 `invoke-publish.ps1`（它在同一进程内串起预检与执行，并用 `UseShellExecute=$true` 派生），或把输出重定向到文件。
- 修复点只能在**派生方式**：必须是 `UseShellExecute=$true`（ShellExecuteEx，`bInheritHandles=FALSE`），让整棵子进程树从根上拿不到调用方句柄。**清理自己标准句柄上的 `HANDLE_FLAG_INHERIT` 无效**（实测标志已由 1 变 0，管道用例照样挂死）。`lib/exec.ps1` 的 `Invoke-CapturedProcess` 用 `UseShellExecute=$false`，**不得**拿它替代安全捕获。
- 原生命令写到 stderr 的内容**只记日志**：成败一律以**退出码**判定；退出码缺失时判为**失败**，不得默认成功，更不得让 stderr 输出中止发布。
- 所有内部进程调用必须传 `-NoProfile`（与 `-ExecutionPolicy Bypass`），不继承宿主 profile。
- 全程不写「每 N 秒进度」之类的轮询输出；日志用 JSONL 事件，供事后排障而非刷屏。

## R11. 安全门禁

- 分支白名单与脏工作区门禁按 `release.json` 的 `safety.allowedBranches`、`safety.allowDirty`、`targets.<环境>.requireCleanWorktree` 执行。越界需显式 `-ConfirmBranch` / `-AllowDirty`。
- **不得**自动 stash、reset、checkout、revert、commit 或 push。不得为了「让工作区干净」而丢弃任何人的改动。
- 输出根必须是**展开 token 后的绝对路径**，且**必须落在仓库之外**（默认在桌面）。写在仓库内的输出根会让后续构建把产物当源码。
- 路径必须做越界校验：会写入的路径（`outputDir`、`versionMarker`、`manifestPath` 等）必须落在对应项目根**之内**。一个写错的配置不得让构建脚本去改写仓库外的东西。
- 传给 `cmd.exe` 的路径必须通过可引用性校验（不得含 `& | < > ^ % " !`）。该校验必须在**构建之前**完成。
- 项目 id 用作路径段，必须是安全段（不得含路径分隔符、`..`、盘符）。
- 本技能**不部署、不重启服务、不碰数据库**。只产出发布包。
- 本技能**不写**用户级配置，不改动与本技能无关的任何文件。

## R12. 脚本工程约束

- 目标运行时是 **Windows PowerShell 5.1**。不得使用 7.x 独有的语法（`??`、`?.`、三元、`-Parallel`）。
- 所有脚本必须存为 **UTF-8 带 BOM**：PS 5.1 把无 BOM 的 `.ps1` 当 ANSI 读，中文注释会乱码并吞掉字符串终止符，报出一堆伪语法错误。JSON 结果文件反过来必须**无 BOM**。
- 脚本内不得出现中文字符串以外的非 ASCII 装饰字符；错误信息必须直接给出路径或配置项名，便于定位。
- 顶层 `catch` 必须带**位置信息**（`$_.InvocationInfo.ScriptLineNumber`）：脚本规模已大，只报「属性不存在」而不给出处，排障只能靠猜。
- 报告对象里**不得**直接放 `Get-Content` 的返回值：它带 `PSPath`/`PSDrive`/`PSProvider` 装饰属性，末尾 `ConvertTo-Json` 会遍历整个 provider 对象图，输出按深度指数膨胀。读文件内容一律用 `[IO.File]::ReadAllLines` / `ReadAllText`。
- `param` 块里**不得**引用 `$PSScriptRoot`：有 `[CmdletBinding()]` 时参数绑定早于它赋值，默认值会算成 `\..\...`。默认值必须在脚本体内解析。
- 调用 `Split-List` 必须写成 `@(Split-List $x)`：函数返回空数组会被解包成 `$null`，`$x.Count` 在 `Set-StrictMode 2.0` 下抛「属性 'Count' 不存在」。
- 跨进程传递的列表参数写成**逗号分隔的单个字符串 token**：`powershell -File` 不解析逗号，声明成数组只会让整串变成一个元素。
- 所有脚本保持 `Set-StrictMode -Version 2.0` 与 `$ErrorActionPreference = 'Stop'`。不得为图省事放宽。

## R13. 退出码契约

`publish.ps1`：`0` 成功 / `2` 预检被阻塞 / `1` 硬失败。

`invoke-publish.ps1`：`0` 成功 / `2` 预检被阻塞 / `3` 缺少 `-ConfirmPublish` / `4` digest 漂移 / `1` 硬失败（含 `publish.ps1` 内部错误）/ 其余透传 `publish.ps1` 的退出码。

- 退出码一经约定不得改变含义。调用方靠它区分「用法问题、可重试」与「脚本坏了」。
- 硬失败必须同时往 stderr 写 `ERROR: ...` 并以非零码退出；**不得**以退出码 0 结束任何一个失败路径。

## R14. 已知未验证项必须显式标注

- PDA APK 工具链版本配对**未经验证**（参考配对 `Android-SDK@5.24.82669_20260813` ↔ HBuilderX `5.24.2026081301`，本机 CLI 自报 `5.07`）。预检必须**每次**打这条警告，且**只提示不阻塞**。
- 该警告**只针对 APK**，不得套用到 PDA Web。
- 打包成功 ≠ 运行时兼容。报告里不得把「构建成功」表述为「已验证可用」。
- PDA Web 的部署前提（history 路由需部署在根路径并配置回退）必须在报告中保留，不得因为「不是本技能职责」而省略——省略会让人把 404 归因到发布包本身。
