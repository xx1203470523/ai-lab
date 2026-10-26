# 个人 /git 技能的提交脚本。
#
# 动作：
#   plan   只读：列出将暂存哪些显式路径，以及消息文件会带来什么内容
#   commit 只暂存列出的路径并创建提交
#
# 提交信息一律从文件读取：PS 5.1 用 here-string 向原生进程传多行文本会被拆断。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('plan', 'commit')]
    [string]$Action,

    [string[]]$Path = @(),
    [string]$MessageFile,
    [string]$Root,
    [string]$OutputJson,
    [switch]$AllowNonConventional,
    [switch]$DryRun
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

$actionName = "commit.$Action"

$repoInfo = Get-GitRepoRoot -StartPath $Root
Add-CommandRun $repoInfo.result
if (-not $repoInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'not-a-repository' `
        -Reason '当前目录不在任何 Git 工作树内。'
}
$repoRoot = $repoInfo.root

# ---------------------------------------------------------------------------
# 路径清单守卫
# ---------------------------------------------------------------------------

if (@($Path).Count -eq 0) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'paths-required' `
        -Reason '缺少 -Path：请显式传入本次任务涉及的文件。本脚本不提供批量暂存。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

# powershell -File 模式下数组参数不会收集多个 token，`-Path a.txt,b.txt` 会作为
# 单个字符串进来；逗号、分号、换行都要当作分隔符再拆一次，否则多文件提交
# 会被静默当成一个不存在的路径。
$rawItems = New-Object System.Collections.Generic.List[string]
foreach ($item in @($Path)) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    foreach ($piece in ($item -split '[,;\r\n]')) {
        $trimmed = $piece.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $rawItems.Add($trimmed) }
    }
}

if ($rawItems.Count -eq 0) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'paths-required' `
        -Reason '拆分后的路径清单为空，没有可提交的内容。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$forbiddenSpecs = @('-A', '--all', '.', './', '*', '-u', '--update')
$rejected = @()
$requested = New-Object System.Collections.Generic.List[string]

foreach ($item in $rawItems.ToArray()) {
    $candidate = $item

    if ($forbiddenSpecs -contains $candidate) {
        $rejected += [pscustomobject]@{ path = $candidate; reason = '批量暂存写法，禁止' }
        continue
    }

    if ($candidate -match '[*?]') {
        $rejected += [pscustomobject]@{ path = $candidate; reason = '不允许通配符' }
        continue
    }

    $absolute = if ([System.IO.Path]::IsPathRooted($candidate)) {
        [System.IO.Path]::GetFullPath($candidate)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $candidate))
    }

    if (-not $absolute.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rejected += [pscustomobject]@{ path = $candidate; reason = '超出仓库范围' }
        continue
    }

    if ((Get-GitPathComparison -Left $absolute -Right $repoRoot)) {
        $rejected += [pscustomobject]@{ path = $candidate; reason = '指向仓库根目录' }
        continue
    }

    $requested.Add($candidate)
}

if ($rejected.Count -gt 0) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'invalid-path-specifier' `
        -Reason '路径清单里含有批量或越界写法，请逐个列出文件。' `
        -RepoRoot $repoRoot -Data ([pscustomobject]@{ rejected = $rejected }) -CommandsRun $commandsRun
}

# ---------------------------------------------------------------------------
# 与工作树实际状态交叉核对
# ---------------------------------------------------------------------------

$statusInfo = Get-GitStatusEntries -RepoRoot $repoRoot
Add-CommandRun $statusInfo.result
if (-not $statusInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'status-failed' `
        -Reason 'git status 执行失败。' -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$entries = @($statusInfo.entries)
$changedPaths = @{}
foreach ($entry in $entries) {
    $full = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $entry.path))
    $changedPaths[$full.ToLowerInvariant()] = $entry
    if ($null -ne $entry.originalPath) {
        $orig = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $entry.originalPath))
        $changedPaths[$orig.ToLowerInvariant()] = $entry
    }
}

$resolved = New-Object System.Collections.Generic.List[object]
$unknown = @()

foreach ($item in @($requested.ToArray())) {
    $absolute = if ([System.IO.Path]::IsPathRooted($item)) {
        [System.IO.Path]::GetFullPath($item)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $item))
    }

    $key = $absolute.ToLowerInvariant()
    if ($changedPaths.ContainsKey($key)) {
        $resolved.Add([pscustomobject]@{
            requested = $item
            path      = $changedPaths[$key].path
            xy        = $changedPaths[$key].xy
        })
    } else {
        $unknown += $item
    }
}

if ($unknown.Count -gt 0) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'path-not-changed' `
        -Reason '有路径没有待提交的改动，不属于本次提交范围。' `
        -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ unknown = $unknown; changedFileCount = $entries.Count }) `
        -CommandsRun $commandsRun
}

# ---------------------------------------------------------------------------
# 提交信息守卫
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($MessageFile)) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'message-file-required' `
        -Reason '缺少 -MessageFile：请指向一个存有提交信息的 UTF-8 文件。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

if (-not (Test-Path -LiteralPath $MessageFile -PathType Leaf)) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'message-file-missing' `
        -Reason "提交信息文件 $MessageFile 不存在。" -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$messageText = [System.IO.File]::ReadAllText($MessageFile, [System.Text.Encoding]::UTF8)
$messageText = $messageText.TrimStart([char]0xFEFF)
$messageLines = @($messageText -split "\r?\n")
$subject = if ($messageLines.Count -gt 0) { $messageLines[0].Trim() } else { '' }

if ([string]::IsNullOrWhiteSpace($subject)) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'empty-message' `
        -Reason '提交信息是空的。' -RepoRoot $repoRoot -CommandsRun $commandsRun
}

# 硬拦截：本仓库历史里存在他人带署名行的提交，用户明确不要在自己提交里出现。
$attributionFound = @($messageLines | Where-Object { $_ -match '^\s*Co-Authored-By:' })
$generatedFound = @($messageLines | Where-Object { $_ -match 'Generated with \[?Claude Code' })
if ($attributionFound.Count -gt 0 -or $generatedFound.Count -gt 0) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'attribution-line-forbidden' `
        -Reason '提交信息里带有 Co-Authored-By 或 generated-with 署名行，请先删除再提交。' `
        -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ offendingLines = @($attributionFound + $generatedFound) }) `
        -CommandsRun $commandsRun
}

$conventionalPattern = '^(feat|fix|chore|refactor|docs|test|style|perf|build|ci|revert|merge)(\([^)]+\))?!?:\s*\S+'
$isConventional = ($subject -match $conventionalPattern)

if (-not $isConventional -and -not $AllowNonConventional) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'non-conventional-subject' `
        -Reason "标题「$subject」不符合 <type>(<scope>): <简述> 格式。请修正，或确实有意为例外时加 -AllowNonConventional。" `
        -RepoRoot $repoRoot -Data ([pscustomobject]@{ subject = $subject }) -CommandsRun $commandsRun
}

$existingStaged = @($entries | Where-Object { $_.isStaged })

$plan = [pscustomobject]@{
    repoRoot            = $repoRoot
    subject             = $subject
    messageFile         = $MessageFile
    messageLines        = $messageLines.Count
    stagedPaths         = @($resolved | ForEach-Object { $_.path })
    stagedCount         = $resolved.Count
    conventional        = $isConventional
    existingStaged      = @($existingStaged | ForEach-Object { $_.path })
    existingStagedCount = $existingStaged.Count
}

if ($Action -eq 'plan' -or $DryRun) {
    $reason = "将暂存 $($resolved.Count) 个路径，并以标题「$subject」提交。"
    if ($plan.existingStagedCount -gt 0) {
        $reason += " 注意：已有 $($plan.existingStagedCount) 个路径在此前被暂存，会一并进入本次提交。"
    }
    $result = New-GitSkillResult -Action 'commit.plan' -Status 'ok' -Reason $reason `
        -RepoRoot $repoRoot -Data $plan -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# 暂存并提交
# ---------------------------------------------------------------------------

$stageArgs = @('add', '--') + @($resolved | ForEach-Object { $_.path })
$stage = Invoke-GitCommand -RepoRoot $repoRoot -Arguments $stageArgs
Add-CommandRun $stage
if ($stage.exitCode -ne 0) {
    Write-GitSkillFailure -Action 'commit.commit' -ErrorCode 'git-add-failed' `
        -Reason "git add 失败：$(@($stage.stderr) -join ' ')" -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$stagedAfter = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('diff', '--cached', '--name-only')
Add-CommandRun $stagedAfter
$stagedFiles = @($stagedAfter.stdout)

if ($stagedFiles.Count -eq 0) {
    Write-GitSkillBlocked -Action 'commit.commit' -ErrorCode 'nothing-staged' `
        -Reason '加入列出的路径后暂存区仍为空，没有可提交的内容。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$commit = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('commit', '-F', $MessageFile) -TimeoutSeconds 180
Add-CommandRun $commit
if ($commit.exitCode -ne 0) {
    $detail = (@($commit.stdout) + @($commit.stderr)) -join ' '
    Write-GitSkillFailure -Action 'commit.commit' -ErrorCode 'git-commit-failed' `
        -Reason "git commit 失败：$detail" -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$headInfo = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('rev-parse', 'HEAD')
Add-CommandRun $headInfo
$head = if (@($headInfo.stdout).Count -gt 0) { ([string]$headInfo.stdout[0]).Trim() } else { $null }

$data = [pscustomobject]@{
    commit       = $head
    subject      = $subject
    stagedPaths  = $stagedFiles
    stagedCount  = $stagedFiles.Count
    messageFile  = $MessageFile
    conventional = $isConventional
}

$result = New-GitSkillResult -Action 'commit.commit' -Status 'ok' `
    -Reason "已提交 $($stagedFiles.Count) 个路径，提交号 $head。" `
    -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun
Write-GitSkillResult -Result $result -OutputJson $OutputJson
