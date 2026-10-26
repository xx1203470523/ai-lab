# publish-pda.ps1 —— PDA APK 生产者。
#
# 职责边界：只负责调用 PDA 自己的权威发布脚本，并把它产出的**原始 APK**定位出来。
#
# 本项刻意**不参与**统一 ZIP 归档，也不参与 duplicateMode：
#   * APK 的文件名由 build-apk.ps1 自带时间戳决定，不含 vX.X.X.X 之外的可预测形态；
#   * PDA 版本号会重复出现（manifest.json 被回退时会重新产出同一个号），
#     去掉时间戳会让两个内容不同的包互相覆盖。
# 因此本脚本产出的是 artifactPath/artifactName，由 package.ps1 原样复制到落盘目录。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ProjectConfig,
    [Parameter(Mandatory = $true)][string]$ResultFile,
    [string[]]$Ids = @(),
    # 预检时算出的预期版本号（裸四段，如 1.4.2.0）。给出时会先与本次自算结果比对，
    # 不一致说明 manifest.json 在预检之后被改过，立刻停，不要先构建再失败。
    [string]$ExpectedVersion = '',
    [string]$LogPath = '',
    [string]$RunId = '',
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\exec.ps1')

$KnownFields = @('kind', 'projects')
$KnownItemFields = @('id', 'projectRoot', 'releaseScript', 'outputDir', 'expectedOutput', 'versionMarker', 'manifestPath', 'backendConfigFile')
$Kind = 'pda'
# manifest.json 的 versionName 是**裸四段**（1.4.1.14），不带 release.json 里的 v 前缀。
$BareVersionPattern = '^(\d+)\.(\d+)\.(\d+)\.(\d+)$'

function Read-PdaLandedVersion([string]$MarkerPath) {
    # version.txt 由 build-apk.ps1 的 [6/6] 写出：UTF-8 带 BOM、CRLF。
    # 必须 Trim()——带 BOM 时首段会读成 "﻿1.4.2.0"，比对必然不等。
    if ([string]::IsNullOrWhiteSpace($MarkerPath) -or -not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($MarkerPath)).Trim() } catch { return $null }
}

function Get-PdaExportDir([string]$PdaRoot, [string]$ManifestPath) {
    # HBuilderX 的导出根是 unpackage/resources/<appid>/www。appid 从 manifest.json 读，不硬编码。
    $appid = $null
    try { $appid = [string](Read-JsonFile $ManifestPath).appid } catch { $appid = $null }
    if ([string]::IsNullOrWhiteSpace($appid)) { throw "无法从 $ManifestPath 读取 appid，无法校验 PDA 导出是否刷新。" }
    return (Join-Path $PdaRoot ("unpackage\resources\$appid\www"))
}

function Test-ApkArtifact([string]$ApkPath) {
    if (-not (Test-Path -LiteralPath $ApkPath -PathType Leaf)) { throw "APK 不存在：$ApkPath" }
    $info = Get-Item -LiteralPath $ApkPath
    if ($info.Length -le 0) { throw "APK 为空：$ApkPath" }
    # Add-Type 必须写在**这个函数内部**：只在归档路径上加载过它的实现，遇到 -Only pda
    # （纯 APK 发布不走归档）时 ZipFile 类型不存在，校验会以「找不到类型」的措辞失败。
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ApkPath)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $entries = $names.Count
        foreach ($required in @('AndroidManifest.xml', 'classes.dex')) {
            if ($names -notcontains $required) { throw "APK 缺少必需条目 $required：$ApkPath" }
        }
    } finally { $zip.Dispose() }
    return [pscustomobject]@{ Bytes = $info.Length; Entries = $entries }
}

try {
    Initialize-RunLog -RunId $RunId -LogPath $LogPath -Json:$Json
    $config = Read-JsonFile $ProjectConfig
    if ($null -eq $config) { throw "项目配置不存在或不是合法 JSON：$ProjectConfig" }
    Assert-NoUnknownFields $config $KnownFields "projects/$Kind.json"
    Assert-RequiredFields $config @('projects') "projects/$Kind.json"
    if ([string]$config.kind -ne $Kind) { throw "projects/$Kind.json 的 kind 字段应为 $Kind，实际为 $($config.kind)。" }

    # 必须由 powershell.exe 子进程执行：build-apk.ps1 末尾是无条件 `exit 0`，
    # 进程内执行会让本脚本在那里静默终止并「报成功」，跳过后续全部校验。
    $powershellExe = Find-Tool '' @('powershell.exe')
    if ($null -eq $powershellExe) { throw '未找到 powershell.exe，无法以子进程方式调用 PDA 发布脚本。' }
    if (-not $powershellExe.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        throw "PDA 发布脚本必须由 powershell.exe 子进程执行，但解析结果不是可执行文件：$powershellExe"
    }

    # 外层 @() 不可省：Split-List 无输入时返回空数组，跨函数边界会被解包成 $null
    # （详见 lib/common.ps1 里 Split-List 的注释）。
    $wanted = @(Split-List $Ids)
    $selected = @($config.projects)
    if (@($wanted).Count -gt 0) { $selected = @($config.projects | Where-Object { $wanted -contains [string]$_.id }) }

    $results = @()
    foreach ($project in $selected) {
        Assert-NoUnknownFields $project $KnownItemFields "projects/$Kind.json 的项目条目"
        Assert-RequiredFields $project @('id', 'projectRoot', 'releaseScript', 'outputDir', 'expectedOutput', 'versionMarker', 'manifestPath') "projects/$Kind.json 的项目条目"
        $id = [string]$project.id
        Assert-SafePathSegment $id 'pda 项目 id'

        $pdaRoot = Resolve-FullPath ([string]$project.projectRoot) $RepoRoot
        $releaseScript = Resolve-FullPath ([string]$project.releaseScript) $pdaRoot
        $outputDir = Resolve-FullPath ([string]$project.outputDir) $pdaRoot
        $versionMarker = Resolve-FullPath ([string]$project.versionMarker) $pdaRoot
        $manifestPath = Resolve-FullPath ([string]$project.manifestPath) $pdaRoot

        if (-not (Test-Path -LiteralPath $releaseScript -PathType Leaf)) { throw "PDA 权威发布脚本不存在：$releaseScript" }
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "PDA manifest.json 不存在：$manifestPath" }
        if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) { throw "PDA 输出目录不存在：$outputDir" }
        # 三处路径都必须落在 PDA 项目根之内，否则一个写错的配置就能让构建脚本
        # 去改写仓库外的东西（build-apk.ps1 会写 manifest.json 与 build.gradle）。
        foreach ($guarded in @($outputDir, $versionMarker, $manifestPath)) {
            if (-not (Test-Within $guarded $pdaRoot)) { throw "PDA 路径越界（必须落在 $pdaRoot 内）：$guarded" }
        }
        foreach ($guarded in @($pdaRoot, $releaseScript)) {
            if (-not (Test-CmdQuotable $guarded)) {
                throw "PDA 参数无法安全传给 cmd.exe（含 & | < > ^ % `" ! 之一）：$guarded"
            }
        }

        # 预测版本必须在**构建前**读：build-apk.ps1 的 [1/6] 就自增并写回 manifest.json，
        # 之后再读只能读到自增后的值，比对就失去意义。
        $currentVersion = $null
        try { $currentVersion = [string](Read-JsonFile $manifestPath).versionName } catch { $currentVersion = $null }
        $currentTuple = Get-VersionTuple $currentVersion $BareVersionPattern
        if ($null -eq $currentTuple) {
            throw "PDA manifest.json 的 versionName '$currentVersion' 不是可解析的四段数字，无法预测本次产出版本：$manifestPath"
        }
        $predicted = Format-Version -Tuple (Get-NextVersionTuple $currentTuple) -Prefix ''
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVersion) -and $ExpectedVersion -ne $predicted) {
            throw "PDA 预期版本 $ExpectedVersion 与本次自算结果 $predicted 不一致：manifest.json 在预检之后被改动过，请重新预检。"
        }

        # 快照构建前的文件名：候选判定要排除既有文件，尤其是上一轮同名（同版本）的包。
        $before = @(Get-ChildItem -LiteralPath $outputDir -File | Select-Object -ExpandProperty Name)

        # 构建开始时间必须取在**启动之前**且与 CreationTime 同源比较。
        $buildStart = Get-Date
        Invoke-External $powershellExe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $releaseScript) $pdaRoot $id | Out-Null

        $apkVersion = Read-PdaLandedVersion $versionMarker
        if ([string]::IsNullOrWhiteSpace($apkVersion)) { throw "PDA 版本标记为空或不存在：$versionMarker" }
        if ($apkVersion -ne $predicted) {
            throw "PDA 实际产出版本 $apkVersion 与预测 $predicted 不一致：manifest.json 可能在构建过程中被改动，请重新预检。"
        }

        # 陈旧导出防护（核心）：这是唯一能拦住「HBuilderX 没真正导出却返回 0、复用上一轮
        # unpackage 资源」的手段。版本号比对拦不住——源 manifest 被回退过时，陈旧复用与
        # 真导出产出的 version.txt 可以完全相同（2026-09-18 实测二者都是 1.4.2.0）。
        $exportDir = Get-PdaExportDir $pdaRoot $manifestPath
        $null = Assert-ExportFreshness $exportDir $buildStart 'PDA 导出'

        # 候选必须同时满足四个条件，且要求**恰好一个**——禁止 Select-Object -First 1 兜底：
        # 兜底会在真的有歧义时静默挑一个，把「配置或构建脚本坏了」变成「发布了一个不知哪来的包」。
        # 「本次窗口」只能看 CreationTime：build-apk.ps1 用 Copy-Item 把 gradle 产物复制进
        # release/output（保留源文件 mtime），而 gradle 在输入未变时会把 packageRelease 判为
        # up-to-date、根本不重写 APK。2026-09-18 实测：新 APK 与上午那个包 sha256 完全相同、
        # LastWriteTime 停在上一次构建的 09:48:19，只有 CreationTime 是本次的 14:09:59；
        # 按 LastWriteTime 过滤会得到 0 个候选，把一个正确的包误判成失败。
        # 不叠加 LastWriteTime 兜底：候选由 Copy-Item 新建，CreationTime 必然 >= $buildStart，
        # 叠加只会扩大候选集，而判定要求「恰好一个」，扩大只会把正确的通过翻转成失败。
        # 若将来 build-apk.ps1 改用 Move-Item 落地（同卷改名会保留原 CreationTime），此处必须重新评估。
        $candidates = @(Get-ChildItem -LiteralPath $outputDir -File -Filter ([string]$project.expectedOutput) |
            Where-Object { $before -notcontains $_.Name } |
            Where-Object { $_.Name -like ('*_v' + $apkVersion + '_*') } |
            Where-Object { $_.CreationTime -ge $buildStart })
        if ($candidates.Count -ne 1) {
            throw ("PDA 产物定位失败：在 {0} 中匹配 {1} 且属于本次构建的文件有 {2} 个（应为恰好 1 个）：{3}" -f `
                $outputDir, [string]$project.expectedOutput, $candidates.Count, (($candidates | ForEach-Object { $_.Name }) -join '、'))
        }
        $apk = $candidates[0]
        $apkStats = Test-ApkArtifact $apk.FullName

        Write-Event 'pda-output' 'validated' $id ("APK {0}，{1} 字节，{2} 个归档条目，版本 {3}" -f $apk.Name, $apkStats.Bytes, $apkStats.Entries, $apkVersion)
        $results += [ordered]@{
            id           = $id
            kind         = $Kind
            artifactPath = $apk.FullName
            artifactName = $apk.Name
            apkVersion   = $apkVersion
            evidence     = [ordered]@{ files = 1; bytes = $apkStats.Bytes; entries = $apkStats.Entries; newest = $apk.CreationTime.ToString('o') }
        }
    }

    Write-JsonFile $ResultFile ([ordered]@{ succeeded = $true; kind = $Kind; items = $results }) 8
    if ($Json) { [ordered]@{ Status = 'succeeded'; Kind = $Kind; Items = @($results | ForEach-Object { $_.id }); ResultFile = $ResultFile } | ConvertTo-Json -Depth 6 }
    exit 0
} catch {
    Write-Event 'run' 'failed' $Kind $_.Exception.Message
    [Console]::Error.WriteLine('ERROR: ' + $_.Exception.Message)
    exit 1
}
