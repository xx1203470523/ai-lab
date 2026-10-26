# publish-web.ps1 —— Web 前端生产者（pnpm + vite）。
#
# 职责边界：只负责把前端源码变成 outputDir（默认 dist）里的静态站点。
# 不压缩、不落盘、不知道版本目录在哪。
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
$KnownItemFields = @('id', 'projectRoot', 'buildCommand', 'mode', 'outputDir', 'requiredEntries')
$Kind = 'web'

try {
    Initialize-RunLog -RunId $RunId -LogPath $LogPath -Json:$Json
    $config = Read-JsonFile $ProjectConfig
    if ($null -eq $config) { throw "项目配置不存在或不是合法 JSON：$ProjectConfig" }
    Assert-NoUnknownFields $config $KnownFields "projects/$Kind.json"
    Assert-RequiredFields $config @('projects') "projects/$Kind.json"
    if ([string]$config.kind -ne $Kind) { throw "projects/$Kind.json 的 kind 字段应为 $Kind，实际为 $($config.kind)。" }

    # 优先 pnpm.cmd：pnpm.ps1 是同进程脚本，$LASTEXITCODE 会残留上一次命令的值，
    # 把构建失败误判成成功。
    $pnpm = Find-Tool '' @('pnpm.cmd', 'pnpm')
    if ($null -eq $pnpm) { throw '未找到 pnpm。' }

    # 外层 @() 不可省：Split-List 无输入时返回空数组，跨函数边界会被解包成 $null
    # （详见 lib/common.ps1 里 Split-List 的注释）。
    $wanted = @(Split-List $Ids)
    $selected = @($config.projects)
    if (@($wanted).Count -gt 0) { $selected = @($config.projects | Where-Object { $wanted -contains [string]$_.id }) }

    $results = @()
    foreach ($project in $selected) {
        Assert-NoUnknownFields $project $KnownItemFields "projects/$Kind.json 的项目条目"
        Assert-RequiredFields $project @('id', 'projectRoot') "projects/$Kind.json 的项目条目"
        $id = [string]$project.id
        Assert-SafePathSegment $id 'web 项目 id'

        $projectRoot = Resolve-FullPath ([string]$project.projectRoot) $RepoRoot
        if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'package.json') -PathType Leaf)) {
            throw "前端 package.json 不存在：$projectRoot"
        }

        $outputDirName = [string](Get-OptionalProperty $project 'outputDir' 'dist')
        $outputDir = Resolve-FullPath $outputDirName $projectRoot
        if (-not (Test-StrictlyWithin $outputDir $projectRoot)) { throw "前端输出目录越界（必须严格位于 $projectRoot 之下）：$outputDir" }

        # buildCommand 只写 pnpm 之后的参数，默认 build；兼容并剥离旧写法里的首项 pnpm。
        $buildArgs = @([string[]](Get-OptionalProperty $project 'buildCommand' @('build')))
        if ($buildArgs.Count -gt 0 -and $buildArgs[0] -eq 'pnpm') { $buildArgs = @($buildArgs | Select-Object -Skip 1) }
        $mode = [string](Get-OptionalProperty $project 'mode' '')
        if (-not [string]::IsNullOrWhiteSpace($mode) -and $buildArgs -notcontains '--mode') {
            $buildArgs += @('--mode', $mode)
        }

        Invoke-External $pnpm $buildArgs $projectRoot $id | Out-Null

        $stats = Get-SourceStats $outputDir
        if (-not $stats.Exists -or $stats.Count -eq 0) { throw "前端产物目录为空：$outputDir" }
        foreach ($entry in @([string[]](Get-OptionalProperty $project 'requiredEntries' @('index.html')))) {
            if (-not (Test-Path -LiteralPath (Join-Path $outputDir $entry) -PathType Leaf)) {
                throw "前端产物缺少 $entry：$outputDir"
            }
        }
        if (-not (Get-ChildItem -LiteralPath $outputDir -File -Recurse -Include '*.js')) { throw "前端产物缺少 JS 资源：$outputDir" }
        if (-not (Get-ChildItem -LiteralPath $outputDir -File -Recurse -Include '*.css')) { throw "前端产物缺少 CSS 资源：$outputDir" }

        $modeLabel = '(未指定)'
        if (-not [string]::IsNullOrWhiteSpace($mode)) { $modeLabel = $mode }
        Write-Event 'web-output' 'validated' $id ("静态站点 {0} 个文件，{1} 字节，mode {2}" -f $stats.Count, $stats.Bytes, $modeLabel)
        $results += [ordered]@{
            id        = $id
            kind      = $Kind
            outputDir = $outputDir
            mode      = $mode
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
