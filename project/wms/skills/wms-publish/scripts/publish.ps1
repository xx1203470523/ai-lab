# publish.ps1 —— 编排层。**只做编排**：解析版本与选择、算 digest、按顺序派生生产者、
# 然后调 package.ps1 落盘。它不构建、不压缩、不知道任何项目的构建参数。
#
# 两段式：Preflight 只读地把「将要发生什么」报给用户并算出 digest；Publish 在核对 digest
# 一致之后才真正执行。用户确认的是 digest，不是「大概那个计划」。
#
# 捕获输出的调用方请走 invoke-publish.ps1：本脚本自身用管道读输出时，PDA 构建留下的
# 常驻 Gradle 守护进程会继承管道的写端，让读端永远等不到 EOF（2026-09-23 实测挂了 24 分钟）。
[CmdletBinding()]
param(
    # 默认值必须留空，在脚本体内再解析：**$PSScriptRoot 在 param 块里是空的**。
    # 原因是有 [CmdletBinding()] 时参数绑定（含默认值求值）发生在 $PSScriptRoot 赋值之前，
    # 实测 "$PSScriptRoot\..\config\release.json" 会得到 "\..\config\release.json"，
    # 于是不传 -Config 的调用一律报「发布配置不存在」。旧技能的两个脚本有同样的问题。
    [string]$Config = '',
    [ValidateSet('Preflight', 'Publish')]
    [string]$Mode = 'Preflight',
    [ValidateSet('test', 'production')]
    [string]$Target = 'production',
    # 指定版本号（如 v1.4.1.15）。给出时既不递增也不复用，就是它。
    [string]$Version,
    # 版本号递增。不传时**复用当前最大版本号**（同版本重发），与旧技能一致：
    # 「正常版本递增」与「指定同版本重新发布」是两件事，后者靠 duplicateMode 表达。
    [switch]$BumpVersion,
    # 版本后缀（如 _fix）：只追加到版本标签，用于同版本号的修复重发。
    # 形如 `_` 加字母/数字/短横线，或留空；不参与版本号解析，因此不影响下一次续号。
    # 模式必须允许空串：ValidatePattern 对「绑定默认值」不校验、对「赋值」校验，而下面
    # `$versionSuffix = ([string]$VersionSuffix).Trim()` 会把空串赋回同名变量（PowerShell
    # 变量名不区分大小写），模式若不允许空串，任何一次调用都会在这里失败。
    [ValidatePattern('^(_[A-Za-z0-9-]+)?$')]
    [string]$VersionSuffix = '',
    # 只发布指定项（项目 id，逗号分隔，如 admin,frontend）。给出时忽略 -Kind。
    [string[]]$Only,
    # 只发布指定类别（逗号分隔，取自 config 的 kindOrder）。不传时用 defaultKinds。
    [string[]]$Kind,
    # 批次时间戳（suffix 模式）。由 invoke-publish.ps1 把内部预检算出的值透传进来，
    # 保证「同一次发布的所有发布包用同一个戳」。留空则本次现算。
    [string]$BatchStamp = '',
    [string]$LogPath,
    [switch]$ConfirmPublish,
    [switch]$ConfirmBranch,
    [switch]$AllowDirty,
    [switch]$AllowStale,
    [string]$PlanDigest,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$RunId = [guid]::NewGuid().ToString('N')
# 预检是只读检查，不得在产物目录留下日志文件；只有真实发布才落盘。
$PersistLog = ($Mode -eq 'Publish')
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\exec.ps1')

# 项目配置按类别分文件，文件名就是 kind。这是本技能唯一的路径约定，
# 不放进 JSON：多一个配置项只会多一处可以写错的地方。
function Get-KindConfigPath([string]$ConfigDir, [string]$Kind) {
    return (Join-Path $ConfigDir ("projects\$Kind.json"))
}

function Get-GitInfo([string]$RepoRoot) {
    Push-Location $RepoRoot
    try {
        $branch = (& git branch --show-current).Trim()
        $status = @(& git status --porcelain)
        # HEAD 提交号进 digest：预检后若有人提交了新代码，工作区依然显示为「干净」，
        # 只有提交号变化能暴露「即将构建的源码不是你确认过的那个提交」。
        $head = (& git rev-parse HEAD).Trim()
        return [pscustomobject]@{ Branch = $branch; Clean = ($status.Count -eq 0); Status = $status; HeadSha = $head }
    } finally { Pop-Location }
}

function Get-VersionCandidates([string[]]$Roots, [string]$Pattern) {
    # 判据是**目录名**，不看 version-state.json 之类的内容文件。
    # 旧技能按 jsonPointers 扫文件内容，结果把 version-state.json 自己也扫成了版本候选；
    # 而且某一侧缺少状态文件时会倒退到 initialVersion。目录名才是版本的真值。
    $found = @()
    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $tuple = Get-VersionTuple $dir.Name $Pattern
            if ($null -ne $tuple) { $found += [pscustomobject]@{ Value = $dir.Name; Tuple = $tuple; Source = $dir.FullName } }
        }
    }
    return $found
}

function Get-MaxVersionTuple($Candidates) {
    $sorted = @($Candidates |
        Sort-Object @{Expression = { $_.Tuple[0] }; Descending = $true },
                    @{Expression = { $_.Tuple[1] }; Descending = $true },
                    @{Expression = { $_.Tuple[2] }; Descending = $true },
                    @{Expression = { $_.Tuple[3] }; Descending = $true })
    if ($sorted.Count -eq 0) { return $null }
    return $sorted[0].Tuple
}

function Get-PdaSourceHash([string]$ManifestPath, [string]$BackendConfigFile) {
    # PDA 与 PDA Web 共用同一份输入：manifest.json（版本号会被编进产物）与 config.js
    # （决定连哪个后端）。两者的哈希都进 digest：预检后改掉其中任何一个，
    # 都会让「即将构建的输入」与用户确认过的那个不一致。
    $parts = @()
    foreach ($path in @($ManifestPath, $BackendConfigFile)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) { $parts += (Get-FileHashValue $path) }
        else { $parts += '' }
    }
    return ($parts -join '|')
}

function Get-PlanItems([string]$RepoRoot, [string]$ConfigDir, [string[]]$Kinds, [string[]]$OnlyIds) {
    # 预检只为「报告」解析路径，用的是与生产者完全相同的 lib 函数与守卫，
    # 因此报告里的路径不可能与真正构建时用的路径不同。
    # 这里**刻意不重复**生产者的「未知字段」断言：配置的形状由各类别自己的生产者负责，
    # 它们在动手之前就会断言；在这里再抄一份字段清单只会多一处会漂移的地方。
    $items = @()
    foreach ($kind in $Kinds) {
        $configPath = Get-KindConfigPath $ConfigDir $kind
        $projectConfig = Read-JsonFile $configPath
        if ($null -eq $projectConfig) { throw "项目配置不存在或不是合法 JSON：$configPath" }
        if ([string]$projectConfig.kind -ne $kind) { throw "$configPath 的 kind 字段应为 $kind，实际为 $($projectConfig.kind)。" }

        $candidates = @($projectConfig.projects)
        if (@($OnlyIds).Count -gt 0) { $candidates = @($candidates | Where-Object { $OnlyIds -contains [string]$_.id }) }

        foreach ($project in $candidates) {
            Assert-RequiredFields $project @('id') "$configPath 的项目条目"
            $id = [string]$project.id
            Assert-SafePathSegment $id "projects/$kind 的项目 id"
            $entry = [ordered]@{
                Id = $id; Kind = $kind; ConfigPath = $configPath
                Destructive = @(); SourceHash = $null; PredictedVersion = $null; BackendConfigFile = $null
            }

            if ($kind -eq 'dotnet') {
                Assert-RequiredFields $project @('project', 'outputDir') "$configPath 的 $id 条目"
                Assert-RequiredFields $projectConfig @('projectRoot', 'configuration', 'framework') 'projects/dotnet.json'
                $projectRoot = Resolve-FullPath ([string]$projectConfig.projectRoot) $RepoRoot
                # outputDir 里的占位符由本类别的顶层字段代入，与 publish-dotnet.ps1 同一套规则。
                $pattern = ([string]$project.outputDir).Replace('{configuration}', [string]$projectConfig.configuration).Replace('{framework}', [string]$projectConfig.framework)
                $outputDir = Resolve-FullPath $pattern $projectRoot
                if (-not (Test-StrictlyWithin $outputDir $projectRoot)) { throw "后端输出目录越界（必须严格位于 $projectRoot 之下）：$outputDir" }
                $entry.Project = Resolve-FullPath ([string]$project.project) $projectRoot
                $entry.OutputDir = $outputDir
                $entry.Runtime = [string](Get-OptionalProperty $projectConfig 'runtime' '')
                $entry.Destructive = @("清空 $outputDir")
            } elseif ($kind -eq 'web') {
                Assert-RequiredFields $project @('projectRoot') "$configPath 的 $id 条目"
                $projectRoot = Resolve-FullPath ([string]$project.projectRoot) $RepoRoot
                $outputDir = Resolve-FullPath ([string](Get-OptionalProperty $project 'outputDir' 'dist')) $projectRoot
                if (-not (Test-StrictlyWithin $outputDir $projectRoot)) { throw "前端输出目录越界（必须严格位于 $projectRoot 之下）：$outputDir" }
                $entry.Project = $projectRoot
                $entry.OutputDir = $outputDir
                $entry.Runtime = ''
                $entry.Destructive = @("清空并重写 $outputDir")
            } elseif ($kind -eq 'pdaweb') {
                Assert-RequiredFields $project @('projectRoot', 'manifestPath', 'backendConfigFile', 'outputDir') "$configPath 的 $id 条目"
                $projectRoot = Resolve-FullPath ([string]$project.projectRoot) $RepoRoot
                $outputDir = Resolve-FullPath ([string]$project.outputDir) $projectRoot
                if (-not (Test-StrictlyWithin $outputDir $projectRoot)) { throw "PDA Web 导出目录越界（必须严格位于 $projectRoot 之下）：$outputDir" }
                $manifestPath = Resolve-FullPath ([string]$project.manifestPath) $projectRoot
                $backendConfigFile = Resolve-FullPath ([string]$project.backendConfigFile) $projectRoot
                $entry.Project = $projectRoot
                $entry.OutputDir = $outputDir
                $entry.Runtime = ''
                $entry.BackendConfigFile = $backendConfigFile
                $entry.SourceHash = Get-PdaSourceHash $manifestPath $backendConfigFile
                $entry.Destructive = @("HBuilderX web 发行全量重建 $outputDir：该目录会被清空重写，其中手工放入的文件会丢失")
            } elseif ($kind -eq 'pda') {
                Assert-RequiredFields $project @('projectRoot', 'manifestPath', 'backendConfigFile', 'outputDir', 'versionMarker') "$configPath 的 $id 条目"
                $projectRoot = Resolve-FullPath ([string]$project.projectRoot) $RepoRoot
                $manifestPath = Resolve-FullPath ([string]$project.manifestPath) $projectRoot
                $backendConfigFile = Resolve-FullPath ([string]$project.backendConfigFile) $projectRoot
                $versionMarker = Resolve-FullPath ([string]$project.versionMarker) $projectRoot
                $entry.Project = $projectRoot
                $entry.OutputDir = Resolve-FullPath ([string]$project.outputDir) $projectRoot
                $entry.Runtime = ''
                $entry.BackendConfigFile = $backendConfigFile
                $entry.SourceHash = Get-PdaSourceHash $manifestPath $backendConfigFile
                $entry.CurrentVersion = $null
                try { $entry.CurrentVersion = [string](Read-JsonFile $manifestPath).versionName } catch { $entry.CurrentVersion = $null }
                # 预测值 = PDA manifest 的 versionName 自增一位（build-apk.ps1 的规则）。
                # 与 publish-pda.ps1 用同一个 lib 函数算，两处不可能不一致。
                $currentTuple = Get-VersionTuple ([string]$entry.CurrentVersion) '^(\d+)\.(\d+)\.(\d+)\.(\d+)$'
                if ($null -ne $currentTuple) { $entry.PredictedVersion = Format-Version -Tuple (Get-NextVersionTuple $currentTuple) -Prefix '' }
                $entry.VersionMarker = $versionMarker
                $entry.Destructive = @(
                    "PDA 构建自增 $manifestPath 的 versionName/versionCode（构建失败也照样消耗版本号）",
                    'PDA 构建改写 release/simpleDemo/build.gradle 与 release/simpleDemo/src/main/AndroidManifest.xml',
                    'PDA 构建清空 release/app-resources 与 release/simpleDemo/src/main/assets/apps/<appid>',
                    "PDA 构建覆盖 release/local.properties、$versionMarker 与 unpackage/resources/<appid>"
                )
            } else {
                throw "未知的发布类别：$kind（必须取自 config 的 kindOrder）"
            }
            $items += $entry
        }
    }
    return $items
}

function Assert-ReleaseConfig($Config) {
    foreach ($key in @('targets', 'kindOrder', 'defaultKinds', 'archiveNaming', 'version', 'packaging', 'safety')) {
        if ($null -eq $Config.PSObject.Properties[$key]) { throw "发布配置缺少字段：$key" }
    }
    if ($null -eq $Config.PSObject.Properties['schemaVersion'] -or [int]$Config.schemaVersion -ne 1) { throw '只支持 release.json 的 schemaVersion=1。' }
    Assert-RequiredFields $Config @('repoRoot') 'release.json'
    $kindOrder = @([string[]]$Config.kindOrder)
    if ($kindOrder.Count -eq 0) { throw 'release.json 的 kindOrder 不能为空。' }
    foreach ($kind in @([string[]]$Config.defaultKinds)) {
        if ($kindOrder -notcontains $kind) { throw "defaultKinds 里的 '$kind' 不在 kindOrder 中。" }
    }
    # pda 产出的是原始 APK，不参与统一 ZIP 命名；其余每个**项目**都必须有发布包前缀。
    # 完整性校验放在项目清单可读之后做（见计划段：那里能列出全部已配置项目），
    # 这里只要求 prefixes 存在且非空。
    if ($null -eq $Config.archiveNaming.PSObject.Properties['prefixes']) {
        throw 'archiveNaming 缺少字段：prefixes（项目 id → 发布包前缀）'
    }
    if (@($Config.archiveNaming.prefixes.PSObject.Properties).Count -eq 0) {
        throw 'archiveNaming.prefixes 不能为空。'
    }
    foreach ($name in @($Config.targets.PSObject.Properties | ForEach-Object { $_.Name })) {
        Assert-RequiredFields $Config.targets.$name @('outputRoot') "targets.$name"
    }
    Assert-RequiredFields $Config.version @('pattern', 'prefix', 'initialVersion') 'version'
    Assert-RequiredFields $Config.packaging @('stagingDirName') 'packaging'
    Assert-RequiredFields $Config.safety @('allowedBranches') 'safety'
}

try {
    # -Config 的默认值在这里补（不能在 param 块里用 $PSScriptRoot，见参数声明处的说明）。
    if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path $PSScriptRoot '..\config\release.json' }
    $Config = [IO.Path]::GetFullPath($Config)
    if (-not (Test-Path -LiteralPath $Config -PathType Leaf)) { throw "发布配置不存在：$Config" }
    $configObject = Read-JsonFile $Config
    if ($null -eq $configObject) { throw "发布配置不是合法 JSON：$Config" }
    Assert-ReleaseConfig $configObject

    $configDir = Split-Path -Parent $Config
    $repoRoot = Resolve-FullPath ([string]$configObject.repoRoot) (Get-Location).Path
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { throw "仓库根目录不存在：$repoRoot" }
    $kindOrder = @([string[]]$configObject.kindOrder)

    # ---- 选择 -------------------------------------------------------------
    # 外层 @() 不可省：Split-List 无输入时返回空数组，跨函数边界会被解包成 $null
    # （详见 lib/common.ps1 里 Split-List 的注释）。
    $onlyItems = @(Split-List $Only)
    $requestedKinds = @(Split-List $Kind)
    foreach ($kind in $requestedKinds) {
        if ($kindOrder -notcontains $kind) { throw "未知的发布类别：$kind。可选：$($kindOrder -join '、')" }
    }
    if ($onlyItems.Count -gt 0) { $selectedKinds = $kindOrder }      # 按 id 选：类别由 id 自己决定
    elseif ($requestedKinds.Count -gt 0) { $selectedKinds = @($kindOrder | Where-Object { $requestedKinds -contains $_ }) }
    else { $selectedKinds = @($kindOrder | Where-Object { @([string[]]$configObject.defaultKinds) -contains $_ }) }

    # ---- 版本 -------------------------------------------------------------
    $versionBlock = $configObject.version
    $versionPattern = [string]$versionBlock.pattern
    $versionPrefix = [string]$versionBlock.prefix
    $outputRoots = [ordered]@{}
    foreach ($name in @($configObject.targets.PSObject.Properties | ForEach-Object { $_.Name })) {
        $raw = [string]$configObject.targets.$name.outputRoot
        if (-not [IO.Path]::IsPathRooted((Expand-PathToken $raw))) { throw "targets.$name.outputRoot 必须是绝对路径（可用 {desktop} 与 ~ 开头）：$raw" }
        $outputRoots[$name] = Resolve-FullPath $raw $repoRoot
    }
    $outputRoot = $outputRoots[$Target]

    # 扫描根 = 配置里的历史根 + 全部环境的输出根。历史根是**必须的**：新结构把产物放在
    # publish/<环境>/ 之下，那里一开始没有任何版本目录，只扫新结构会让版本号倒退到
    # initialVersion（真实历史最高在桌面 dev/publish 里）。测试线与生产线共用一条版本线，
    # 所以两边的输出根都要扫。
    $scanRoots = @()
    foreach ($root in @([string[]](Get-OptionalProperty $versionBlock 'scanRoots' @()))) {
        $resolved = Resolve-FullPath $root $repoRoot
        if (-not [string]::IsNullOrWhiteSpace($resolved) -and $scanRoots -notcontains $resolved) { $scanRoots += $resolved }
    }
    foreach ($name in $outputRoots.Keys) {
        if ($scanRoots -notcontains $outputRoots[$name]) { $scanRoots += $outputRoots[$name] }
    }
    $candidates = Get-VersionCandidates $scanRoots $versionPattern
    $maxTuple = Get-MaxVersionTuple $candidates
    if ($null -eq $maxTuple) {
        $maxTuple = Get-VersionTuple ([string]$versionBlock.initialVersion) $versionPattern
        if ($null -eq $maxTuple) { throw "没有找到任何版本候选，且 version.initialVersion 不是合法版本号：$($versionBlock.initialVersion)" }
        $maxSource = 'initialVersion'
    } else { $maxSource = 'history' }

    $versionMode = 'reuse'
    $resolvedTuple = $maxTuple
    if ($BumpVersion) { $versionMode = 'bump'; $resolvedTuple = Get-NextVersionTuple $maxTuple }
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $explicitTuple = Get-VersionTuple $Version $versionPattern
        if ($null -eq $explicitTuple) { throw "指定版本无效：$Version（必须匹配 version.pattern：$versionPattern）" }
        $resolvedTuple = $explicitTuple
        $versionMode = 'explicit'
    }
    $versionSuffix = ([string]$VersionSuffix).Trim()
    # param 上的 ValidatePattern 允许空串（见参数声明处），且脚本可能被点源调用绕过校验，这里再挡一次。
    if (-not [string]::IsNullOrWhiteSpace($versionSuffix) -and $versionSuffix -notmatch '^_[A-Za-z0-9-]+$') {
        throw "版本后缀无效：$VersionSuffix。只允许一个下划线加字母、数字或短横线（如 _fix、_fix2）。"
    }
    # 版本标签是**唯一**的版本表示法：既做版本目录名，也做发布包名里的 {version}。
    $versionLabel = (Format-Version -Tuple $resolvedTuple -Prefix $versionPrefix) + $versionSuffix

    # ---- 重复发布模式与批次时间戳 -----------------------------------------
    $duplicateMode = [string](Get-OptionalProperty $configObject.targets.$Target 'duplicateMode' 'suffix')
    if ($duplicateMode -notin @('overwrite', 'suffix')) { throw "targets.$Target.duplicateMode 只能是 overwrite 或 suffix，实际为：$duplicateMode" }
    $stampFormat = [string](Get-OptionalProperty $configObject.archiveNaming 'duplicateStampFormat' 'yyyyMMddHH')
    $batchStamp = $BatchStamp
    if ([string]::IsNullOrWhiteSpace($batchStamp)) { $batchStamp = (Get-Date).ToString($stampFormat) }
    $duplicateSuffix = ''
    if ($duplicateMode -eq 'suffix') { $duplicateSuffix = '_' + $batchStamp }
    # 批次时间戳**刻意不进 digest**：它是墙上时钟，进了 digest 会让「预检→确认→执行」
    # 只要跨越整点就无端漂移。它只影响重复发布时新文件的命名，而时间戳变化在危险方向上
    # 是安全的（换一个戳只会少覆盖、不会多覆盖——旧戳那个文件会原样留下）。

    # ---- 工具（无条件进 digest） -------------------------------------------
    # 无条件解析，不按本次是否选中：否则 digest 的结构会随选择变化，同一份配置在不同
    # 选择下算出的计划形状不一致，等于把「工具换了」这类信息藏在选择里。
    $tools = [ordered]@{
        dotnet     = Find-Tool '' @('dotnet')
        pnpm       = Find-Tool '' @('pnpm.cmd', 'pnpm')
        bandizip   = Find-Tool ([string](Get-OptionalProperty $configObject.packaging 'executable' '')) @('bz.exe', 'bz')
        hbuilderx  = $null
        powershell = Find-Tool '' @('powershell.exe')
    }
    # HBuilderX CLI 由配置显式给出，**不走 Find-Tool**：cli.exe 不在 PATH 上，
    # $env:HBUILDERX_CLI 也只存在于 build-apk.ps1 自己的进程里（它 dot-source 了
    # 被 gitignore 的 release/local.env.ps1）。Find-Tool 在这里还有两个额外风险：
    # 配置非空但文件不存在时它直接返回 $null（掩盖「路径写错了」）；配置为空时会退化成
    # 对通用名 cli.exe 做 PATH 查找，可能选中别的软件的同名工具。
    $pdawebConfig = Read-JsonFile (Get-KindConfigPath $configDir 'pdaweb')
    if ($null -ne $pdawebConfig) {
        $firstPdaWeb = @($pdawebConfig.projects)[0]
        if ($null -ne $firstPdaWeb) {
            $cliConfig = [string](Get-OptionalProperty $firstPdaWeb 'hbuilderxCli' '')
            if (-not [string]::IsNullOrWhiteSpace($cliConfig)) { $tools.hbuilderx = Resolve-FullPath $cliConfig $repoRoot }
        }
    }
    if ($null -eq $tools.powershell -or -not $tools.powershell.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw "未找到 powershell.exe（派生生产者与 package.ps1 都依赖它）：$($tools.powershell)"
    }

    # ---- 计划项 -----------------------------------------------------------
    # 同样包 @()：没有匹配项时 Get-PlanItems 返回空数组，解包成 $null 后下面每一处
    # @($planItems ...) 虽然还能用，但 `$planItems.Count` 一类的写法会炸。
    $planItems = @(Get-PlanItems $repoRoot $configDir $selectedKinds $onlyItems)
    if ($onlyItems.Count -gt 0) {
        $knownIds = @($planItems | ForEach-Object { $_.Id })
        $unknownIds = @($onlyItems | Where-Object { $knownIds -notcontains $_ })
        if ($unknownIds.Count -gt 0) {
            $allIds = @()
            foreach ($kind in $kindOrder) {
                $pc = Read-JsonFile (Get-KindConfigPath $configDir $kind)
                if ($null -ne $pc) { $allIds += @($pc.projects | ForEach-Object { [string]$_.id }) }
            }
            throw ("未知的发布项：{0}。可选：{1}" -f ($unknownIds -join '、'), (($allIds | Sort-Object -Unique) -join '、'))
        }
    }

    # ---- 破坏性动作、落地名与「将覆盖什么」 --------------------------------
    $destructive = @()
    foreach ($item in $planItems) { $destructive += @($item.Destructive) }

    $versionDir = Join-Path $outputRoot $versionLabel
    if (-not (Test-StrictlyWithin $versionDir $outputRoot)) { throw "版本目录越界：$versionDir" }
    $naming = $configObject.archiveNaming
    $namingPattern = [string](Get-OptionalProperty $naming 'pattern' '{prefix}_{version}{duplicate}.zip')
    $prefixes = $naming.prefixes

    # 计划粒度 = **项目**，与 package.ps1 的落盘模型一致：一个项目一个包、包内不带目录层。
    # 项目 id 不再是版本目录下的平级子目录，也不再聚合成族包。
    $planned = @()
    $confirmedReplacements = @()

    # 前缀完整性在**全部已配置项目**上校验，而不只是本次选中的那些：缺一个前缀现在就要说，
    # 否则要等到某天选中那个项目、构建全部跑完、package.ps1 落盘时才炸。
    foreach ($kind in @([string[]]$configObject.kindOrder)) {
        if ($kind -eq 'pda') { continue }
        $kindConfig = Read-JsonFile (Get-KindConfigPath $configDir $kind)
        if ($null -eq $kindConfig) { continue }
        foreach ($project in @($kindConfig.projects)) {
            $configuredId = [string]$project.id
            if ([string]::IsNullOrWhiteSpace($configuredId)) { continue }
            $prefixProperty = $prefixes.PSObject.Properties[$configuredId]
            if ($null -eq $prefixProperty -or [string]::IsNullOrWhiteSpace([string]$prefixProperty.Value)) {
                throw "archiveNaming.prefixes 缺少项目 '$configuredId'（类别 $kind）的发布包前缀。"
            }
        }
    }

    foreach ($item in $planItems) {
        if ($item.Kind -eq 'pda') {
            # PDA APK 的文件名由 build-apk.ps1 自带时间戳决定，预检**不预测**它：
            # 预测要么靠猜命名规则，要么在预检阶段执行构建脚本，两者都不能接受。
            # 它也不参与命名与重复发布判定，所以 path 只能报到版本目录这一层。
            $planned += [ordered]@{ id = $item.Id; kind = 'apk'; name = '(构建时决定，文件名自带时间戳)'; path = $versionDir; duplicate = $false }
            continue
        }
        $prefix = [string]$prefixes.($item.Id)
        # 命名规则与重复发布判定都走 lib 里的唯一实现，与 package.ps1 落盘时同源，
        # 所以报告里展示的包名与实际落盘的包名不可能不一致。
        $resolved = Resolve-ArtifactName -Pattern $namingPattern -Prefix $prefix -VersionLabel $versionLabel -ItemDir $versionDir -DuplicateMode $duplicateMode -DuplicateSuffix $duplicateSuffix
        if ($resolved.IsDuplicate) { $destructive += "覆盖同版本重复发布包 $versionDir\$($resolved.Name)" }
        $targetPath = Join-Path $versionDir $resolved.Name
        if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
            $destructive += "删除原产物 $targetPath"
            $confirmedReplacements += $targetPath
        }
        $planned += [ordered]@{ id = $item.Id; kind = 'zip'; name = $resolved.Name; path = $targetPath; duplicate = $resolved.IsDuplicate }
    }
    # 前缀是**按项目**配的，配重了会让两个项目写到同一个包名上互相覆盖。package.ps1 也会在
    # 动手之前拒绝，但那时构建已经全部跑完；预检就该拦下。
    $zipTargets = @($planned | ForEach-Object { if ($_['kind'] -eq 'zip') { $_['path'] } })
    $collided = @($zipTargets | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($collided.Count -gt 0) {
        throw ("archiveNaming.prefixes 配置重复，多个项目会写到同一个包名：{0}。每个项目的前缀必须唯一。" -f (($collided | ForEach-Object { $_.Name }) -join '、'))
    }

    # ---- 环境与分支门禁 ---------------------------------------------------
    $git = Get-GitInfo $repoRoot
    $targetBlock = $configObject.targets.$Target
    $allowedBranches = @([string[]]$configObject.safety.allowedBranches)
    $branchGate = ($allowedBranches -contains $git.Branch) -or $ConfirmBranch
    $needClean = [bool](Get-OptionalProperty $targetBlock 'requireCleanWorktree' $true)
    # 工作区要求按环境配置（test 通常不需要干净工作区，production 需要）。
    # 覆盖方式只有 -AllowDirty 一个，不再有第二个配置开关——两个开关
    # （配置允许 + 命令行允许）会让人分不清到底哪一个放行的。
    $dirtyAllowed = (-not $needClean) -or $git.Clean -or $AllowDirty

    # ---- digest -----------------------------------------------------------
    # 不含 Mode：预检与执行是两次调用，Mode 进 digest 会让两者永远算不出同一个值。
    #
    # **不含工作区干净标志。** 它是个会在两次调用之间自己翻转的输入：本机的 Hook 每次
    # 用户发言都会轮换 .ai/project/knowledge-feedback/candidates/<日期>/ 下的文件，
    # 「删旧之后、写新之前」有瞬间工作区是干净的，于是同一份计划算出两个 digest，
    # 发布被拒并报「PlanDigest 不匹配」，看起来像配置变了，其实什么都没变（2026-09-16 实测）。
    # 从 digest 里剔除它不降低安全性：执行阶段会**重新**读一次 git 状态并重算 §阻塞原因，
    # 脏工作区该拦的照样在动手之前被拦下（见下面 Publish 分支的 $blocking 判定）。
    # Branch 同理（由 $branchGate 重新判定）；HeadSha 不同——没有任何门禁复查提交号，
    # 它是唯一能抓住「预检后被提交了新代码」的输入，必须留在 digest 里。
    # 工作区状态仍然照常出现在报告里（WorktreeClean），只是不再参与哈希。
    $plan = [ordered]@{
        Target             = $Target
        Version            = $versionLabel
        VersionMode        = $versionMode
        Branch             = $git.Branch
        HeadSha            = $git.HeadSha
        RepoRoot           = $repoRoot
        OutputRoot         = $outputRoot
        DuplicateMode      = $duplicateMode
        Tools              = $tools
        Items              = @($planItems | ForEach-Object { [ordered]@{ Id = $_.Id; Kind = $_.Kind; SourceHash = $_.SourceHash; PredictedVersion = $_.PredictedVersion } })
        PlannedArtifacts   = @($planned)
        DestructiveActions = @($destructive)
    }
    $canonical = $plan | ConvertTo-Json -Depth 8 -Compress
    $digestBytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $planDigestValue = ([Security.Cryptography.SHA256]::Create().ComputeHash($digestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''

    # ---- 日志 -------------------------------------------------------------
    $logDir = Join-Path $outputRoot ([string](Get-OptionalProperty $configObject.logs 'dirName' '_logs'))
    if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path (Join-Path $logDir $RunId) 'publish.jsonl' }
    $statusPath = [IO.Path]::ChangeExtension($LogPath, '.status.json')
    if ($PersistLog) {
        Initialize-RunLog -RunId $RunId -LogPath $LogPath -StatusPath $statusPath -Json:$Json
        Write-Event 'run' 'started' 'publish' ("目标 {0}，版本 {1}，日志 {2}" -f $Target, $versionLabel, $LogPath)
    } else {
        # 预检不落盘：不给 Write-Event 日志路径，它自然只往 stdout 报。
        Initialize-RunLog -RunId $RunId -Json:$Json
        Write-Event 'run' 'started' 'publish' ("目标 {0}，版本 {1}，预检模式不写日志" -f $Target, $versionLabel)
    }

    # ---- 提示信息（只提示，不阻塞） ----------------------------------------
    $warnings = @()
    $pdaVersions = [ordered]@{ Current = $null; Predicted = $null; LastLanded = $null }
    $configSharingItem = @($planItems | Where-Object { $_.Kind -in @('pda', 'pdaweb') }) | Select-Object -First 1
    $backendConfig = [ordered]@{ ConfigFile = $null; Lines = @() }
    if ($null -ne $configSharingItem) {
        # config.js 决定 APK/H5 连哪个后端，是保护文件（只由用户改）。这里展示整份原文，
        # 不解析、不归一化、更不修改——整块注释掉的 Web/测试环境配置也要看得见。
        # 必须用 [IO.File]::ReadAllLines 而不是 Get-Content：Get-Content 返回的字符串带
        # PSPath/PSDrive/PSProvider 装饰属性，一旦进入报告，末尾的 ConvertTo-Json 会连带
        # 遍历整个 PSDrive/PSProvider 对象图，输出按深度指数膨胀（实测 depth=6 → 23MB，
        # depth=12 吃满数 GB 并卡死）。
        $backendConfig.ConfigFile = [string]$configSharingItem.BackendConfigFile
        if (Test-Path -LiteralPath $backendConfig.ConfigFile -PathType Leaf) {
            $backendConfig.Lines = @([IO.File]::ReadAllLines([string]$backendConfig.ConfigFile))
        }
    }
    foreach ($item in @($planItems | Where-Object { $_.Kind -eq 'pda' })) {
        $pdaVersions.Current = [string]$item.CurrentVersion
        $pdaVersions.Predicted = [string]$item.PredictedVersion
        $pdaVersions.LastLanded = $null
        if (Test-Path -LiteralPath ([string]$item.VersionMarker) -PathType Leaf) {
            try { $pdaVersions.LastLanded = ([IO.File]::ReadAllText([string]$item.VersionMarker)).Trim() } catch { $pdaVersions.LastLanded = $null }
        }
        if ([string]::IsNullOrWhiteSpace([string]$item.PredictedVersion)) {
            $warnings += "PDA manifest.json 的 versionName '$($item.CurrentVersion)' 不是可解析的四段数字，无法预测本次会产出哪个版本号。"
        }
        # 一致性提示：正常路径下构建完成后 manifest 版本与 version.txt 记录的已落地版本相等。
        # 不相等只有两种可能——号被回退过，或上一轮构建失败消耗了号却没走到写 version.txt。
        # 两种都会让本次产出与历史 APK 同号、内容不同的包。只判等，不比较大小。
        if (-not [string]::IsNullOrWhiteSpace([string]$pdaVersions.LastLanded) -and
            [string]$item.CurrentVersion -ne [string]$pdaVersions.LastLanded) {
            $warnings += "PDA manifest.json 当前版本 $($item.CurrentVersion) 与 version.txt 记录的已落地版本 $($pdaVersions.LastLanded) 不一致；manifest 疑似被回退，或上一轮构建失败消耗了版本号但未写出 version.txt。本次会产出一个与历史 APK 同号、内容不同的包。"
        }
    }
    if (@($planItems | Where-Object { $_.Kind -eq 'pda' }).Count -gt 0) {
        $warnings += 'PDA 工具链版本配对未经验证（参考文档记录的配对为 Android-SDK@5.24.82669_20260813 ↔ HBuilderX 5.24.2026081301，本机 HBuilderX CLI 自报 5.07）。打包成功不代表运行时兼容，建议装真机冒烟（扫码头、蓝牙、是否白屏）。'
    }
    if (@($planItems | Where-Object { $_.Kind -eq 'pdaweb' }).Count -gt 0) {
        # 必须带 -ErrorAction SilentlyContinue：脚本顶层是 $ErrorActionPreference='Stop'，
        # Get-Process 无匹配是非终止错误，会被提升为终止错误，让本该只发一条警告的预检崩成
        # 一句裸英文（2026-09-18 实测）。加 -ErrorAction SilentlyContinue 后可正常得到空数组。
        $hbxProcesses = @(Get-Process -Name 'HBuilderX' -ErrorAction SilentlyContinue)
        if ($hbxProcesses.Count -eq 0) {
            $warnings += 'HBuilderX 未在运行。cli.exe 需要与本机已启动的 HBuilderX 通信，未运行时 web 发行会失败；另外该项目是否已在 HBuilderX 中导入无法预检，只能由执行时的 CLI 报错暴露。'
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$tools.hbuilderx)) {
            # cli.exe 通过本机 socket 与已启动的 HBuilderX 通信，两者指向不同安装时行为不可预期。
            # .Path 对部分进程会抛访问受限，逐项 try 兜住；取不到路径就不做这项比对。
            $runningPaths = @($hbxProcesses | ForEach-Object { try { [string]$_.Path } catch { $null } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($runningPaths.Count -gt 0) {
                $cliDir = Split-Path -Parent ([string]$tools.hbuilderx)
                $runningDirs = @($runningPaths | ForEach-Object { Split-Path -Parent $_ } | Select-Object -Unique)
                if ($runningDirs -notcontains $cliDir) {
                    $warnings += "配置的 HBuilderX CLI（$($tools.hbuilderx)）与正在运行的 HBuilderX（$($runningPaths -join '、')）不在同一个安装目录；cli.exe 通过本机 socket 与已启动的实例通信，指向不同安装时行为不可预期。"
                }
            }
        }
        # 刻意**不**复用上面 PDA 那条「工具链版本配对未经验证」：它的文本讲的是 Android
        # 离线 SDK 配对（白屏、扫码头、蓝牙），对 H5 产物是假命题。
        $warnings += 'PDA Web（H5）的运行时兼容性未经验证：产物由 HBuilderX 的 web 发行生成，预检按规则不做任何版本探测，也不校验产物的浏览器兼容性。打包成功只代表导出与归档成功，建议部署后做浏览器与真机冒烟。'
    }
    if ($duplicateMode -eq 'overwrite' -and (Test-Path -LiteralPath $versionDir -PathType Container)) {
        $warnings += "targets.$Target.duplicateMode = overwrite：同版本已存在的发布包会被直接覆盖。想保留旧包请改成 suffix。"
    }

    # ---- 阻塞原因 ---------------------------------------------------------
    $blocking = @()
    if (@($planItems).Count -eq 0) { $blocking += '没有选中任何发布项，请检查 -Only / -Kind 与 release.json 的 defaultKinds。' }
    if (-not $branchGate) { $blocking += "分支 '$($git.Branch)' 不在允许列表（$($allowedBranches -join '、')），需 -ConfirmBranch。" }
    if (-not $dirtyAllowed) { $blocking += '工作区存在未提交变更，需 -AllowDirty。' }
    # PDA 走自己的版本线（APK 版本由 PDA manifest.json 自增），与 Web 版本线无关。
    # 纯 PDA 选择时递增会推进共享的 Web 版本线：凭空造出一个只装了 APK 的版本目录，
    # 且会让下一次 Web 发布从那个号继续。需要指定目录时用 -Version。
    if ($BumpVersion -and @($planItems).Count -gt 0 -and @($planItems | Where-Object { $_.Kind -ne 'pda' }).Count -eq 0) {
        $blocking += 'PDA 使用独立版本线，纯 PDA 发布不允许 -BumpVersion（会推进 Web 版本线）。需要指定目录时用 -Version vX.Y.Z.W。'
    }
    $needsArchive = $false
    foreach ($kind in @($selectedKinds)) {
        $kindItems = @($planItems | Where-Object { $_.Kind -eq $kind })
        if ($kindItems.Count -eq 0) { continue }
        if ($kind -eq 'dotnet' -and $null -eq $tools.dotnet) { $blocking += '未找到 dotnet。' }
        if ($kind -eq 'web' -and $null -eq $tools.pnpm) { $blocking += '未找到 pnpm。' }
        if ($kind -eq 'pdaweb' -and ($null -eq $tools.hbuilderx -or -not (Test-Path -LiteralPath $tools.hbuilderx -PathType Leaf))) {
            $blocking += "HBuilderX CLI 不存在：$($tools.hbuilderx)（配置项 config/projects/pdaweb.json 的 hbuilderxCli）"
        }
        if ($kind -eq 'pda') {
            foreach ($item in $kindItems) {
                if ([string]::IsNullOrWhiteSpace([string]$item.PredictedVersion)) {
                    $blocking += "PDA manifest.json 的 versionName 无法预测下一版本，需人工确认：$($item.ConfigPath)"
                }
            }
        } else { $needsArchive = $true }
    }
    # Bandizip 只在本次确实要压缩归档时才必需：PDA 产出的是原始 APK，不经归档，
    # 一个纯 PDA 发布不应该因为本机缺压缩工具而失败。
    # 判定放在循环**之外**：写在循环里的话，同时选中 dotnet 与 web 时同一条原因会出现两次。
    if ($needsArchive -and $null -eq $tools.bandizip) { $blocking += '未找到 Bandizip CLI（配置项 packaging.executable）。' }

    # 报告的 Kinds 必须是**实际有发布项的**类别。按 id 选（-Only）时 $selectedKinds 是所有
    # 类别，直接报出去会让人以为 pda/pdaweb 也在这次发布里。顺序仍取 kindOrder。
    $effectiveKinds = @($kindOrder | Where-Object { @($planItems | ForEach-Object { $_.Kind }) -contains $_ })

    $reportLogPath = $LogPath
    if (-not $PersistLog) { $reportLogPath = $null }
    $report = [ordered]@{
        Status            = 'preflight'
        RunId             = $RunId
        Mode              = $Mode
        Target            = $Target
        Only              = @($onlyItems)
        Kinds             = @($effectiveKinds)
        SelectedItems     = @($planItems | ForEach-Object { $_.Id })
        Branch            = $git.Branch
        WorktreeClean     = $git.Clean
        HeadSha           = $git.HeadSha
        Version           = $versionLabel
        VersionMode       = $versionMode
        VersionSuffix     = $versionSuffix
        VersionSource     = $maxSource
        RequestedVersion  = $Version
        MaxVersion        = (Format-Version -Tuple $maxTuple -Prefix $versionPrefix)
        VersionCandidates = @($candidates | ForEach-Object { $_.Value } | Sort-Object -Unique)
        VersionScanRoots  = @($scanRoots)
        OutputDirectory   = $versionDir
        DuplicateMode     = $duplicateMode
        BatchStamp        = $batchStamp
        PlannedArtifacts  = @($planned)
        LogPath           = $reportLogPath
        Tools             = $tools
        PlanDigest        = $planDigestValue
        Plan              = $plan
        Warnings          = @($warnings)
        BackendConfig     = $backendConfig
        PdaVersions       = $pdaVersions
        BlockingReasons   = @($blocking)
    }

    if ($Mode -eq 'Preflight') {
        if ($Json) { $report | ConvertTo-Json -Depth 10 } else { Write-Output ($report | ConvertTo-Json -Depth 10) }
        if (@($blocking).Count -gt 0) { exit 2 }
        exit 0
    }

    # ---- 真实发布 ---------------------------------------------------------
    if (-not $ConfirmPublish) { throw '真实发布必须提供 -ConfirmPublish。' }
    if (@($blocking).Count -gt 0) { throw ('预检存在阻塞原因，已中止：' + "`n  - " + (@($blocking) -join "`n  - ")) }
    if ([string]::IsNullOrWhiteSpace($PlanDigest) -or $PlanDigest -ne $planDigestValue) {
        throw "PlanDigest 不匹配。预检 digest：$planDigestValue（预检之后配置、分支、提交号、输入文件哈希或落盘状态发生了变化，请重新预检）。"
    }

    # 目录不在这里建：日志目录由其写入方（Write-Event / Write-JsonFile）自己保证存在，
    # 落盘结构由 package.ps1 负责。这里再建一遍只是把同一件事写成两处。
    $runLogDir = Split-Path -Parent $LogPath

    # 生产者按 kindOrder 顺序串行执行。顺序不是小事：pdaweb 必须排在任何 APK 构建之前——
    # H5 包会把 manifest.json 的 versionName 编进 __uniConfig.appVersion，而 APK 构建
    # 第一步就自增 manifest。改 kindOrder 前请先把这件事想清楚。
    $resultFiles = @()
    foreach ($kind in $selectedKinds) {
        $kindItems = @($planItems | Where-Object { $_.Kind -eq $kind })
        if ($kindItems.Count -eq 0) { continue }
        $producer = Join-Path $PSScriptRoot ("publish-$kind.ps1")
        if (-not (Test-Path -LiteralPath $producer -PathType Leaf)) { throw "生产者脚本不存在：$producer" }
        $resultFile = Join-Path $runLogDir ("$kind.result.json")
        $producerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $producer,
            '-RepoRoot', $repoRoot,
            '-ProjectConfig', (Get-KindConfigPath $configDir $kind),
            '-ResultFile', $resultFile,
            '-LogPath', $LogPath,
            '-RunId', $RunId,
            '-Json')
        if ($onlyItems.Count -gt 0) {
            $idsArg = (@($kindItems) | ForEach-Object { $_.Id }) -join ','
            $producerArgs += @('-Ids', $idsArg)
        }
        if ($kind -eq 'pda' -and $kindItems.Count -eq 1) {
            # 把预检算出的预期版本透传下去，让「预检之后 manifest 被改过」在**构建之前**
            # 就被发现，而不是先花几分钟构建再失败。
            # 只在恰好一个 PDA 项目时传：这个参数是单值，多于一个项目时它只能描述其中一个，
            # 传递下去会让另一个项目被误判成「manifest 被动过」。宁可不查，也不要误报。
            $predicted = [string]$kindItems[0].PredictedVersion
            if (-not [string]::IsNullOrWhiteSpace($predicted)) { $producerArgs += @('-ExpectedVersion', $predicted) }
        }
        Invoke-External $tools.powershell $producerArgs $repoRoot $kind | Out-Null
        if (-not (Test-Path -LiteralPath $resultFile -PathType Leaf)) { throw "生产者未写出结果文件：$resultFile" }
        $resultFiles += $resultFile
    }

    $packager = Join-Path $PSScriptRoot 'package.ps1'
    if (-not (Test-Path -LiteralPath $packager -PathType Leaf)) { throw "打包脚本不存在：$packager" }
    $packageResult = Join-Path $runLogDir 'package.result.json'
    $packageArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packager,
        '-RepoRoot', $repoRoot,
        '-ReleaseConfig', $Config,
        '-Target', $Target,
        '-VersionLabel', $versionLabel,
        '-DuplicateMode', $duplicateMode,
        '-BatchStamp', $batchStamp,
        '-ItemResults', ($resultFiles -join ','),
        '-ResultFile', $packageResult,
        '-LogPath', $LogPath,
        '-RunId', $RunId,
        '-Json')
    if ($confirmedReplacements.Count -gt 0) { $packageArgs += @('-ConfirmedReplacements', ($confirmedReplacements -join ',')) }
    if ($AllowStale) { $packageArgs += '-AllowStale' }
    Invoke-External $tools.powershell $packageArgs $repoRoot 'package' | Out-Null
    if (-not (Test-Path -LiteralPath $packageResult -PathType Leaf)) { throw "打包脚本未写出结果文件：$packageResult" }
    $package = Read-JsonFile $packageResult
    if ($null -eq $package) { throw "打包结果不是合法 JSON：$packageResult" }

    $artifacts = @($package.items | ForEach-Object { [string]$_.path })
    Write-Event 'run' 'succeeded' 'publish' ("完成，产物目录 {0}" -f $versionDir)
    $report.Status = 'succeeded'
    $report.Artifacts = $artifacts
    $report.PackageResult = $package
    if ($Json) { $report | ConvertTo-Json -Depth 10 } else { Write-Output ($report | ConvertTo-Json -Depth 10) }
    exit 0
} catch {
    # 位置信息必须带上：本脚本有 600 多行，一句「属性不存在」而不给出处，
    # 排障只能靠猜。StrictMode 抛出的裸 .NET 消息尤其需要它。
    $where = ''
    $info = $_.InvocationInfo
    if ($null -ne $info -and $null -ne $info.ScriptLineNumber -and $info.ScriptLineNumber -gt 0) {
        $where = '（{0} 第 {1} 行）' -f [IO.Path]::GetFileName([string]$info.ScriptName), $info.ScriptLineNumber
    }
    Write-Event 'run' 'failed' 'publish' ($_.Exception.Message + $where)
    [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message + $where)
    exit 1
}
