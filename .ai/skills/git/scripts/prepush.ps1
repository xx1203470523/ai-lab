# 个人 /git 技能推送前检查与变基脚本。
#
# 动作：
#   check  只读报告：分支守卫、目标分支、与远端的分叉、本地合并提交隐患、工作树状态
#   rebase 先跑同样的检查，再把当前分支变基到目标分支最新。冲突则中止并列出文件。
#
# 破坏性动作全部设了闸门：不能在受保护的集成分支上操作、工作树必须干净、
# 目标分支必须有依据地解析出来而不是靠猜。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('check', 'rebase')]
    [string]$Action,

    [string]$Target,
    [string]$Root,
    [string]$OutputJson,
    [switch]$AllowFetch,
    # 只放行「未跟踪文件」参与变基。已跟踪文件的改动一律照拦。
    # 未跟踪文件不进任何提交，变基不会丢它们；只有变基要写入同路径时 git 自己会拒绝。
    [switch]$AllowUntracked
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

$actionName = "prepush.$Action"

$repoInfo = Get-GitRepoRoot -StartPath $Root
Add-CommandRun $repoInfo.result
if (-not $repoInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'not-a-repository' `
        -Reason '当前目录不在任何 Git 工作树内。'
}
$repoRoot = $repoInfo.root

# ---------------------------------------------------------------------------
# 位置与分支守卫
# ---------------------------------------------------------------------------

$worktreeInfo = Get-GitWorktrees -RepoRoot $repoRoot
Add-CommandRun $worktreeInfo.result
if (-not $worktreeInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'worktree-list-failed' `
        -Reason 'git worktree list 执行失败。' -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$worktrees = @($worktreeInfo.worktrees)
$mainWorktree = Get-GitMainWorktree -Worktrees $worktrees

$currentDirectory = (Get-Location).Path
$currentWorktree = Get-GitCurrentWorktree -Worktrees $worktrees -CurrentDirectory $currentDirectory

$branchInfo = Get-GitCurrentBranch -RepoRoot $repoRoot
Add-CommandRun $branchInfo.result

if ($branchInfo.detached) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'detached-head' `
        -Reason 'HEAD 处于游离状态。推送或变基前请先切到工作分支。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$sourceBranch = $branchInfo.branch

if (Test-ProtectedBranch -Branch $sourceBranch) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'protected-branch' `
        -Reason "$sourceBranch 是受保护的集成分支，请改从特性分支提交并推送。" `
        -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ branch = $sourceBranch; mainWorktree = $mainWorktree.path }) `
        -CommandsRun $commandsRun
}

# 常驻规则 7：动历史之前先确认自己在哪个工作区。
$insideLinkedWorktree = ($null -ne $currentWorktree) -and (-not $currentWorktree.isMain)

# ---------------------------------------------------------------------------
# 目标分支
# ---------------------------------------------------------------------------

$resolved = Resolve-GitTargetBranch -RepoRoot $repoRoot -Requested $Target
if (-not $resolved.ok) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'target-branch-unresolved' `
        -Reason $resolved.reason -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{
                requested          = $Target
                remoteCandidates   = $resolved.candidates
                mainWorktree       = $mainWorktree.path
                mainWorktreeBranch = $mainWorktree.branch
            }) `
        -CommandsRun $commandsRun `
        -NextActions @('向用户确认要并入 main 还是 production，然后用 -Target <分支> 重跑。')
}

$targetBranch = $resolved.branch
$targetRef = "refs/remotes/origin/$targetBranch"

if ($sourceBranch -eq $targetBranch) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'source-equals-target' `
        -Reason "当前分支 $sourceBranch 就是目标分支本身，请先切到特性分支。" `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

# ---------------------------------------------------------------------------
# 拉取与分叉计算
# ---------------------------------------------------------------------------

$fetched = $false
if ($AllowFetch) {
    $fetch = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('fetch', 'origin', $targetBranch) -TimeoutSeconds 180
    Add-CommandRun $fetch
    if ($fetch.exitCode -ne 0) {
        Write-GitSkillBlocked -Action $actionName -ErrorCode 'fetch-failed' `
            -Reason "git fetch origin $targetBranch 失败：$(@($fetch.stderr) -join ' ')" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }
    $fetched = $true
}

$targetCheck = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref $targetRef
Add-CommandRun $targetCheck.result
if (-not $targetCheck.exists) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'remote-target-missing' `
        -Reason "远端引用 $targetRef 不存在，请加 -AllowFetch 重跑。" `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$divergence = Get-GitAheadBehind -RepoRoot $repoRoot -Range "$targetRef...HEAD"
Add-CommandRun $divergence.result

$behind = $(if ($divergence.ok) { $divergence.left } else { $null })
$ahead = $(if ($divergence.ok) { $divergence.right } else { $null })

# 常驻规则 9：本地集成分支若含合并提交，就不能作为变基基准，必须用远端引用。
$localTargetExists = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref "refs/heads/$targetBranch"
Add-CommandRun $localTargetExists.result

$localTargetMergeCommits = $null
if ($localTargetExists.exists) {
    $merges = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @(
        'rev-list', '--merges', '--count', "refs/heads/$targetBranch", '--not', $targetRef
    )
    Add-CommandRun $merges
    if ($merges.exitCode -eq 0 -and @($merges.stdout).Count -gt 0) {
        $localTargetMergeCommits = [int](([string]$merges.stdout[0]).Trim())
    }
}

# ---------------------------------------------------------------------------
# 工作树状态
# ---------------------------------------------------------------------------

$statusInfo = Get-GitStatusEntries -RepoRoot $repoRoot
Add-CommandRun $statusInfo.result
$entries = @($statusInfo.entries)

$unstagedTracked = @($entries | Where-Object { -not $_.isUntracked -and $_.xy[1] -ne ' ' })
$untracked = @($entries | Where-Object { $_.isUntracked })

# ---------------------------------------------------------------------------
# 源分支尚未推送的提交
# ---------------------------------------------------------------------------

$upstreamRef = "refs/remotes/origin/$sourceBranch"
$sourceUpstreamExists = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref $upstreamRef
Add-CommandRun $sourceUpstreamExists.result

$unpushedCommits = @()
if ($sourceUpstreamExists.exists) {
    $log = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @(
        'log', '--oneline', '--no-merges', "$upstreamRef..HEAD"
    )
    Add-CommandRun $log
    if ($log.exitCode -eq 0) { $unpushedCommits = @($log.stdout) }
}

$data = [pscustomobject]@{
    repoRoot                = $repoRoot
    currentPath             = $currentDirectory
    currentWorktree         = $(if ($null -eq $currentWorktree) { $null } else { $currentWorktree.path })
    insideLinkedWorktree    = $insideLinkedWorktree
    mainWorktree            = $mainWorktree.path
    mainWorktreeBranch      = $mainWorktree.branch
    sourceBranch            = $sourceBranch
    targetBranch            = $targetBranch
    targetResolvedBy        = $resolved.source
    targetRef               = $targetRef
    fetched                 = $fetched
    behindTarget            = $behind
    aheadOfTarget           = $ahead
    localTargetBranchExists = $localTargetExists.exists
    localTargetMergeCommits = $localTargetMergeCommits
    needsRebase             = ($null -ne $behind -and $behind -gt 0)
    changedFiles            = $entries.Count
    unstagedTrackedFiles    = $unstagedTracked.Count
    untrackedFiles          = $untracked.Count
    treeClean               = ($entries.Count -eq 0)
    sourceUpstreamExists    = $sourceUpstreamExists.exists
    unpushedCommits         = $unpushedCommits
    unpushedCount           = $unpushedCommits.Count
    # 只在 rebase 成功后回填。必须在这里先声明：StrictMode 2.0 下给 [pscustomobject]
    # 追加不存在的属性会抛异常。
    #
    # behindTarget / aheadOfTarget 是变基「之前」的值，属于触发依据；
    # 变基后的真实状态用带 AfterRebase 后缀的字段报告，别拿陈旧数字当结果。
    rebasedOnto              = $null
    headBefore               = $null
    headAfter                = $null
    behindTargetAfterRebase  = $null
    aheadOfTargetAfterRebase = $null
}

if ($Action -eq 'check') {
    $notes = New-Object System.Collections.Generic.List[string]
    if ($data.needsRebase) { $notes.Add("分支落后 $targetRef 共 $behind 个提交。") }
    if ($null -ne $localTargetMergeCommits -and $localTargetMergeCommits -gt 0) {
        $notes.Add("本地 $targetBranch 有 $localTargetMergeCommits 个远端没有的合并提交；变基必须以 $targetRef 为基准，不能用本地分支。")
    }
    if ($insideLinkedWorktree) { $notes.Add("当前位于链接工作区 $($currentWorktree.path)。") }
    if (-not $data.treeClean) {
        $trackedCount = @($entries | Where-Object { -not $_.isUntracked }).Count
        if ($trackedCount -gt 0) {
            $notes.Add("有 $trackedCount 个已跟踪文件存在未提交改动，变基会被拒绝。")
        } elseif ($AllowUntracked) {
            $notes.Add("有 $($entries.Count) 个未跟踪路径，已按 -AllowUntracked 放行。")
        } else {
            $notes.Add("有 $($entries.Count) 个未跟踪路径，变基会被拒绝（可加 -AllowUntracked 放行）。")
        }
    }

    $reason = if ($notes.Count -eq 0) { '未发现阻塞项。' } else { ($notes -join ' ') }

    $result = New-GitSkillResult -Action 'prepush.check' -Status 'ok' -Reason $reason `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# rebase
# ---------------------------------------------------------------------------

if (-not $statusInfo.ok) {
    Write-GitSkillFailure -Action 'prepush.rebase' -ErrorCode 'status-failed' `
        -Reason 'git status 执行失败；工作树状态未知，拒绝改写历史。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

# 已跟踪改动永远拦；未跟踪文件默认也拦，只有显式 -AllowUntracked 才放行。
$trackedDirty = @($entries | Where-Object { -not $_.isUntracked })
$dirtyBlocks = ($trackedDirty.Count -gt 0) -or ($untracked.Count -gt 0 -and -not $AllowUntracked)

if ($dirtyBlocks) {
    $sample = @($entries | Select-Object -First 20 | ForEach-Object { $_.path })
    Write-GitSkillBlocked -Action 'prepush.rebase' -ErrorCode 'dirty-tree' `
        -Reason "工作树有 $($entries.Count) 个改动路径。请先提交或妥善移走这些改动再变基。" `
        -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ changedFiles = $entries.Count; sample = $sample; unstagedTracked = $unstagedTracked.Count; untracked = $untracked.Count }) `
        -CommandsRun $commandsRun
}

if ($null -eq $behind -or $behind -eq 0) {
    $result = New-GitSkillResult -Action 'prepush.rebase' -Status 'ok' `
        -Reason "$sourceBranch 未落后于 $targetRef，无需变基。" `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

$headBefore = $null
$headInfo = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('rev-parse', 'HEAD')
Add-CommandRun $headInfo
if ($headInfo.exitCode -eq 0 -and @($headInfo.stdout).Count -gt 0) {
    $headBefore = ([string]$headInfo.stdout[0]).Trim()
}

$rebase = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('rebase', $targetRef) -TimeoutSeconds 300
Add-CommandRun $rebase

if ($rebase.exitCode -ne 0) {
    $conflictFiles = @()
    $conflicted = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('diff', '--name-only', '--diff-filter=U')
    Add-CommandRun $conflicted
    if ($conflicted.exitCode -eq 0) { $conflictFiles = @($conflicted.stdout) }

    if ($conflictFiles.Count -eq 0) {
        $statusAfter = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('status', '--porcelain=v1')
        Add-CommandRun $statusAfter
        $conflictFiles = @($statusAfter.stdout)
    }

    $abort = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('rebase', '--abort') -TimeoutSeconds 120
    Add-CommandRun $abort

    # 冲突不自行解决，也不退回用 merge 绕过——先把现场还原并交给用户。
    Write-GitSkillResult -Result (New-GitSkillResult -Action 'prepush.rebase' -Status 'blocked' `
            -Reason "变基到 $targetRef 时发生冲突，已中止并还原。请与用户确认后再处理，不要改用 merge 绕过。" `
            -RepoRoot $repoRoot -ErrorCode 'rebase-conflict' `
            -Data ([pscustomobject]@{
                    targetRef       = $targetRef
                    conflictedFiles = $conflictFiles
                    aborted         = ($abort.exitCode -eq 0)
                    rebaseStderr    = @($rebase.stderr)
                }) `
            -CommandsRun $commandsRun) `
        -OutputJson $OutputJson
}

$headAfter = $null
$headInfoAfter = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('rev-parse', 'HEAD')
Add-CommandRun $headInfoAfter
if ($headInfoAfter.exitCode -eq 0 -and @($headInfoAfter.stdout).Count -gt 0) {
    $headAfter = ([string]$headInfoAfter.stdout[0]).Trim()
}

$data.rebasedOnto = $targetRef
$data.headBefore = $headBefore
$data.headAfter = $headAfter

# 回读变基后的真实分叉状态。子进程退出后不复核，调用方就只能相信
# 「git rebase 退出码为 0」，而退出码为 0 不代表分叉数真的是 0。
$divergenceAfter = Get-GitAheadBehind -RepoRoot $repoRoot -Range "$targetRef...HEAD"
Add-CommandRun $divergenceAfter.result
if ($divergenceAfter.ok) {
    $data.behindTargetAfterRebase = $divergenceAfter.left
    $data.aheadOfTargetAfterRebase = $divergenceAfter.right
}

$result = New-GitSkillResult -Action 'prepush.rebase' -Status 'ok' `
    -Reason "$sourceBranch 已变基到 $targetRef（并入 $behind 个提交），变基后落后 $($data.behindTargetAfterRebase) 个提交。" `
    -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun
Write-GitSkillResult -Result $result -OutputJson $OutputJson
