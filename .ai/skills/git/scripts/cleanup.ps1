# 个人 /git 技能的工作区与分支清理脚本。
#
# 动作：
#   plan  只读预检。逐一给出「可删 / 需保留」判定及依据，并返回一个确认令牌。
#   apply 只有带上 plan 返回的令牌才执行；执行前重新校验目标状态，状态变了就拒绝。
#   prune 清掉 git 登记但目录已不存在的工作区记录
#
# 分两阶段是因为删除不可逆，而判定依据（是否已合并、有无未提交改动）会随别人推送改变，
# 用户确认必须发生在看到真实清单之后。

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('plan', 'apply', 'prune')]
    [string]$Action,

    [string]$Name,
    [string]$Target,
    [string]$ConfirmToken,
    [string]$Root,
    [string]$OutputJson,
    [switch]$AllowFetch,
    # 只放行「未跟踪文件」。已跟踪文件的改动永远拦着，不受这个开关影响。
    # 未跟踪文件不属于任何提交，删除工作区不会丢历史，但会丢内容，所以必须显式开。
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

$actionName = "cleanup.$Action"

$repoInfo = Get-GitRepoRoot -StartPath $Root
Add-CommandRun $repoInfo.result
if (-not $repoInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'not-a-repository' `
        -Reason '当前目录不在任何 Git 工作树内。'
}
$repoRoot = $repoInfo.root

$worktreeInfo = Get-GitWorktrees -RepoRoot $repoRoot
Add-CommandRun $worktreeInfo.result
if (-not $worktreeInfo.ok) {
    Write-GitSkillFailure -Action $actionName -ErrorCode 'worktree-list-failed' `
        -Reason 'git worktree list 执行失败。' -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$worktrees = @($worktreeInfo.worktrees)

$currentDirectory = (Get-Location).Path

# ---------------------------------------------------------------------------
# prune：清掉 git 登记但目录已不存在的工作区记录
# ---------------------------------------------------------------------------

if ($Action -eq 'prune') {
    $stale = @($worktrees | Where-Object { -not (Test-Path -LiteralPath $_.path) })
    if ($stale.Count -eq 0) {
        $result = New-GitSkillResult -Action 'cleanup.prune' -Status 'ok' `
            -Reason '没有需要清理的失效工作区登记。' -RepoRoot $repoRoot -CommandsRun $commandsRun
        Write-GitSkillResult -Result $result -OutputJson $OutputJson
    }

    $prune = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('worktree', 'prune')
    Add-CommandRun $prune
    if ($prune.exitCode -ne 0) {
        Write-GitSkillFailure -Action 'cleanup.prune' -ErrorCode 'prune-failed' `
            -Reason "git worktree prune 失败：$(@($prune.stderr) -join ' ')" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    $result = New-GitSkillResult -Action 'cleanup.prune' -Status 'ok' `
        -Reason "已清理 $($stale.Count) 条失效工作区登记。" -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ pruned = @($stale | ForEach-Object { $_.path }) }) `
        -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# 目标分支
# ---------------------------------------------------------------------------

$resolved = Resolve-GitTargetBranch -RepoRoot $repoRoot -Requested $Target
if (-not $resolved.ok) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'target-branch-unresolved' `
        -Reason $resolved.reason -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ requested = $Target; remoteCandidates = $resolved.candidates }) `
        -CommandsRun $commandsRun
}
$targetBranch = $resolved.branch
$targetRef = "refs/remotes/origin/$targetBranch"

if ($AllowFetch) {
    $fetch = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('fetch', 'origin', $targetBranch, '--prune') -TimeoutSeconds 180
    Add-CommandRun $fetch
    if ($fetch.exitCode -ne 0) {
        Write-GitSkillBlocked -Action $actionName -ErrorCode 'fetch-failed' `
            -Reason "git fetch origin $targetBranch --prune 失败：$(@($fetch.stderr) -join ' ')" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }
}

$targetCheck = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref $targetRef
Add-CommandRun $targetCheck.result
if (-not $targetCheck.exists) {
    Write-GitSkillBlocked -Action $actionName -ErrorCode 'remote-target-missing' `
        -Reason "远端引用 $targetRef 不存在，无法判断是否已合并。请加 -AllowFetch。" `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

# ---------------------------------------------------------------------------
# glab MR 状态（用于识别 squash 合并这类「提交不在目标分支但内容已并入」的情况）
# ---------------------------------------------------------------------------

$glabAvailable = $null -ne (Get-Command -Name 'glab' -ErrorAction SilentlyContinue)
$mrStateByBranch = @{}

if ($glabAvailable) {
    $list = Invoke-NativeCapture -FilePath 'glab' -Arguments @(
        'mr', 'list', '--target-branch', $targetBranch, '--output', 'json', '--per-page', '100'
    ) -TimeoutSeconds 120
    Add-CommandRun $list

    if ($list.exitCode -eq 0) {
        try {
            $parsed = (@($list.stdout) -join "`n") | ConvertFrom-Json
            foreach ($mr in @($parsed)) {
                if (-not [string]::IsNullOrWhiteSpace($mr.source_branch)) {
                    $mrStateByBranch[$mr.source_branch] = [pscustomobject]@{
                        state  = $mr.state
                        webUrl = $mr.web_url
                        iid    = $mr.iid
                    }
                }
            }
        } catch { }
    }
}

# ---------------------------------------------------------------------------
# 逐个候选做预检
# ---------------------------------------------------------------------------

$candidates = @()
if (-not [string]::IsNullOrWhiteSpace($Name)) {
    $needle = $Name.Trim()
    $found = Find-GitWorktreeByName -Worktrees $worktrees -Name $needle
    $candidates = @($found.matches)

    if ($candidates.Count -eq 0) {
        Write-GitSkillBlocked -Action $actionName -ErrorCode 'worktree-not-found' `
            -Reason "没有匹配 $needle 的工作区。" -RepoRoot $repoRoot `
            -Data ([pscustomobject]@{
                    requested = $needle
                    available = @($worktrees | Where-Object { -not $_.isMain } | ForEach-Object { Split-Path -Leaf $_.path })
                }) `
            -CommandsRun $commandsRun
    }
} else {
    # 未指定名称时，把主工作目录之外的全部工作区作为候选逐一给出结论。
    $candidates = @($worktrees | Where-Object { -not $_.isMain })
}

$assessments = New-Object System.Collections.Generic.List[object]

foreach ($worktree in $candidates) {
    $blockers = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    $exists = Test-Path -LiteralPath $worktree.path
    $branch = $worktree.branch

    if ($worktree.isMain) {
        $blockers.Add('这是主工作目录，永不清理。')
    }

    if (-not $exists) {
        $notes.Add('目录已不存在，只需执行 cleanup.prune 清掉 git 登记。')
    }

    $insideThisWorktree = $currentDirectory.StartsWith($worktree.path, [System.StringComparison]::OrdinalIgnoreCase)
    if ($insideThisWorktree) {
        $blockers.Add('当前会话就在这个工作区里，先切回主工作目录再执行。')
    }

    # --- 未提交改动 -------------------------------------------------------
    $dirtyEntries = @()
    if ($exists) {
        $status = Get-GitStatusEntries -RepoRoot $worktree.path
        if ($status.ok) {
            $dirtyEntries = @($status.entries)
        } else {
            $blockers.Add('git status 读取失败，无法确认是否还有未提交改动。')
        }
    }

    # 未跟踪文件不属于任何提交：默认仍然拦（删除会丢内容），但可以用
    # -AllowUntracked 显式放行；已跟踪文件的改动无论如何都拦。
    $trackedDirty = @($dirtyEntries | Where-Object { -not $_.isUntracked })
    $untrackedDirty = @($dirtyEntries | Where-Object { $_.isUntracked })

    if ($trackedDirty.Count -gt 0) {
        $blockers.Add("存在 $($trackedDirty.Count) 个未提交的已跟踪改动，删除会丢失。")
    }

    if ($untrackedDirty.Count -gt 0) {
        if ($AllowUntracked) {
            $notes.Add("将一并删除 $($untrackedDirty.Count) 个未跟踪路径。")
        } else {
            $blockers.Add("存在 $($untrackedDirty.Count) 个未跟踪路径，删除会丢失；确认可丢弃时加 -AllowUntracked。")
        }
    }

    # --- 未推送提交 -------------------------------------------------------
    # 这里必须在该工作区自己的目录里跑：裸 HEAD 在仓库根取到的是主工作目录的
    # HEAD，会把 main 的未推送提交算到每个候选头上（2026-10-21 实测过）。
    $headScope = if ($exists) { $worktree.path } else { $repoRoot }
    $unpushed = @()
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
        $upstreamRef = "refs/remotes/origin/$branch"
        $upstreamExists = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref $upstreamRef
        if ($upstreamExists.exists) {
            $log = Invoke-GitCommand -RepoRoot $headScope -Arguments @('log', '--oneline', '--no-merges', "$upstreamRef..HEAD")
            Add-CommandRun $log
            if ($log.exitCode -eq 0) { $unpushed = @($log.stdout) }
        } else {
            $all = Invoke-GitCommand -RepoRoot $headScope -Arguments @('log', '--oneline', '--no-merges', 'HEAD', '--not', $targetRef)
            Add-CommandRun $all
            if ($all.exitCode -eq 0) { $unpushed = @($all.stdout) }
            if ($unpushed.Count -gt 0) {
                $notes.Add("分支从未推送到远端，且有 $($unpushed.Count) 个提交不在目标分支上。")
            }
        }
    }

    if ($unpushed.Count -gt 0) {
        $blockers.Add("有 $($unpushed.Count) 个提交未推送到 origin/$branch。")
    }

    # --- 是否已合并 -------------------------------------------------------
    $mergedVerdict = 'unknown'
    $mergedEvidence = ''
    $commitsNotInTarget = $null

    if (-not [string]::IsNullOrWhiteSpace($branch) -and -not $worktree.detached) {
        $countResult = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('rev-list', '--count', "$targetRef..$branch")
        Add-CommandRun $countResult

        if ($countResult.exitCode -eq 0 -and @($countResult.stdout).Count -gt 0) {
            $commitsNotInTarget = [int](([string]$countResult.stdout[0]).Trim())

            if ($commitsNotInTarget -eq 0) {
                $mergedVerdict = 'merged'
                $mergedEvidence = "git rev-list --count $targetRef..$branch 为 0。"
            } else {
                # 提交不在目标分支上，也可能是 squash 合并。只有 MR 状态能证明。
                $mr = $null
                if ($mrStateByBranch.ContainsKey($branch)) { $mr = $mrStateByBranch[$branch] }

                if ($null -ne $mr -and $mr.state -eq 'merged') {
                    $mergedVerdict = 'merged-squashed'
                    $mergedEvidence = "MR !$($mr.iid) 状态为 merged，内容已并入 $targetBranch（压缩合并）。"
                } elseif ($null -ne $mr) {
                    $mergedVerdict = 'not-merged'
                    $mergedEvidence = "MR !$($mr.iid) 状态为 $($mr.state)。"
                } else {
                    $mergedVerdict = 'unknown'
                    $mergedEvidence = "有 $commitsNotInTarget 个提交不在 $targetRef 上，且查不到对应 MR 状态，无法确认是否已合并。"
                }
            }
        } else {
            $mergedEvidence = '计算与目标分支差异失败。'
        }
    } else {
        $mergedEvidence = '游离头指针或分支名未知，无法判断合并状态。'
    }

    if ($mergedVerdict -ne 'merged' -and $mergedVerdict -ne 'merged-squashed') {
        if ($mergedVerdict -eq 'not-merged') {
            $blockers.Add("分支 $branch 尚未并入 $targetBranch。")
        } else {
            $blockers.Add("分支 $branch 的合并状态无法确认，按规则不得删除。")
        }
    }

    $deletable = ($blockers.Count -eq 0)

    $assessments.Add([pscustomobject]@{
        name              = (Split-Path -Leaf $worktree.path)
        path              = $worktree.path
        branch            = $branch
        head              = $worktree.head
        exists            = $exists
        isMain            = $worktree.isMain
        mergedVerdict     = $mergedVerdict
        mergedEvidence    = $mergedEvidence
        commitsNotInTarget = $commitsNotInTarget
        changedFiles      = $dirtyEntries.Count
        trackedChangedFiles = $trackedDirty.Count
        untrackedFiles    = $untrackedDirty.Count
        # git worktree remove 遇到未跟踪文件同样会拒绝，只有这类可删项才需要 --force。
        # 已跟踪改动永远进不了可删清单，所以 --force 不会被用来丢弃已跟踪改动。
        needsForce        = ($untrackedDirty.Count -gt 0)
        changedSample     = @($dirtyEntries | Select-Object -First 10 | ForEach-Object { $_.path })
        unpushedCount     = $unpushed.Count
        unpushedSample    = @($unpushed | Select-Object -First 10)
        deletable         = $deletable
        blockers          = @($blockers)
        notes             = @($notes)
    })
}

$deletableItems = @($assessments | Where-Object { $_.deletable })
$blockedItems = @($assessments | Where-Object { -not $_.deletable })

# 令牌只由「本次校验到的真实状态」派生。执行阶段重算，不一致就说明
# 期间有人推了代码或改了文件，必须重新确认。
$tokenSource = (@($assessments | ForEach-Object {
            "$($_.path)|$($_.branch)|$($_.head)|$($_.mergedVerdict)|$($_.changedFiles)|$($_.unpushedCount)"
        }) -join "`n") + "`n$targetRef|AllowUntracked=$([bool]$AllowUntracked)"
$sha = [System.Security.Cryptography.SHA256]::Create()
$tokenBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($tokenSource))
$token = (@($tokenBytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 16)

# ---------------------------------------------------------------------------
# plan
# ---------------------------------------------------------------------------

if ($Action -eq 'plan') {
    $commands = @($deletableItems | ForEach-Object {
            $forceFlag = if ($_.needsForce) { ' --force' } else { '' }
            "git -C '$repoRoot' worktree remove$forceFlag '$($_.path)'"
            if (-not $_.isMain -and -not [string]::IsNullOrWhiteSpace($_.branch)) {
                "git -C '$repoRoot' branch -d '$($_.branch)'"
            }
        })

    $data = [pscustomobject]@{
        repoRoot       = $repoRoot
        targetBranch   = $targetBranch
        targetRef      = $targetRef
        glabAvailable  = $glabAvailable
        confirmToken   = $token
        candidateCount = $assessments.Count
        deletableCount = $deletableItems.Count
        blockedCount   = $blockedItems.Count
        deletable      = @($deletableItems)
        blocked        = @($blockedItems)
        plannedCommands = $commands
    }

    $reason = "预检完成：$($deletableItems.Count) 个可清理，$($blockedItems.Count) 个需保留。确认后带 -ConfirmToken $token 执行。"

    $result = New-GitSkillResult -Action 'cleanup.plan' -Status 'ok' -Reason $reason `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun `
        -NextActions @(
            '把 deletable 与 blocked 两份清单完整展示给用户，等待明确确认；不要代为确认。',
            "用户确认后执行：cleanup.ps1 -Action apply -ConfirmToken $token"
        )
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ConfirmToken)) {
    Write-GitSkillBlocked -Action 'cleanup.apply' -ErrorCode 'confirm-token-required' `
        -Reason '缺少 -ConfirmToken。必须先跑 cleanup.ps1 -Action plan，把清单展示给用户并取得确认。' `
        -RepoRoot $repoRoot -CommandsRun $commandsRun
}

if ($ConfirmToken.Trim() -ne $token) {
    Write-GitSkillBlocked -Action 'cleanup.apply' -ErrorCode 'state-changed-since-plan' `
        -Reason '自预检以来工作区或分支状态已变化（可能有人推送或改动了文件）。请重新跑 plan 并向用户再次确认。' `
        -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ currentToken = $token; assessments = $assessments.ToArray() }) `
        -CommandsRun $commandsRun
}

if ($deletableItems.Count -eq 0) {
    $result = New-GitSkillResult -Action 'cleanup.apply' -Status 'ok' `
        -Reason '没有可清理的目标，未做任何改动。' -RepoRoot $repoRoot `
        -Data ([pscustomobject]@{ blocked = @($blockedItems) }) -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

$removed = New-Object System.Collections.Generic.List[object]
$failed = New-Object System.Collections.Generic.List[object]

foreach ($item in $deletableItems) {
    if (-not $item.exists) {
        # 目录已不在，只需清登记，交给 cleanup.prune。
        $failed.Add([pscustomobject]@{ path = $item.path; stage = 'worktree-remove'; error = '目录已不存在，请改用 cleanup.prune 清理登记。' })
        continue
    }

    if ($currentDirectory.StartsWith($item.path, [System.StringComparison]::OrdinalIgnoreCase)) {
        $failed.Add([pscustomobject]@{ path = $item.path; stage = 'worktree-remove'; error = '当前会话仍在该工作区内。' })
        continue
    }

    $removeArguments = New-Object System.Collections.Generic.List[string]
    $removeArguments.Add('worktree')
    $removeArguments.Add('remove')
    # --force 只可能出现在「脏的只有未跟踪文件」的项上（needsForce），
    # 已跟踪改动会被上面的拦阻挡住，进不了 deletable。
    if ($item.needsForce) { $removeArguments.Add('--force') }
    $removeArguments.Add($item.path)

    $remove = Invoke-GitCommand -RepoRoot $repoRoot -Arguments $removeArguments.ToArray() -TimeoutSeconds 120
    Add-CommandRun $remove

    if ($remove.exitCode -ne 0) {
        $failed.Add([pscustomobject]@{
                path  = $item.path
                stage = 'worktree-remove'
                error = (@($remove.stderr) -join ' ')
            })
        # 工作区没删掉就不动分支，避免出现「分支没了但工作区还在」的半成品。
        continue
    }

    $branchDeleted = $false
    $branchError = $null
    if (-not [string]::IsNullOrWhiteSpace($item.branch)) {
        # 用 -d 而不是 -D：未合并时让 git 自己拦下来。
        $branchRemove = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('branch', '-d', $item.branch)
        Add-CommandRun $branchRemove
        if ($branchRemove.exitCode -eq 0) {
            $branchDeleted = $true
        } else {
            $branchError = (@($branchRemove.stderr) -join ' ')
        }
    }

    $removed.Add([pscustomobject]@{
        path          = $item.path
        branch        = $item.branch
        mergedVerdict = $item.mergedVerdict
        branchDeleted = $branchDeleted
        branchError   = $branchError
    })
}

$verify = Get-GitWorktrees -RepoRoot $repoRoot
Add-CommandRun $verify.result
$remainingPaths = @($verify.worktrees | ForEach-Object { $_.path })

$data = [pscustomobject]@{
    repoRoot      = $repoRoot
    targetBranch  = $targetBranch
    removed       = $removed.ToArray()
    removedCount  = $removed.Count
    failed        = $failed.ToArray()
    failedCount   = $failed.Count
    skippedBlocked = @($blockedItems)
    remainingWorktrees = $remainingPaths
}

$status = if ($failed.Count -gt 0) { 'blocked' } else { 'ok' }
$errorCode = if ($failed.Count -gt 0) { 'partial-cleanup' } else { $null }
$reason = "已移除 $($removed.Count) 个工作区；$($failed.Count) 个失败；$($blockedItems.Count) 个按规则保留。"

Write-GitSkillResult -Result (New-GitSkillResult -Action 'cleanup.apply' -Status $status -Reason $reason `
        -RepoRoot $repoRoot -ErrorCode $errorCode -Data $data -CommandsRun $commandsRun) `
    -OutputJson $OutputJson
