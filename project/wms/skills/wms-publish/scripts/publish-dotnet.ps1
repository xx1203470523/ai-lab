# publish-dotnet.ps1 —— .NET 后端生产者。
#
# 职责边界：**只负责把 .csproj 变成 outputDir 里的东西**。
# 它不压缩、不落盘、不知道版本目录在哪、不碰输出根，也不删任何交付物。
# 归档与落盘是 package.ps1 的事。
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

$KnownFields = @('kind', 'projectRoot', 'configuration', 'framework', 'runtime', 'selfContained', 'projects')
$KnownItemFields = @('id', 'project', 'outputDir')
$Kind = 'dotnet'

try {
    Initialize-RunLog -RunId $RunId -LogPath $LogPath -Json:$Json
    $config = Read-JsonFile $ProjectConfig
    if ($null -eq $config) { throw "项目配置不存在或不是合法 JSON：$ProjectConfig" }
    Assert-NoUnknownFields $config $KnownFields "projects/$Kind.json"
    Assert-RequiredFields $config @('projectRoot', 'configuration', 'framework', 'runtime', 'projects') "projects/$Kind.json"
    if ([string]$config.kind -ne $Kind) { throw "projects/$Kind.json 的 kind 字段应为 $Kind，实际为 $($config.kind)。" }

    $projectRoot = Resolve-FullPath ([string]$config.projectRoot) $RepoRoot
    if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) { throw "后端项目根目录不存在：$projectRoot" }

    $configuration = [string]$config.configuration
    $framework = [string]$config.framework
    $runtime = [string]$config.runtime
    $selfContained = if ([bool]$config.selfContained) { 'true' } else { 'false' }

    $dotnet = Find-Tool '' @('dotnet')
    if ($null -eq $dotnet) { throw '未找到 dotnet。' }

    # 外层 @() 不可省：Split-List 无输入时返回空数组，跨函数边界会被解包成 $null
    # （详见 lib/common.ps1 里 Split-List 的注释）。
    $wanted = @(Split-List $Ids)
    $selected = @($config.projects)
    if (@($wanted).Count -gt 0) { $selected = @($config.projects | Where-Object { $wanted -contains [string]$_.id }) }

    $results = @()
    foreach ($project in $selected) {
        Assert-NoUnknownFields $project $KnownItemFields "projects/$Kind.json 的项目条目"
        Assert-RequiredFields $project @('id', 'project', 'outputDir') "projects/$Kind.json 的项目条目"
        $id = [string]$project.id
        Assert-SafePathSegment $id 'dotnet 项目 id'

        $projectPath = Resolve-FullPath ([string]$project.project) $projectRoot
        if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) { throw "后端项目文件不存在：$projectPath" }

        # outputDir 里的 {configuration} / {framework} 由本 kind 的顶层字段代入。
        # 这样「把 Release 改成 Debug」只改一处：写死的 publishDir 会变成
        # 「发布到 Debug、却去 Release 找产物，而且发布前还把 Release 目录清空」。
        $outputDirPattern = ([string]$project.outputDir).Replace('{configuration}', $configuration).Replace('{framework}', $framework)
        $outputDir = Resolve-FullPath $outputDirPattern $projectRoot

        # 递归删除前必须过这两道：严格在项目根之下，且不是项目根自己。
        # 这是全技能唯一的递归删除点，Phase 1 审计发现旧实现这里的守卫是缺的。
        if (-not (Test-StrictlyWithin $outputDir $projectRoot)) { throw "后端输出目录越界（必须严格位于 $projectRoot 之下）：$outputDir" }

        if (Test-Path -LiteralPath $outputDir) { Remove-Item -LiteralPath $outputDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

        Invoke-External $dotnet @('publish', $projectPath, '-c', $configuration, '-f', $framework, '-r', $runtime, '--self-contained', $selfContained, '--output', $outputDir) (Split-Path -Parent $projectPath) $id | Out-Null

        $stats = Get-SourceStats $outputDir
        if (-not $stats.Exists -or $stats.Count -eq 0) { throw "后端发布目录为空：$outputDir" }

        Write-Event 'dotnet-output' 'validated' $id ("发布目录 {0} 个文件，{1} 字节，runtime {2}" -f $stats.Count, $stats.Bytes, $runtime)
        $results += [ordered]@{
            id        = $id
            kind      = $Kind
            outputDir = $outputDir
            runtime   = $runtime
            evidence  = [ordered]@{ files = $stats.Count; bytes = $stats.Bytes; newest = if ($null -ne $stats.Newest) { $stats.Newest.ToString('o') } else { $null } }
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
