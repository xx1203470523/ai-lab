# 个人 /git 技能的合并请求查询脚本。
#
# 动作：
#   query 这对源/目标分支是否已经存在开启中的 MR
#   link  在 query 基础上，附上评审所需的证据（提交列表、diff 统计），
#         没有既有 MR 时给出拼好的「新建 MR」链接
#
# 本脚本刻意保持只读：绝不调用 glab mr create，也绝不更新 MR。
# 创建或更新合并请求是另一个需要显式请求并确认的动作。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('query', 'link')]
    [string]$Action,

    [string]$Source,
    [string]$Target,
    [string]$Root,
    [string]$OutputJson,
    [switch]$AllowFetch
)

$ErrorActionPreference = 'Continue'

$commonPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'git-common.ps1'
. $commonPath

Initialize-GitSkillEncoding

$commandsRun = New-Object System.Collections.Generic.List[object]
function Add-CommandRun {
    param($Result)
    if ($null -ne $Result) { $commandsRun.Add($Result) }
}

$actionName = "mr.$Action"

$repoInfo = Get-GitRepoRoot -StartPath $Root
Add-CommandRun $repoInfo.result
if (-not $repoInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'not-a-repository' `
        -Reason '当前目录不在任何 Git 工作树内。'
}
$repoRoot = $repoInfo.root

# ---------------------------------------------------------------------------
# 源分支与目标分支
# ---------------------------------------------------------------------------

$sourceBranch = $Source
if ([string]::IsNullOrWhiteSpace($sourceBranch)) {
    $branchInfo = Get-GitCurrentBranch -RepoRoot $repoRoot
    Add-CommandRun $branchInfo.result
    if ($branchInfo.detached) {
        Write-GitSkillBlocked -Action $actionName -ErrorCode 'detached-head' `
            -Reason 'HEAD 处于游离状态，且未传 -Source 分支。' `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }
    $sourceBranch = $branchInfo.branch
}
$sourceBranch = $sourceBranch.Trim()

$resolved = Resolve-GitTargetBranch -RepoRoot $repoRoot -Requested $Target
if (-not $resolved.ok) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'target-branch-unresolved' `
        -Reason $resolved.reason -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ requested = $Target; remoteCandidates = $resolved.candidates }) `
        -CommandsRun $commandsRun
}
$targetBranch = $resolved.branch

if ($sourceBranch -eq $targetBranch) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'source-equals-target' `
        -Reason "源分支与目标分支都是 $sourceBranch。" -RepoRoot $repoRoot -CommandsRun $commandsRun
}

# ---------------------------------------------------------------------------
# 远端身份
# ---------------------------------------------------------------------------

$remoteUrlInfo = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('remote', 'get-url', 'origin')
Add-CommandRun $remoteUrlInfo
$remoteUrl = if (@($remoteUrlInfo.stdout).Count -gt 0) { ([string]$remoteUrlInfo.stdout[0]).Trim() } else { $null }

if ([string]::IsNullOrWhiteSpace($remoteUrl)) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'no-origin-remote' `
        -Reason '未配置 origin 远端，无从查询。' -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$hostName = $null
$projectPath = $null
if ($remoteUrl -match '^(?:[a-z+]+://)?(?:[^@/]+@)?(?<host>[^:/]+)(?::\d+)?[/:](?<path>.+?)(?:\.git)?$') {
    $hostName = $Matches['host']
    $projectPath = $Matches['path'] -replace '\.git$', ''
}

$isGitLab = $false
if (-not [string]::IsNullOrWhiteSpace($hostName)) {
    $lower = $hostName.ToLowerInvariant()
    $isGitLab = ($lower -eq 'gitlab' -or $lower -eq 'gitlab.com' -or
        $lower.StartsWith('gitlab.') -or $lower.Contains('.gitlab.'))
}

if (-not $isGitLab) {
    # 非 GitLab 时明确降级报告，绝不编造 MR 链接；推送本身不受影响。
    Write-GitSkillResult -Result (New-GitSkillResult -Action $actionName -Status 'blocked' `
            -Reason "远端主机 $hostName 不是 GitLab，无法查询 MR。推送本身不受影响。" `
            -RepoRoot $repoRoot -ErrorCode 'not-gitlab' `
            -Data ([pscustomobject]@{ remoteUrl = $remoteUrl; host = $hostName; sourceBranch = $sourceBranch; targetBranch = $targetBranch }) `
            -CommandsRun $commandsRun) `
        -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# glab 查询
# ---------------------------------------------------------------------------

$glabAvailable = $null -ne (Get-Command -Name 'glab' -ErrorAction SilentlyContinue)
$existing = @()
$glabError = $null

if ($glabAvailable) {
    if ($AllowFetch) {
        $fetch = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('fetch', 'origin', $targetBranch) -TimeoutSeconds 180
        Add-CommandRun $fetch
    }

    # glab 是 Go/pflag，标志必须写字面量 kebab 形式，不能用 hashtable splatting。
    $list = Invoke-NativeCapture -FilePath 'glab' -Arguments @(
        'mr', 'list',
        '--source-branch', $sourceBranch,
        '--target-branch', $targetBranch,
        '--output', 'json'
    ) -TimeoutSeconds 120
    Add-CommandRun $list

    if ($list.exitCode -eq 0) {
        $raw = @($list.stdout) -join "`n"
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $parsed = $raw | ConvertFrom-Json
                foreach ($mr in @($parsed)) {
                    $existing += [pscustomobject]@{
                        iid          = $mr.iid
                        title        = $mr.title
                        state        = $mr.state
                        webUrl       = $mr.web_url
                        sourceBranch = $mr.source_branch
                        targetBranch = $mr.target_branch
                        draft        = $mr.draft
                    }
                }
            } catch {
                $glabError = "无法解析 glab 输出：$($_.Exception.Message)"
            }
        }
    } else {
        $glabError = (@($list.stderr) -join ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($glabError)) { $glabError = "glab 退出码 $($list.exitCode)" }
    }
} else {
    $glabError = 'glab 未安装或不在 PATH 中。'
}

$openExisting = @($existing | Where-Object { $_.state -eq 'opened' })

$webUrl = $null
if ($glabAvailable) {
    $repoView = Invoke-NativeCapture -FilePath 'glab' -Arguments @('repo', 'view', '--output', 'json') -TimeoutSeconds 60
    Add-CommandRun $repoView
    if ($repoView.exitCode -eq 0) {
        try {
            $view = (@($repoView.stdout) -join "`n") | ConvertFrom-Json
            $webUrl = $view.web_url
        } catch { }
    }
}

if ([string]::IsNullOrWhiteSpace($webUrl) -and $null -ne $hostName -and $null -ne $projectPath) {
    $webUrl = "https://$hostName/$projectPath"
}

# ---------------------------------------------------------------------------
# MR 正文所需的可证事实
# ---------------------------------------------------------------------------

$targetRef = "refs/remotes/origin/$targetBranch"
$commitLog = @()
$diffStat = @()
$commitsBehind = $null

$targetCheck = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref $targetRef
Add-CommandRun $targetCheck.result

if ($targetCheck.exists) {
    $log = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('log', '--oneline', '--no-merges', "$targetRef..HEAD")
    Add-CommandRun $log
    if ($log.exitCode -eq 0) { $commitLog = @($log.stdout) }

    $stat = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('diff', '--stat', "$targetRef...HEAD")
    Add-CommandRun $stat
    if ($stat.exitCode -eq 0) { $diffStat = @($stat.stdout) }

    $divergence = Get-GitAheadBehind -RepoRoot $repoRoot -Range "$targetRef...HEAD"
    Add-CommandRun $divergence.result
    if ($divergence.ok) { $commitsBehind = $divergence.left }
}

$createUrl = $null
if (-not [string]::IsNullOrWhiteSpace($webUrl)) {
    $encodedSource = [System.Uri]::EscapeDataString($sourceBranch)
    $encodedTarget = [System.Uri]::EscapeDataString($targetBranch)
    $createUrl = "$webUrl/-/merge_requests/new?merge_request%5Bsource_branch%5D=$encodedSource&merge_request%5Btarget_branch%5D=$encodedTarget"
}

$data = [pscustomobject]@{
    repoRoot            = $repoRoot
    remoteUrl           = $remoteUrl
    host                = $hostName
    projectPath         = $projectPath
    webUrl              = $webUrl
    sourceBranch        = $sourceBranch
    targetBranch        = $targetBranch
    targetResolvedBy    = $resolved.source
    glabAvailable       = $glabAvailable
    glabError           = $glabError
    existingMrCount     = $existing.Count
    existingOpenCount   = $openExisting.Count
    existingMrs         = @($existing)
    hasOpenMr           = ($openExisting.Count -gt 0)
    createUrl           = $createUrl
    commitCount         = $commitLog.Count
    commits             = $commitLog
    commitsBehindTarget = $commitsBehind
    diffStat            = $diffStat
    suggestedTitle      = $(if ($commitLog.Count -ge 1) { $commitLog[0] } else { $null })
}

if ($openExisting.Count -gt 0) {
    $reason = "已存在开启中的 MR（$sourceBranch -> $targetBranch）：$(@($openExisting | ForEach-Object { $_.webUrl }) -join ', ')。不要重复创建。"
    $status = 'ok'
} elseif (-not $glabAvailable -or -not [string]::IsNullOrWhiteSpace($glabError)) {
    $reason = "MR 查询已降级（$glabError）。推送本身不受影响，不得编造合并请求链接。"
    $status = 'blocked'
} else {
    $reason = "未找到 $sourceBranch -> $targetBranch 的开启中 MR，源分支领先 $($commitLog.Count) 个提交。"
    $status = 'ok'
}

$errorCode = if ($status -eq 'blocked') { 'mr-lookup-degraded' } else { $null }

Write-GitSkillResult -Result (New-GitSkillResult -Action $actionName -Status $status -Reason $reason `
        -RepoRoot $repoRoot -ErrorCode $errorCode -Data $data -CommandsRun $commandsRun) `
    -OutputJson $OutputJson
