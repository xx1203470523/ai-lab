# package.ps1 —— 归档与落盘。全技能**唯一**写交付物的脚本。
#
# 职责边界：
#   * 生产者（publish-*.ps1）只把产物落到项目自己的输出目录，不碰交付目录；
#   * 本脚本只做「压缩 → 校验 → 落地命名 → 落盘」，不构建任何东西、不决定版本号。
# 因此单独重跑本脚本不会触发任何构建副作用。
#
# 落地结构（**每个项目一个发布包，包内不带目录层**；版本目录下平铺交付物）：
#   <outputRoot>/<标签>/<发布包>       ← 每个项目一个，名字由 archiveNaming.prefixes 查表得来
#   <outputRoot>/<标签>/<APK>          ← PDA 原样复制，不压缩、不重命名
#   <outputRoot>/_logs/<runId>/        ← 运行日志与本次 run 的 manifest，与交付物分开
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ReleaseConfig,
    [Parameter(Mandatory = $true)][string]$Target,
    # 版本标签：v 前缀 + 四段 + 可选后缀（如 v1.4.1.15、v1.4.1.15_fix）。
    # 目录名与发布包名**共用**这一个值，不再有第二个版本表示法。
    [Parameter(Mandatory = $true)][string]$VersionLabel,
    # overwrite | suffix。留空时取 targets.<Target>.duplicateMode。
    [string]$DuplicateMode = '',
    # 批次时间戳（suffix 模式必需）。由编排层在预检时算定并写进 digest，
    # 保证「同一次发布中的所有发布包使用同一个批次时间戳」，且执行的就是用户确认过的那个。
    [string]$BatchStamp = '',
    # 各生产者写出的结果文件，本脚本只读它们，不重新构建。
    [string[]]$ItemResults = @(),
    # 预检报告里已向用户列明「会被覆盖」的完整路径。落盘时若发现要覆盖一个不在
    # 这份清单里的文件，说明它在预检之后出现，立刻中止——这正是 digest 机制的本意。
    [string[]]$ConfirmedReplacements = @(),
    [switch]$AllowStale,
    [string]$ResultFile = '',
    [string]$LogPath = '',
    [string]$RunId = '',
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\exec.ps1')

$KnownTargetFields = @('outputRoot', 'requireCleanWorktree', 'duplicateMode')
$KnownNamingFields = @('pattern', 'prefixes', 'duplicateStampFormat')

function Assert-ArchivePlatform([string[]]$ArchiveEntries, [string]$Runtime, [string]$Archive) {
    # 校验必须落在"最终压进归档的东西"上，而不是源目录上。Visual Studio 的 Folder 发布配置
    # （Properties\PublishProfiles\*.pubxml，RID=win-x64）没有设 PublishDir，默认发布到
    # bin\Release\net8.0\publish —— 与本技能的后端发布目录完全相同。它会在「清空目录之后、
    # 压缩之前」的窗口里写入，所以「发布前先清空」防不住它：2026-09-11 的 Admin_v1.4.1.9.zip
    # 就是这样被塞进 11 个 win-x64 文件、从 52.9MB 变成 81.1MB 的，而当时源目录清单与归档清单
    # 是"一致"的，既有校验拦不下。检查归档内容则任何时刻的污染都跑不掉，且没有竞态窗口。
    if ([string]::IsNullOrWhiteSpace($Runtime)) { return }
    $windowsRuntime = $Runtime -like 'win-*'
    $foreign = @($ArchiveEntries | Where-Object {
        if ($windowsRuntime) { $_ -like '*.so' } else { ($_ -like '*.exe') -or ($_ -like '*web.config') }
    })
    if ($foreign.Count -gt 0) {
        $sample = ($foreign | Select-Object -First 5) -join '、'
        throw ("归档混入了非 $Runtime 平台的产物（$($foreign.Count) 个，例如：$sample）。" +
            "最常见原因是发布期间 Visual Studio 的 Folder 发布配置（Properties\PublishProfiles\*.pubxml，RID=win-x64）" +
            "写入了同一个发布目录；请暂停 VS 发布后重发，不要靠手工删文件掩盖。归档：$Archive")
    }
}

function New-Archive([string]$Bandizip, [string]$Archive, [string]$SourceDirectory, [string]$Item, [string]$Runtime) {
    $stats = Get-SourceStats $SourceDirectory
    if (-not $stats.Exists -or $stats.Count -eq 0) { throw "源目录为空，拒绝打包：$SourceDirectory" }
    Write-Event 'archive' 'started' $Item ("源文件 {0} 个，{1} 字节" -f $stats.Count, $stats.Bytes)
    Invoke-External $Bandizip @('c', '-y', '-r', $Archive, '*') $SourceDirectory $Item | Out-Null
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "压缩包未生成：$Archive" }
    $archiveInfo = Get-Item -LiteralPath $Archive
    if ($archiveInfo.Length -le 0) { throw "压缩包为空：$Archive" }
    Invoke-External $Bandizip @('t', '-y', $Archive) (Split-Path -Parent $Archive) ($Item + '-integrity') | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) })
        if ($entries.Count -ne $stats.Count) { throw "归档文件数不一致：源目录 $($stats.Count)，归档 $($entries.Count)。" }
        $sourceRelative = @($stats.Files | ForEach-Object { $_.FullName.Substring($SourceDirectory.Length).TrimStart('\').Replace('\', '/') } | Sort-Object)
        $archiveRelative = @($entries | ForEach-Object { $_.FullName.Replace('\', '/') } | Sort-Object)
        if ((Compare-Object $sourceRelative $archiveRelative)) { throw '归档条目与源目录清单不一致。' }
        # 一个包只有一个源目录、一个 runtime（web 类没有 runtime，函数内直接返回），
        # 所以平台污染校验直接在归档条目上做，判据与改动前完全一致。
        Assert-ArchivePlatform $archiveRelative $Runtime $Archive
    } finally { $zip.Dispose() }
    Write-Event 'archive' 'succeeded' $Item ("压缩包 {0} 字节，已通过完整性和清单测试" -f $archiveInfo.Length)
    return [pscustomobject]@{ SourceFiles = $stats.Count; SourceBytes = $stats.Bytes; ArchiveBytes = $archiveInfo.Length }
}

$staging = $null
try {
    Initialize-RunLog -RunId $RunId -LogPath $LogPath -Json:$Json
    # 跨进程传进来的列表是逗号分隔的单个 token（powershell -File 不解析逗号）。
    # 外层 @() 不可省：Split-List 无输入时返回空数组，跨函数边界会被解包成 $null
    # （详见 lib/common.ps1 里 Split-List 的注释）。
    $ItemResults = @(Split-List $ItemResults)
    $ConfirmedReplacements = @(Split-List $ConfirmedReplacements)
    $config = Read-JsonFile $ReleaseConfig
    if ($null -eq $config) { throw "发布配置不存在或不是合法 JSON：$ReleaseConfig" }
    Assert-RequiredFields $config @('targets', 'version', 'packaging', 'archiveNaming') 'release.json'

    if ([string]::IsNullOrWhiteSpace($VersionLabel)) { throw '缺少版本标签。' }
    Assert-SafePathSegment $VersionLabel '版本标签'
    # 版本标签 = 版本号 + 可选后缀（_fix 之类）。校验只认配置里的 version.pattern，
    # 不在这里再写死一遍四段形状：两处形状迟早会不一致。
    $versionPattern = [string](Get-OptionalProperty $config.version 'pattern' '^v(\d+)\.(\d+)\.(\d+)\.(\d+)$')
    $numericPart = $VersionLabel
    if ($numericPart -match '^(.+?)(_[A-Za-z0-9-]+)$') { $numericPart = $Matches[1] }
    $versionMatch = [regex]::Match($numericPart, $versionPattern)
    if (-not $versionMatch.Success -or $versionMatch.Value -ne $numericPart) {
        throw "版本标签不合法：$VersionLabel（版本号部分必须完整匹配配置中的 version.pattern：$versionPattern，末尾可带 _后缀）。"
    }

    # 输出根按环境隔离：test 与 production 各自独立判断重复发布，互不影响。
    $targetBlock = $config.targets.PSObject.Properties[$Target]
    if ($null -eq $targetBlock -or $null -eq $targetBlock.Value) {
        $allowedTargets = @($config.targets.PSObject.Properties | ForEach-Object { $_.Name })
        throw "未知的发布环境：$Target。已配置的环境：$($allowedTargets -join '、')"
    }
    Assert-NoUnknownFields $targetBlock.Value $KnownTargetFields "targets.$Target"
    Assert-RequiredFields $targetBlock.Value @('outputRoot') "targets.$Target"
    # 输出根允许落在仓库之外（默认就在桌面），但必须是展开 token 后的绝对路径：
    # 相对路径会被解析到仓库里，而交付目录出现在仓库里几乎一定是写错了。
    $rawOutputRoot = [string]$targetBlock.Value.outputRoot
    if (-not [IO.Path]::IsPathRooted((Expand-PathToken $rawOutputRoot))) {
        throw "targets.$Target.outputRoot 必须是绝对路径（可用 {desktop} 与 ~ 开头）：$rawOutputRoot"
    }
    $outputRoot = Resolve-FullPath $rawOutputRoot $RepoRoot

    $mode = $DuplicateMode
    if ([string]::IsNullOrWhiteSpace($mode)) { $mode = [string](Get-OptionalProperty $targetBlock.Value 'duplicateMode' 'suffix') }
    if ($mode -notin @('overwrite', 'suffix')) { throw "duplicateMode 只能是 overwrite 或 suffix，实际为：$mode" }

    Assert-NoUnknownFields $config.archiveNaming $KnownNamingFields 'archiveNaming'
    Assert-RequiredFields $config.archiveNaming @('prefixes') 'archiveNaming'
    $pattern = [string](Get-OptionalProperty $config.archiveNaming 'pattern' '{prefix}_{version}{duplicate}.zip')
    $prefixes = $config.archiveNaming.prefixes
    $stampFormat = [string](Get-OptionalProperty $config.archiveNaming 'duplicateStampFormat' 'yyyyMMddHH')

    if ($mode -eq 'suffix' -and [string]::IsNullOrWhiteSpace($BatchStamp)) {
        # 批次时间戳必须由编排层在预检时算定：这里现算会与用户确认过的 digest 脱节，
        # 而且同一次发布里不同项目可能跨过整点，得到两个不同的戳。
        throw 'suffix 模式必须由调用方提供 -BatchStamp（预检时算定的批次时间戳）。'
    }
    $duplicateSuffix = ''
    if ($mode -eq 'suffix') { $duplicateSuffix = '_' + $BatchStamp }

    $versionDir = Join-Path $outputRoot $VersionLabel
    if (-not (Test-StrictlyWithin $versionDir $outputRoot)) { throw "版本目录越界：$versionDir" }

    $stagingName = [string](Get-OptionalProperty $config.packaging 'stagingDirName' '_staging')
    $staging = Join-Path $outputRoot ($stagingName + '-' + $VersionLabel + '-' + [guid]::NewGuid().ToString('N'))
    if (-not (Test-StrictlyWithin $staging $outputRoot)) { throw "暂存目录越界：$staging" }
    # 显式建出来：暂存目录现在只作为「归档文件搬进版本目录之前的临时位置」。不依赖压缩
    # 工具顺带创建父目录——那属于隐式依赖，换个工具或换个参数就会失败。
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    $staleHours = [int](Get-OptionalProperty $config.packaging 'staleSourceHours' 24)
    $bandizip = $null

    # ---- 收集生产者结果 ---------------------------------------------------
    $items = @()
    # 循环变量叫 $resultFilePath，**不能**叫 $resultFile：PowerShell 变量名大小写不敏感，
    # 那样它会与本脚本的参数 $ResultFile 是同一个变量，循环结束后参数值变成最后一个结果
    # 文件路径，末尾写 payload 就写错文件（2026-09-23 实测：package 的 payload 被写进
    # pdaweb.result.json，package.result.json 从未生成，发布成功却报成假失败）。
    foreach ($resultFilePath in @($ItemResults)) {
        if ([string]::IsNullOrWhiteSpace($resultFilePath)) { continue }
        $result = Read-JsonFile $resultFilePath
        if ($null -eq $result) { throw "生产者结果文件不存在或不是合法 JSON：$resultFilePath" }
        foreach ($item in @($result.items)) { $items += $item }
    }
    if ($items.Count -eq 0) { throw '没有任何生产者结果可打包。' }

    # ---- 先判定落地名，再动手：全部判定都在任何写入之前完成 ---------------
    # **每个项目一个发布包，包内不带项目目录层。** archiveNaming.prefixes 是 项目 id → 包名前缀，
    # 所以同一次发布里每个项目都得到各不相同的名字，不会互相覆盖；包内就是该项目 outputDir 的
    # 内容本身（dll / 静态资源直接躺在包根），部署时不需要先剥掉一层目录。
    # 重复发布判定按项目做，suffix 作用于该项目自己的包：
    #   publish_v1.4.1.14.zip / publish_report_v1.4.1.14.zip / web_v1.4.1.14.zip / pda_v1.4.1.14.zip
    # PDA APK 不参与这套命名，仍原样复制进版本目录。
    $apkPlan = @()
    $plan = @()
    foreach ($item in $items) {
        $id = [string]$item.id
        $kind = [string]$item.kind
        Assert-SafePathSegment $id '项目 id'

        if ($kind -eq 'pda') {
            # PDA APK 不参与统一 ZIP 命名，也不参与 duplicateMode：文件名由 build-apk.ps1
            # 自带时间戳决定，且 PDA 版本号会重复出现，去掉时间戳会让两个不同的包互相覆盖。
            $name = [string]$item.artifactName
            if ([string]::IsNullOrWhiteSpace($name)) { throw "PDA 生产者结果缺少 artifactName：$id" }
            Assert-SafePathSegment $name 'APK 文件名'
            $apkPlan += [pscustomobject]@{ Id = $id; Name = $name; Target = (Join-Path $versionDir $name); Source = [string]$item.artifactPath }
            continue
        }

        $prefixProperty = $prefixes.PSObject.Properties[$id]
        if ($null -eq $prefixProperty -or [string]::IsNullOrWhiteSpace([string]$prefixProperty.Value)) {
            $known = @($prefixes.PSObject.Properties | ForEach-Object { $_.Name })
            throw "archiveNaming.prefixes 缺少项目 '$id' 的发布包前缀。已配置的项目：$($known -join '、')"
        }
        $prefix = [string]$prefixProperty.Value
        Assert-SafePathSegment $prefix "archiveNaming.prefixes.$id"
        $source = [string]$item.outputDir
        if ([string]::IsNullOrWhiteSpace($source)) { throw "生产者结果缺少 outputDir：$id" }

        # 命名规则与重复发布判定都走 lib 里的唯一实现，与预检报告展示的名字同源。
        # ItemDir 传版本目录本身：判定单位就是这个项目自己的包。
        $resolved = Resolve-ArtifactName -Pattern $pattern -Prefix $prefix -VersionLabel $VersionLabel -ItemDir $versionDir -DuplicateMode $mode -DuplicateSuffix $duplicateSuffix
        if ($resolved.IsDuplicate) {
            Write-Event 'artifact' 'duplicate' $id ("同版本包已存在，本次加批次时间戳：{0}" -f $resolved.Name)
        }
        # 变量名不能是 $target：PowerShell 变量名大小写不敏感，它会与本脚本的环境参数
        # $Target（test / production）是同一个变量，循环结束后 manifest 里的 target 字段
        # 就变成了最后一个发布包的路径（2026-09-23 实测）。与 $resultFilePath 同一类坑。
        $targetPath = Join-Path $versionDir $resolved.Name
        if (-not (Test-StrictlyWithin $targetPath $versionDir)) { throw "发布包落盘路径越界：$targetPath" }
        $plan += [pscustomobject]@{
            Id = $id; Kind = $kind; Name = $resolved.Name; Target = $targetPath
            Source = $source; Runtime = [string](Get-OptionalProperty $item 'runtime' '')
        }
    }

    # 前缀是**按项目**配的，配重了就会让两个项目写到同一个包名上互相覆盖。聚合模型下这是
    # 设计的必然（共享前缀），逐项目模型下它只可能是配置错误，所以在动手之前先拒绝。
    $collided = @($plan | Group-Object -Property Target | Where-Object { $_.Count -gt 1 })
    if ($collided.Count -gt 0) {
        throw ("archiveNaming.prefixes 配置重复，多个项目会写到同一个包名：{0}。每个项目的前缀必须唯一。" -f (($collided | ForEach-Object { $_.Name }) -join '、'))
    }
    foreach ($apkEntry in $apkPlan) {
        if (-not (Test-StrictlyWithin $apkEntry.Target $versionDir)) { throw "APK 落盘路径越界：$($apkEntry.Target)" }
    }

    # 要覆盖的目标必须都在预检清单里。少一个就说明它在预检之后才出现，中止。
    $confirmed = @($ConfirmedReplacements | ForEach-Object { [IO.Path]::GetFullPath($_) })
    foreach ($entry in @($plan) + @($apkPlan)) {
        if (-not (Test-Path -LiteralPath $entry.Target -PathType Leaf)) { continue }
        $full = [IO.Path]::GetFullPath($entry.Target)
        if ($confirmed -notcontains $full) {
            throw ("将要覆盖一个预检时并不存在的文件，已中止：{0}`n它在预检之后才出现，本次没有被确认覆盖。请重新预检。" -f $full)
        }
    }

    $results = @()

    # ---- 逐个项目压缩：直接以项目的 outputDir 为源目录 --------------------
    # 归档用单源目录形式（cwd = outputDir + `*`），所以归档条目就是该目录的相对路径，
    # 文件直接躺在包根，**不带 <项目 id>/ 这一层**。一个包只有一个源目录，也就不存在
    # 「多个源目录塌进同一个顶层目录」的问题——那正是聚合模型下必须先复制进族暂存目录的原因
    # （2026-09-23 实测：多源目录时 Bandizip 按源目录 basename 建顶层目录，而三个 dotnet
    # 生产者的 outputDir 都叫 publish，会互相覆盖）。逐项目模型下这层复制不再需要。
    foreach ($entry in $plan) {
        $stats = Get-SourceStats $entry.Source
        if (-not $stats.Exists -or $stats.Count -eq 0) {
            throw "源目录不存在或为空，拒绝打包：$($entry.Source)（项目 $($entry.Id)）"
        }
        # 陈旧产物闸门：单独重跑 package.ps1 时最可能踩到的坑，就是拿一个几天前的
        # 构建结果重新打包，出来一个"看起来是新版本号"的旧包。报错必须指名是哪个项目陈旧。
        if (-not $AllowStale -and $null -ne $stats.Newest -and $stats.Newest -lt (Get-Date).AddHours(-$staleHours)) {
            throw ("项目 {0} 的产物目录最新文件时间为 {1:o}，早于允许的 {2} 小时窗口，拒绝打包陈旧产物：{3}`n确实是刻意复用旧构建时，加 -AllowStale。" -f $entry.Id, $stats.Newest, $staleHours, $entry.Source)
        }

        if ($null -eq $bandizip) {
            $configured = [string](Get-OptionalProperty $config.packaging 'executable' '')
            $bandizip = Find-Tool $configured @('bz.exe', 'bz')
            if ($null -eq $bandizip) { throw "未找到 Bandizip：$(if ([string]::IsNullOrWhiteSpace($configured)) { 'bz.exe' } else { $configured })" }
        }
        $stagedPath = Join-Path $staging $entry.Name
        if (-not (Test-StrictlyWithin $stagedPath $staging)) { throw "暂存路径越界：$stagedPath" }
        $archiveStats = New-Archive $bandizip $stagedPath $entry.Source $entry.Id $entry.Runtime
        $bytes = $archiveStats.ArchiveBytes

        # 落盘：先建目录再 Move。每个项目只覆盖**它自己**的目标名，同版本目录里别的项目的包
        # 与 APK 不受影响（见 rules R7）。覆盖既有目标前已由 ConfirmedReplacements 闸门把关。
        New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
        if (Test-Path -LiteralPath $entry.Target -PathType Leaf) {
            Remove-Item -LiteralPath $entry.Target -Force
            Write-Event 'artifact' 'replaced' $entry.Id ("删除原产物 {0}" -f $entry.Target)
        }
        Move-Item -LiteralPath $stagedPath -Destination $entry.Target -Force
        Write-Event 'artifact' 'landed' $entry.Id ("{0}（{1} 字节）" -f $entry.Target, $bytes)
        $results += [ordered]@{ kind = 'zip'; id = $entry.Id; name = $entry.Name; path = $entry.Target; bytes = $bytes }
    }

    # ---- APK：原样复制，不聚合、不改名 ------------------------------------
    foreach ($entry in $apkPlan) {
        if (-not (Test-Path -LiteralPath $entry.Source -PathType Leaf)) { throw "APK 不存在：$($entry.Source)" }
        $stagedPath = Join-Path $staging $entry.Name
        if (-not (Test-StrictlyWithin $stagedPath $staging)) { throw "暂存路径越界：$stagedPath" }
        Copy-Item -LiteralPath $entry.Source -Destination $stagedPath -Force
        $bytes = (Get-Item -LiteralPath $stagedPath).Length
        Write-Event 'artifact' 'packaged' $entry.Id ("APK {0}，{1} 字节（未压缩）" -f $entry.Name, $bytes)

        New-Item -ItemType Directory -Force -Path $versionDir | Out-Null
        if (Test-Path -LiteralPath $entry.Target -PathType Leaf) {
            Remove-Item -LiteralPath $entry.Target -Force
            Write-Event 'artifact' 'replaced' $entry.Id ("删除原产物 {0}" -f $entry.Target)
        }
        Move-Item -LiteralPath $stagedPath -Destination $entry.Target -Force
        Write-Event 'artifact' 'landed' $entry.Id ("{0}（{1} 字节）" -f $entry.Target, $bytes)
        $results += [ordered]@{ kind = 'apk'; id = $entry.Id; name = $entry.Name; path = $entry.Target; bytes = $bytes }
    }

    # 只是清理中间目录：此时全部产物都已经搬出去了，删不掉（被别的进程占着）不该让
    # 一次已经落盘成功的发布报成失败。
    if (Test-Path -LiteralPath $staging -PathType Container) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $staging = $null

    # ---- 本次 run 的 manifest：落在运行目录，不进交付目录 -----------------
    # 版本目录只放要交付的东西（各项目的发布包 + APK）。manifest 属于 run state，跟着 runId 走：
    # 每次发布一个自己的文件，重复发布（suffix 累积多个包）不会互相覆盖，也不会把多个
    # 批次的信息混进一个文件。standalone 调用（未传 -LogPath）时按 outputRoot\<logs.dirName>\
    # <runId> 兜底，不新增第二套状态目录。
    $runDir = $null
    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $fallbackRunId = $RunId
        if ([string]::IsNullOrWhiteSpace($fallbackRunId)) { $fallbackRunId = Get-Date -Format 'yyyyMMdd-HHmmss' }
        $runDir = Join-Path (Join-Path $outputRoot ([string](Get-OptionalProperty $config.logs 'dirName' '_logs'))) $fallbackRunId
    } else {
        $runDir = Split-Path -Parent $LogPath
    }
    $manifestName = [string](Get-OptionalProperty $config.logs 'manifestFile' 'manifest.json')
    Assert-SafePathSegment $manifestName 'manifest 文件名'
    $statePath = Join-Path $runDir $manifestName
    if (-not (Test-StrictlyWithin $statePath $outputRoot)) { throw "manifest 落盘路径越界：$statePath" }

    # artifacts 只描述**最终交付物**（各项目的发布包 + APK），不再列生产者中间产物。
    $state = [ordered]@{
        version       = $VersionLabel
        target        = $Target
        createdAt     = (Get-Date).ToString('o')
        runId         = $RunId
        duplicateMode = $mode
        batchStamp    = $BatchStamp
        versionDir    = $versionDir
        artifacts     = $results
    }
    Write-JsonFile $statePath $state 6

    $payload = [ordered]@{ succeeded = $true; target = $Target; version = $VersionLabel; versionDir = $versionDir; duplicateMode = $mode; batchStamp = $BatchStamp; manifestPath = $statePath; items = $results }
    if (-not [string]::IsNullOrWhiteSpace($ResultFile)) { Write-JsonFile $ResultFile $payload 8 }
    if ($Json) { $payload | ConvertTo-Json -Depth 8 } else { Write-Output ($payload | ConvertTo-Json -Depth 8) }
    exit 0
} catch {
    # 暂存目录里只有本轮尚未落盘的中间产物，失败即弃；交付目录此时一定还没被改动过。
    if ($null -ne $staging -and (Test-Path -LiteralPath $staging -PathType Container)) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Event 'run' 'failed' 'package' $_.Exception.Message
    [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
    exit 1
}
