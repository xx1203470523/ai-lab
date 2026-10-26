# publish-pdaweb.ps1 —— PDA Web（H5）生产者。
#
# 职责边界：只负责把 HBuilderX 的 web 发行产物落到 outputDir。
# **不走 PDA 的 build-apk.ps1**，也不得把 H5 逻辑塞进 wms-pda-release。
#
# 顺序约束（由编排层保证，这里只记录原因）：本项**必须排在任何 APK 构建之前**。
# H5 包会把 manifest.json 的 versionName 编进 __uniConfig.appVersion，而 APK 构建
# 第一步就自增 manifest.json。若 APK 先跑，H5 包内嵌的将是自增后的版本号。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$ProjectConfig,
    [Parameter(Mandatory = $true)][string]$ResultFile,
    [string[]]$Ids = @(),
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
$KnownItemFields = @('id', 'projectRoot', 'hbuilderxCli', 'manifestPath', 'backendConfigFile', 'outputDir', 'requiredEntries')
$Kind = 'pdaweb'

try {
    Initialize-RunLog -RunId $RunId -LogPath $LogPath -Json:$Json
    $config = Read-JsonFile $ProjectConfig
    if ($null -eq $config) { throw "项目配置不存在或不是合法 JSON：$ProjectConfig" }
    Assert-NoUnknownFields $config $KnownFields "projects/$Kind.json"
    Assert-RequiredFields $config @('projects') "projects/$Kind.json"
    if ([string]$config.kind -ne $Kind) { throw "projects/$Kind.json 的 kind 字段应为 $Kind，实际为 $($config.kind)。" }

    # 外层 @() 不可省：Split-List 无输入时返回空数组，跨函数边界会被解包成 $null
    # （详见 lib/common.ps1 里 Split-List 的注释）。
    $wanted = @(Split-List $Ids)
    $selected = @($config.projects)
    if (@($wanted).Count -gt 0) { $selected = @($config.projects | Where-Object { $wanted -contains [string]$_.id }) }

    $results = @()
    foreach ($project in $selected) {
        Assert-NoUnknownFields $project $KnownItemFields "projects/$Kind.json 的项目条目"
        Assert-RequiredFields $project @('id', 'projectRoot', 'hbuilderxCli', 'manifestPath', 'outputDir') "projects/$Kind.json 的项目条目"
        $id = [string]$project.id
        Assert-SafePathSegment $id 'pdaweb 项目 id'

        $projectRoot = Resolve-FullPath ([string]$project.projectRoot) $RepoRoot
        $cli = Resolve-FullPath ([string]$project.hbuilderxCli) $RepoRoot
        $manifestPath = Resolve-FullPath ([string]$project.manifestPath) $projectRoot
        $outputDir = Resolve-FullPath ([string]$project.outputDir) $projectRoot

        # hbuilderxCli 必须由配置给出绝对路径，**不走 PATH 查找**：cli.exe 不在 PATH 上，
        # $env:HBUILDERX_CLI 只存在于 build-apk.ps1 自己的进程里（它 dot-source 了被
        # gitignore 的 release/local.env.ps1）。通用的 cli.exe 名字还可能命中别的软件。
        if (-not (Test-Path -LiteralPath $cli -PathType Leaf)) { throw "HBuilderX CLI 不存在：$cli（配置项 projects/$Kind.json 的 hbuilderxCli）" }
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "PDA Web 必需文件不存在：$manifestPath" }
        if (-not (Test-StrictlyWithin $outputDir $projectRoot)) { throw "PDA Web 导出目录越界（必须严格位于 $projectRoot 之下）：$outputDir" }

        # cmd.exe 无法安全引用的字符必须在**构建前**暴露：真正的引用发生在进程捕获内部，
        # 那时 HBuilderX 可能已经跑完 4 分钟，而且导出目录已被清空重写。
        foreach ($guarded in @($projectRoot, $cli)) {
            if (-not (Test-CmdQuotable $guarded)) {
                throw "PDA Web 参数无法安全传给 cmd.exe（含 & | < > ^ % `" ! 之一）：$guarded"
            }
        }

        # HBuilderX 的 web 发行是**全量重建**：导出目录会被清空重写，其中手工放入的文件会丢失。
        # 该副作用发生在构建阶段、与是否复用版本号无关，已由编排层无条件列入 DestructiveActions。
        $buildStart = Get-Date
        Invoke-External $cli @('publish', 'web', '--project', $projectRoot) $projectRoot $id | Out-Null

        $stats = Get-SourceStats $outputDir
        if (-not $stats.Exists -or $stats.Count -eq 0) { throw "PDA Web 导出目录为空：$outputDir" }
        foreach ($entry in @([string[]](Get-OptionalProperty $project 'requiredEntries' @('index.html')))) {
            if (-not (Test-Path -LiteralPath (Join-Path $outputDir $entry) -PathType Leaf)) {
                throw "PDA Web 导出缺少 $entry：$outputDir"
            }
        }
        if (-not (Get-ChildItem -LiteralPath $outputDir -File -Recurse -Include '*.js')) { throw "PDA Web 导出缺少 JS 资源：$outputDir" }
        if (-not (Get-ChildItem -LiteralPath $outputDir -File -Recurse -Include '*.css')) { throw "PDA Web 导出缺少 CSS 资源：$outputDir" }
        # 标签必须是「H5 导出」，否则 H5 失败时会报出 APK 的措辞。
        $null = Assert-ExportFreshness $outputDir $buildStart 'H5 导出'

        $manifestVersion = $null
        try { $manifestVersion = [string](Read-JsonFile $manifestPath).versionName } catch { $manifestVersion = $null }

        Write-Event 'pdaweb-output' 'validated' $id ("H5 站点 {0} 个文件，{1} 字节，内嵌 manifest 版本 {2}" -f $stats.Count, $stats.Bytes, $manifestVersion)
        $results += [ordered]@{
            id                  = $id
            kind                = $Kind
            outputDir           = $outputDir
            manifestVersionName = $manifestVersion
            evidence            = [ordered]@{ files = $stats.Count; bytes = $stats.Bytes; newest = if ($null -ne $stats.Newest) { $stats.Newest.ToString('o') } else { $null } }
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
