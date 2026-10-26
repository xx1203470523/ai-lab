# 个人 /git 技能的工作区（worktree）生命周期脚本。
#
# 动作：
#   list   列出所有工作区及其分支、脏文件数
#   find   找最近活跃、可能对应当前需求的分支迭代（只读，不做语义匹配）
#   create 从远端最新基分支创建工作区和新分支
#   attach 把既有分支挂到一个新工作区，接着旧分支干活
#   enter  解析工作区路径并给出切换命令
#   status 报告当前目录在工作区拓扑里的位置

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('list', 'find', 'create', 'attach', 'enter', 'status')]
    [string]$Action,

    [string]$Name,
    [string]$Branch,
    [string]$Base,
    [string]$Target,
    [int]$SinceDays = 30,
    [int]$Top = 20,
    [int]$DetailTop = 10,
    [string]$Root,
    [string]$OutputJson,
    [switch]$AllowFetch,
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

# ---------------------------------------------------------------------------
# 定位仓库
# ---------------------------------------------------------------------------

$repoInfo = Get-GitRepoRoot -StartPath $Root
Add-CommandRun $repoInfo.result

if (-not $repoInfo.ok) {
    Write-GitSkillFailure -Action "wt.$Action" -ErrorCode 'not-a-repository' `
        -Reason '当前目录不在任何 Git 工作树内。'
}

$repoRoot = $repoInfo.root

$worktreeInfo = Get-GitWorktrees -RepoRoot $repoRoot
Add-CommandRun $worktreeInfo.result

if (-not $worktreeInfo.ok) {
    Write-GitSkillFailure -Action "wt.$Action" -ErrorCode 'worktree-list-failed' `
        -Reason 'git worktree list 执行失败。' -RepoRoot $repoRoot -CommandsRun $commandsRun
}

$worktrees = @($worktreeInfo.worktrees)
$mainWorktree = Get-GitMainWorktree -Worktrees $worktrees

$currentDirectory = (Get-Location).Path
$currentWorktree = Get-GitCurrentWorktree -Worktrees $worktrees -CurrentDirectory $currentDirectory

function Get-WorktreeDirtyState {
    param([string]$Path)

    $status = Get-GitStatusEntries -RepoRoot $Path
    if (-not $status.ok) {
        return [pscustomobject]@{ ok = $false; entries = @() }
    }

    # 必须包一层对象：PowerShell 函数直接返回空数组会被解包成 $null，
    # 那样干净的工作区会被误判成「状态未知」。
    return [pscustomobject]@{ ok = $true; entries = @($status.entries) }
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

if ($Action -eq 'list') {
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($worktree in $worktrees) {
        $dirty = Get-WorktreeDirtyState -Path $worktree.path
        $items.Add([pscustomobject]@{
            path         = $worktree.path
            branch       = $worktree.branch
            head         = $worktree.head
            detached     = $worktree.detached
            isMain       = $worktree.isMain
            locked       = $worktree.locked
            exists       = (Test-Path -LiteralPath $worktree.path)
            changedFiles = $(if ($dirty.ok) { @($dirty.entries).Count } else { $null })
            isCurrent    = ($null -ne $currentWorktree -and $worktree.path -eq $currentWorktree.path)
        })
    }

    $data = [pscustomobject]@{
        mainWorktree  = $mainWorktree.path
        currentPath   = $currentDirectory
        currentIsMain = ($null -ne $currentWorktree -and $currentWorktree.isMain)
        count         = $items.Count
        worktrees     = @($items.ToArray())
    }

    $result = New-GitSkillResult -Action 'wt.list' -Status 'ok' `
        -Reason "共 $($items.Count) 个工作区。" -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# find
# ---------------------------------------------------------------------------

if ($Action -eq 'find') {
    # 判「已合并」必须有集成分支做基准。解析不出唯一答案就停下问，不要默认 main：
    # 猜错会把只在 production 上合过的迭代当成已合并，直接从候选里丢掉。
    $targetResolution = Resolve-GitTargetBranch -RepoRoot $repoRoot -Requested $Target

    if (-not $targetResolution.ok) {
        Write-GitSkillBlocked -Action 'wt.find' -ErrorCode 'target-branch-unresolved' `
            -Reason $targetResolution.reason -RepoRoot $repoRoot `
            -Data ([pscustomobject]@{
                requested  = $Target
                candidates = @($targetResolution.candidates)
            }) -CommandsRun $commandsRun
    }

    $targetBranch = $targetResolution.branch

    if ($AllowFetch) {
        $fetch = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('fetch', 'origin', $targetBranch) -TimeoutSeconds 180
        Add-CommandRun $fetch
        if ($fetch.exitCode -ne 0) {
            Write-GitSkillBlocked -Action 'wt.find' -ErrorCode 'fetch-failed' `
                -Reason "git fetch origin $targetBranch 失败：$(@($fetch.stderr) -join ' ')" `
                -RepoRoot $repoRoot -CommandsRun $commandsRun
        }
    }

    $scan = Get-GitCandidateBranches -RepoRoot $repoRoot -Target $targetBranch `
        -SinceDays $SinceDays -Top $Top -DetailTop $DetailTop -Worktrees $worktrees
    foreach ($command in @($scan.commands)) { Add-CommandRun $command }

    if (-not $scan.ok) {
        Write-GitSkillFailure -Action 'wt.find' -ErrorCode 'branch-scan-failed' `
            -Reason 'git for-each-ref 执行失败，无法列出分支。' `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    $candidates = @($scan.candidates)
    $attached = @($candidates | Where-Object { $_.hasWorktree })
    $detached = @($candidates | Where-Object { -not $_.hasWorktree })

    $data = [pscustomobject]@{
        targetBranch    = $targetBranch
        targetSource    = $targetResolution.source
        sinceDays       = $SinceDays
        totalScanned    = $scan.totalScanned
        candidateCount  = $candidates.Count
        withWorktree    = $attached.Count
        withoutWorktree = $detached.Count
        excluded        = $scan.excluded
        candidates      = $candidates
    }

    $reason = "近 $SinceDays 天有 $($scan.totalScanned) 个分支仍在进行；" +
    "列出其中最活跃的 $($candidates.Count) 个（$($attached.Count) 个已有工作区，" +
    "$($detached.Count) 个需要挂接）。已排除 $($scan.excluded.merged) 个已合并、" +
    "$($scan.excluded.tooOld) 个超出时间窗、$($scan.excluded.protectedBranch) 个集成分支；" +
    "$($scan.excluded.mergedWithWorktree) 个领先为 0 但仍挂着工作区，按进行中保留。"

    $nextActions = if ($candidates.Count -eq 0) {
        @('没有候选。用 -Action create -Branch <新分支> -Name <工作区名> [-Base main|production] 新建。')
    } else {
        @('由调用方比对需求与候选分支名及其最近提交，判断是否属于同一迭代；脚本不做语义匹配。')
    }

    $result = New-GitSkillResult -Action 'wt.find' -Status 'ok' -Reason $reason `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun -NextActions $nextActions
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

if ($Action -eq 'status') {
    $branchInfo = Get-GitCurrentBranch -RepoRoot $currentDirectory
    Add-CommandRun $branchInfo.result

    $insideLinked = ($null -ne $currentWorktree) -and (-not $currentWorktree.isMain)

    $data = [pscustomobject]@{
        currentPath     = $currentDirectory
        currentWorktree = $(if ($null -eq $currentWorktree) { $null } else { $currentWorktree.path })
        currentBranch   = $branchInfo.branch
        detached        = $branchInfo.detached
        insideWorktree  = $insideLinked
        mainWorktree    = $mainWorktree.path
        mainBranch      = $mainWorktree.branch
        worktreeCount   = $worktrees.Count
    }

    $reason = if ($insideLinked) {
        "当前位于链接工作区 $($currentWorktree.path)，分支 $($branchInfo.branch)。"
    } else {
        "当前位于主工作目录，分支 $($branchInfo.branch)。"
    }

    $result = New-GitSkillResult -Action 'wt.status' -Status 'ok' -Reason $reason `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# enter
# ---------------------------------------------------------------------------

if ($Action -eq 'enter') {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-GitSkillBlocked -Action 'wt.enter' -ErrorCode 'name-required' `
            -Reason '缺少 -Name：请传入工作区目录名或分支名。' `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    $needle = $Name.Trim()
    $found = Find-GitWorktreeByName -Worktrees $worktrees -Name $needle

    if ($found.matches.Count -eq 0) {
        $available = @($worktrees | Where-Object { -not $_.isMain } | ForEach-Object {
                [pscustomobject]@{ name = (Split-Path -Leaf $_.path); branch = $_.branch; path = $_.path }
            })

        Write-GitSkillBlocked -Action 'wt.enter' -ErrorCode 'worktree-not-found' `
            -Reason "没有匹配 $needle 的工作区。" -RepoRoot $repoRoot `
            -Data ([pscustomobject]@{ requested = $needle; available = $available }) `
            -CommandsRun $commandsRun
    }

    $match = $found.matches[0]

    if (-not (Test-Path -LiteralPath $match.path)) {
        Write-GitSkillBlocked -Action 'wt.enter' -ErrorCode 'worktree-path-missing' `
            -Reason "Git 仍登记着 $($match.path)，但目录已经不存在。请先执行 git worktree prune。" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    $alreadyThere = (Get-GitPathComparison -Left $currentDirectory -Right $match.path)
    $cd = New-GitSkillCdFields -Path $match.path

    $data = [pscustomobject]@{
        path            = $match.path
        branch          = $match.branch
        isMain          = $match.isMain
        alreadyThere    = $alreadyThere
        cdCommand       = $cd.cdCommand
        parentShellNote = $cd.parentShellNote
    }

    $reason = if ($alreadyThere) {
        "已经在 $($match.path)。"
    } else {
        "已解析到工作区 $($match.path)。本脚本无法替调用方切换目录，请执行 cdCommand。"
    }

    $result = New-GitSkillResult -Action 'wt.enter' -Status 'ok' -Reason $reason `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun `
        -NextActions $(if ($alreadyThere) { @() } else { @($data.cdCommand) })
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

if ($Action -eq 'create') {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'name-required' `
            -Reason '缺少 -Name：请传入工作区名称（即 .claude/worktree 下的目录名）。' `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'branch-required' `
            -Reason '缺少 -Branch：请传入新分支名，例如 fix/lyp/warehouse-bin-sync-guard。' `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    Assert-GitNotInsideLinkedWorktree -RepoRoot $repoRoot -Action 'wt.create' -Log $commandsRun `
        -CurrentWorktree $currentWorktree -MainWorktree $mainWorktree -CurrentDirectory $currentDirectory

    # 主工作目录必须停在集成分支上才能拉出新分支。
    $mainBranch = $mainWorktree.branch
    if ($mainWorktree.detached -or [string]::IsNullOrWhiteSpace($mainBranch)) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'main-worktree-detached' `
            -Reason "主工作目录 $($mainWorktree.path) 处于游离头指针状态。请先切回 main 或 production。" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    $newBranch = $Branch.Trim()
    if (Test-ProtectedBranch -Branch $newBranch) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'protected-branch-name' `
            -Reason "$newBranch 是受保护的集成分支名；特性工作区必须使用自己的分支。" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    # --- 基分支解析 --------------------------------------------------------
    # 这里与 git-common 的 Resolve-GitTargetBranch 是同一套推断，但不复用：显式
    # -Base 必须在 -AllowFetch **之后**才校验远端引用（fetch 可能把引用带出来），
    # 而 Resolve 是先校验。硬合会改变 -Base x -AllowFetch 的行为。
    $baseRequested = $Base
    if ([string]::IsNullOrWhiteSpace($baseRequested)) { $baseRequested = 'auto' }
    $baseRequested = $baseRequested.Trim()

    $baseResolution = 'explicit'
    $candidate = $baseRequested

    if ($baseRequested -eq 'auto') {
        $mainBranchLower = $mainBranch.Trim().ToLowerInvariant()
        if ($mainBranchLower -eq 'production') {
            $candidate = 'production'
            $baseResolution = 'main-worktree-branch'
        } elseif ($mainBranchLower -eq 'main' -or $mainBranchLower -eq 'master') {
            $candidate = $mainBranchLower
            $baseResolution = 'main-worktree-branch'
        } else {
            $baseResolution = 'undetermined'
            $candidate = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $probe = @()
        foreach ($probeName in @('main', 'production')) {
            $exists = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref "refs/remotes/origin/$probeName"
            if ($exists.exists) { $probe += $probeName }
        }
        if ($probe.Count -eq 1) {
            $candidate = $probe[0]
            $baseResolution = 'single-remote-candidate'
        }
    }

    if ([string]::IsNullOrWhiteSpace($candidate)) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'base-branch-ambiguous' `
            -Reason "无法在不猜测的前提下确定基分支。主工作目录当前在 $mainBranch 上。请显式传入 -Base main 或 -Base production。" `
            -RepoRoot $repoRoot `
            -Data ([pscustomobject]@{ mainWorktreeBranch = $mainBranch; requested = $baseRequested }) `
            -CommandsRun $commandsRun
    }

    $baseBranch = $candidate
    $remoteBaseRef = "refs/remotes/origin/$baseBranch"

    # --- 拉取远端 ----------------------------------------------------------
    if ($AllowFetch) {
        $fetch = Invoke-GitCommand -RepoRoot $repoRoot -Arguments @('fetch', 'origin', $baseBranch) -TimeoutSeconds 180
        Add-CommandRun $fetch
        if ($fetch.exitCode -ne 0) {
            Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'fetch-failed' `
                -Reason "git fetch origin $baseBranch 失败：$(@($fetch.stderr) -join ' ')" `
                -RepoRoot $repoRoot -CommandsRun $commandsRun
        }
    }

    $remoteCheck = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref $remoteBaseRef
    Add-CommandRun $remoteCheck.result
    if (-not $remoteCheck.exists) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'remote-base-missing' `
            -Reason "远端引用 $remoteBaseRef 不存在。请加 -AllowFetch，或传入一个确实存在于 origin 上的基分支。" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    # --- 目标路径与分支冲突 ------------------------------------------------
    # 变量名不能叫 $target：PowerShell 变量不区分大小写，会和 [string]$Target
    # 参数是同一个变量，赋值时被强制转成字符串。
    $targetInfo = Get-GitSkillWorktreeTargetPath -RepoRoot $repoRoot -Name $Name -Action 'wt.create' -Log $commandsRun
    $directoryName = $targetInfo.directoryName
    $targetPath = $targetInfo.targetPath

    $localCheck = Test-GitLocalBranchExists -RepoRoot $repoRoot -Branch $newBranch
    Add-CommandRun $localCheck.result
    if ($localCheck.exists) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'branch-already-exists' `
            -Reason "本地分支 $newBranch 已存在；要接着开发请改用 -Action attach。" -RepoRoot $repoRoot `
            -Data ([pscustomobject]@{ branch = $newBranch; worktrees = $worktrees }) `
            -CommandsRun $commandsRun
    }

    $existingRemote = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref "refs/remotes/origin/$newBranch"
    Add-CommandRun $existingRemote.result
    if ($existingRemote.exists) {
        Write-GitSkillBlocked -Action 'wt.create' -ErrorCode 'remote-branch-already-exists' `
            -Reason "远端分支 origin/$newBranch 已存在；要接着开发请改用 -Action attach。" `
            -RepoRoot $repoRoot -Data ([pscustomobject]@{ branch = $newBranch }) -CommandsRun $commandsRun
    }

    $plan = [pscustomobject]@{
        worktreeName   = $directoryName
        path           = $targetPath
        branch         = $newBranch
        baseBranch     = $baseBranch
        baseRef        = $remoteBaseRef
        baseResolution = $baseResolution
        mainWorktree   = $mainWorktree.path
        commands       = @(
            "git -C '$repoRoot' worktree add -b '$newBranch' '$targetPath' '$remoteBaseRef'"
        )
    }

    if ($DryRun) {
        $result = New-GitSkillResult -Action 'wt.create' -Status 'ok' `
            -Reason '预演模式：未真正创建工作区。' -RepoRoot $repoRoot -Data $plan -CommandsRun $commandsRun
        Write-GitSkillResult -Result $result -OutputJson $OutputJson
    }

    $created = Add-GitSkillWorktree -RepoRoot $repoRoot -TargetPath $targetPath -Action 'wt.create' `
        -Arguments @('worktree', 'add', '-b', $newBranch, $targetPath, $remoteBaseRef) -Log $commandsRun

    $cd = New-GitSkillCdFields -Path $targetPath
    $data = [pscustomobject]@{
        path            = $targetPath
        branch          = $created.branch
        head            = $created.head
        baseBranch      = $baseBranch
        baseResolution  = $baseResolution
        mainWorktree    = $mainWorktree.path
        cdCommand       = $cd.cdCommand
        parentShellNote = $cd.parentShellNote
    }

    $result = New-GitSkillResult -Action 'wt.create' -Status 'ok' `
        -Reason "已从 $remoteBaseRef 创建工作区 $directoryName（分支 $newBranch）。" `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun `
        -NextActions @($data.cdCommand)
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}

# ---------------------------------------------------------------------------
# attach
# ---------------------------------------------------------------------------

if ($Action -eq 'attach') {
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        Write-GitSkillBlocked -Action 'wt.attach' -ErrorCode 'branch-required' `
            -Reason '缺少 -Branch：请传入要接着开发的既有分支名。' `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    Assert-GitNotInsideLinkedWorktree -RepoRoot $repoRoot -Action 'wt.attach' -Log $commandsRun `
        -CurrentWorktree $currentWorktree -MainWorktree $mainWorktree -CurrentDirectory $currentDirectory

    $resumeBranch = $Branch.Trim()
    if (Test-ProtectedBranch -Branch $resumeBranch) {
        Write-GitSkillBlocked -Action 'wt.attach' -ErrorCode 'protected-branch-name' `
            -Reason "$resumeBranch 是受保护的集成分支名，不应挂到独立工作区上开发。" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    # 分支已经挂在别的工作区上时，正确答案是 enter，不是再挂一个。
    $owner = @($worktrees) |
        Where-Object { $null -ne $_.branch -and ($_.branch -eq $resumeBranch) } |
        Select-Object -First 1
    if ($null -ne $owner) {
        Write-GitSkillBlocked -Action 'wt.attach' -ErrorCode 'branch-already-checked-out' `
            -Reason "分支 $resumeBranch 已经挂在工作区 $($owner.path) 上。要接着开发请用 -Action enter。" `
            -RepoRoot $repoRoot `
            -Data ([pscustomobject]@{ branch = $resumeBranch; worktree = $owner.path }) `
            -CommandsRun $commandsRun `
            -NextActions @("Set-Location -LiteralPath '$($owner.path)'")
    }

    $localCheck = Test-GitLocalBranchExists -RepoRoot $repoRoot -Branch $resumeBranch
    Add-CommandRun $localCheck.result

    $remoteCheck = Test-GitRemoteRefExists -RepoRoot $repoRoot -Ref "refs/remotes/origin/$resumeBranch"
    Add-CommandRun $remoteCheck.result

    if (-not $localCheck.exists -and -not $remoteCheck.exists) {
        Write-GitSkillBlocked -Action 'wt.attach' -ErrorCode 'branch-not-found' `
            -Reason "本地和 origin 上都没有分支 $resumeBranch。要新建请用 -Action create。" `
            -RepoRoot $repoRoot -CommandsRun $commandsRun
    }

    $nameInput = if ([string]::IsNullOrWhiteSpace($Name)) { $resumeBranch } else { $Name }
    $targetInfo = Get-GitSkillWorktreeTargetPath -RepoRoot $repoRoot -Name $nameInput -Action 'wt.attach' -Log $commandsRun
    $directoryName = $targetInfo.directoryName
    $targetPath = $targetInfo.targetPath

    # 本地已有该分支就直接挂它，保持它当前的提交位置不动；只有分支仅存在于远端时
    # 才建一个跟踪远端的新本地分支。不擅自把既有分支重置到 origin。
    $hasLocal = $localCheck.exists
    $arguments = if ($hasLocal) {
        @('worktree', 'add', $targetPath, $resumeBranch)
    } else {
        @('worktree', 'add', '-b', $resumeBranch, $targetPath, "refs/remotes/origin/$resumeBranch")
    }
    $source = if ($hasLocal) { 'local-branch' } else { 'remote-branch' }

    $plan = [pscustomobject]@{
        worktreeName = $directoryName
        path         = $targetPath
        branch       = $resumeBranch
        source       = $source
        mainWorktree = $mainWorktree.path
        commands     = @("git -C '$repoRoot' $($arguments -join ' ')")
    }

    if ($DryRun) {
        $result = New-GitSkillResult -Action 'wt.attach' -Status 'ok' `
            -Reason '预演模式：未真正挂接工作区。' -RepoRoot $repoRoot -Data $plan -CommandsRun $commandsRun
        Write-GitSkillResult -Result $result -OutputJson $OutputJson
    }

    $created = Add-GitSkillWorktree -RepoRoot $repoRoot -TargetPath $targetPath -Action 'wt.attach' `
        -Arguments $arguments -Log $commandsRun

    $cd = New-GitSkillCdFields -Path $targetPath
    $data = [pscustomobject]@{
        path            = $targetPath
        branch          = $created.branch
        head            = $created.head
        source          = $source
        mainWorktree    = $mainWorktree.path
        cdCommand       = $cd.cdCommand
        parentShellNote = $cd.parentShellNote
    }

    $result = New-GitSkillResult -Action 'wt.attach' -Status 'ok' `
        -Reason "已把既有分支 $resumeBranch 挂到工作区 $directoryName。" `
        -RepoRoot $repoRoot -Data $data -CommandsRun $commandsRun -NextActions @($data.cdCommand)
    Write-GitSkillResult -Result $result -OutputJson $OutputJson
}
