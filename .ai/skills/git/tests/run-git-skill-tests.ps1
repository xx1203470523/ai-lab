# 个人 /git 技能脚本的隔离回归测试。
#
# 全程只在一个临时目录里造仓库和一个裸仓库充当假远端，
# 不接触任何真实远端、不推送、不删除任何真实工作区。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File <本文件>

param(
    [switch]$KeepLab
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$skillRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$scriptsDir = Join-Path $skillRoot 'scripts'

$script:PassCount = 0
$script:FailCount = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host "=== $Text ===" -ForegroundColor Cyan
}

function Assert-True {
    param([string]$Label, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:PassCount++
        Write-Host "  [通过] $Label" -ForegroundColor Green
    } else {
        $script:FailCount++
        $script:Failures.Add("$Label :: $Detail")
        Write-Host "  [失败] $Label" -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($Detail)) { Write-Host "         $Detail" -ForegroundColor DarkYellow }
    }
}

function Assert-Equal {
    param([string]$Label, $Expected, $Actual)
    Assert-True -Label $Label -Condition ($Expected -eq $Actual) -Detail "期望=$Expected 实际=$Actual"
}

function Invoke-Skill {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory
    )

    $path = Join-Path $scriptsDir $Script
    $pushed = $false
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        Push-Location $WorkingDirectory
        $pushed = $true
    }

    $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $path @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($pushed) { Pop-Location }

    $text = (@($raw) -join "`n").Trim()
    $parsed = $null
    $parseError = $null
    try {
        $parsed = $text | ConvertFrom-Json
    } catch {
        $parseError = $_.Exception.Message
    }

    return [pscustomobject]@{
        exitCode   = $exitCode
        text       = $text
        json       = $parsed
        parseError = $parseError
    }
}

function New-Lab {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) { Remove-Item -Recurse -Force -LiteralPath $Path }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null

    $remote = Join-Path $Path 'origin.git'
    $primary = Join-Path $Path 'primary'

    & git init --bare -b main $remote | Out-Null
    & git init -b main $primary | Out-Null
    & git -C $primary config user.email 'test@example.com' | Out-Null
    & git -C $primary config user.name 'test' | Out-Null
    & git -C $primary config core.autocrlf false | Out-Null
    & git -C $primary config commit.gpgsign false | Out-Null

    Set-Content -LiteralPath (Join-Path $primary 'readme.md') -Value 'hello' -Encoding UTF8
    & git -C $primary add readme.md | Out-Null
    & git -C $primary commit -m 'chore: 初始化' | Out-Null
    & git -C $primary remote add origin $remote | Out-Null
    & git -C $primary push -u origin main | Out-Null
    & git -C $primary branch production | Out-Null
    & git -C $primary push origin production | Out-Null
    & git -C $primary fetch origin | Out-Null

    return [pscustomobject]@{ Remote = $remote; Primary = $primary }
}

function Get-Head {
    param([string]$Repo, [string]$Rev = 'HEAD')
    $value = & git -C $Repo rev-parse $Rev 2>$null
    return ([string]($value | Select-Object -First 1)).Trim()
}

# ===========================================================================
Write-Head '准备隔离实验室'

$labPath = Join-Path $env:TEMP 'git-skill-tests'
$lab = New-Lab -Path $labPath
Write-Host "  仓库：$($lab.Primary)"
Write-Host "  假远端：$($lab.Remote)"

Assert-True -Label '临时仓库已就绪' -Condition (Test-Path (Join-Path $lab.Primary '.git'))

# ===========================================================================
Write-Head 'wt.ps1 只读动作'

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @('-Action', 'status') -WorkingDirectory $lab.Primary
Assert-Equal -Label 'wt.status 退出码为 0' -Expected 0 -Actual $r.exitCode
Assert-Equal -Label 'wt.status 判定在主工作目录' -Expected $false -Actual $r.json.data.insideWorktree
Assert-Equal -Label 'wt.status 主分支为 main' -Expected 'main' -Actual $r.json.data.mainBranch
Assert-True -Label 'stdout 是纯 JSON（无杂散输出）' -Condition ($null -eq $r.parseError) -Detail $r.parseError

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @('-Action', 'list') -WorkingDirectory $lab.Primary
Assert-Equal -Label 'wt.list 数量为 1' -Expected 1 -Actual $r.json.data.count
Assert-Equal -Label '干净工作区脏文件数为 0 而非 null' -Expected 0 -Actual $r.json.data.worktrees[0].changedFiles

# ===========================================================================
Write-Head 'wt.ps1 创建与守卫'

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'create', '-Name', 'feature-a', '-Branch', 'fix/lyp/feature-a', '-AllowFetch'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '创建工作区成功' -Expected 'ok' -Actual $r.json.status
Assert-Equal -Label 'auto 模式从主工作目录分支推出基分支' -Expected 'main' -Actual $r.json.data.baseBranch
Assert-Equal -Label '基分支解析来源可追溯' -Expected 'main-worktree-branch' -Actual $r.json.data.baseResolution
Assert-True -Label '返回了调用方需自行执行的切换命令' -Condition ($r.json.data.cdCommand -like "Set-Location -LiteralPath '*'")
Assert-True -Label '注明这条命令要由调用方自己执行、不要丢给用户' -Condition ($r.json.data.parentShellNote -like '*由调用方（AI）自己执行*')

$worktreeA = $r.json.data.path
Assert-True -Label '工作区目录真实存在' -Condition (Test-Path -LiteralPath $worktreeA)

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'create', '-Name', 'nested', '-Branch', 'fix/lyp/nested', '-AllowFetch'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '工作区内建工作区被拦截' -Expected 'nested-worktree-forbidden' -Actual $r.json.errorCode
Assert-Equal -Label '拦截时退出码为 1' -Expected 1 -Actual $r.exitCode

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'create', '-Name', 'bad', '-Branch', 'main', '-AllowFetch'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '受保护分支名被拦截' -Expected 'protected-branch-name' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'create', '-Name', 'dup', '-Branch', 'fix/lyp/feature-a', '-AllowFetch'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '重复分支被拦截' -Expected 'branch-already-exists' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'enter', '-Name', 'feature-a'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '按目录名进入工作区' -Expected $worktreeA -Actual $r.json.data.path
Assert-Equal -Label '进入时 alreadyThere 为假' -Expected $false -Actual $r.json.data.alreadyThere

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'enter', '-Name', 'fix-lyp-feature-a'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '按分支名也能解析到同一工作区' -Expected $worktreeA -Actual $r.json.data.path

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @('-Action', 'enter', '-Name', '不存在') -WorkingDirectory $lab.Primary
Assert-Equal -Label '不存在的工作区被拦截' -Expected 'worktree-not-found' -Actual $r.json.errorCode

# ===========================================================================
Write-Head 'wt.ps1 find：候选扫描'

# 造四种分支，正好覆盖四个判定分支：
#   fix/lyp/detached  —— 领先 1 且没有工作区：应进候选，hasWorktree 为假
#   old/lyp/stale     —— 最后提交在两年前：应被时间窗排除
#   merged/lyp/done   —— 与 origin/main 同点且无工作区：应按已合并排除
#   fix/lyp/feature-a —— 领先 0 但挂着工作区：必须保留（例外规则）
# 注意此时 main 与 origin/main 仍同点，后面 commit 段才会让 main 前进。

& git -C $lab.Primary checkout -q -b 'fix/lyp/detached' | Out-Null
Set-Content -LiteralPath (Join-Path $lab.Primary 'detached.txt') -Value 'x' -Encoding UTF8
& git -C $lab.Primary add detached.txt | Out-Null
& git -C $lab.Primary commit -q -m 'fix(仓库): 未合并的改动' | Out-Null
& git -C $lab.Primary checkout -q main | Out-Null

& git -C $lab.Primary checkout -q -b 'old/lyp/stale' | Out-Null
Set-Content -LiteralPath (Join-Path $lab.Primary 'stale.txt') -Value 'x' -Encoding UTF8
& git -C $lab.Primary add stale.txt | Out-Null
$env:GIT_AUTHOR_DATE = '2020-01-01T00:00:00'
$env:GIT_COMMITTER_DATE = '2020-01-01T00:00:00'
& git -C $lab.Primary commit -q -m 'chore(仓库): 两年前的改动' | Out-Null
if (Test-Path Env:\GIT_AUTHOR_DATE) { Remove-Item Env:\GIT_AUTHOR_DATE }
if (Test-Path Env:\GIT_COMMITTER_DATE) { Remove-Item Env:\GIT_COMMITTER_DATE }
& git -C $lab.Primary checkout -q main | Out-Null

& git -C $lab.Primary branch 'merged/lyp/done' | Out-Null

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @('-Action', 'find', '-AllowFetch') -WorkingDirectory $lab.Primary
Assert-Equal -Label 'wt.find 退出码为 0' -Expected 0 -Actual $r.exitCode
Assert-True -Label 'wt.find 的 stdout 是纯 JSON' -Condition ($null -eq $r.parseError) -Detail $r.parseError

$names = @($r.json.data.candidates | ForEach-Object { $_.name })
$joined = $names -join ', '
Assert-True -Label '未合并且无工作区的分支进入候选' -Condition ($names -contains 'fix/lyp/detached') -Detail $joined
Assert-True -Label '已合并且无工作区的分支被排除' -Condition (-not ($names -contains 'merged/lyp/done')) -Detail $joined
Assert-True -Label '超出时间窗的分支被排除' -Condition (-not ($names -contains 'old/lyp/stale')) -Detail $joined
Assert-True -Label '集成分支不出现在候选里' -Condition ((-not ($names -contains 'main')) -and (-not ($names -contains 'production'))) -Detail $joined
Assert-True -Label '领先为 0 但挂着工作区的分支被保留' -Condition ($names -contains 'fix/lyp/feature-a') -Detail $joined
Assert-True -Label '排除项里至少有一个已合并计数' -Condition ($r.json.data.excluded.merged -ge 1)
Assert-Equal -Label '领先为 0 的工作区分支计入 mergedWithWorktree' -Expected 1 -Actual $r.json.data.excluded.mergedWithWorktree

$detachedItem = $r.json.data.candidates | Where-Object { $_.name -eq 'fix/lyp/detached' }
Assert-Equal -Label '无工作区的候选 hasWorktree 为假' -Expected $false -Actual $detachedItem.hasWorktree
Assert-True -Label '无工作区的候选领先数为正' -Condition ($detachedItem.aheadOfTarget -gt 0)
Assert-True -Label '候选带出最近提交标题供比对' -Condition (@($detachedItem.recentCommits).Count -gt 0) -Detail ($detachedItem.recentCommits -join ' / ')

$keptItem = $r.json.data.candidates | Where-Object { $_.name -eq 'fix/lyp/feature-a' }
Assert-Equal -Label '有工作区的候选带出工作区路径' -Expected $worktreeA -Actual $keptItem.worktreePath

$ordered = @($r.json.data.candidates | ForEach-Object { $_.daysAgo })
$sortedDesc = @($ordered | Sort-Object)
Assert-Equal -Label '候选按最后提交时间倒排' -Expected ($sortedDesc -join ',') -Actual ($ordered -join ',')

# 独立交叉验证：脚本的领先数必须与 git rev-list 自己算的一致。
# 这是「已合并」判定的核心，口径反了会把正在开发的分支当成已合并丢掉。
$mismatch = 0
foreach ($candidate in $r.json.data.candidates) {
    $refExists = & git -C $lab.Primary rev-parse --verify --quiet "refs/heads/$($candidate.name)"
    if ($LASTEXITCODE -ne 0) { continue }
    $rev = (& git -C $lab.Primary rev-list --left-right --count "refs/remotes/origin/main...refs/heads/$($candidate.name)") -split '\s+'
    if ([int]$rev[1] -ne [int]$candidate.aheadOfTarget) { $mismatch++ }
}
Assert-Equal -Label '领先数与 rev-list 独立计算逐条一致' -Expected 0 -Actual $mismatch

# ===========================================================================
Write-Head 'wt.ps1 attach：挂接既有分支'

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'attach', '-Branch', 'fix/lyp/detached', '-DryRun'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label 'attach 预演判定成功' -Expected 'ok' -Actual $r.json.status
Assert-Equal -Label '预演识别为挂接本地既有分支' -Expected 'local-branch' -Actual $r.json.data.source
$attachPath = $r.json.data.path
Assert-True -Label '预演不落盘' -Condition (-not (Test-Path -LiteralPath $attachPath))

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'attach', '-Branch', 'fix/lyp/detached'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '挂接成功' -Expected 'ok' -Actual $r.json.status
Assert-True -Label '工作区目录已建立' -Condition (Test-Path -LiteralPath $attachPath)
Assert-Equal -Label '挂接后 HEAD 就是该分支的提交（未被重置）' `
    -Expected (Get-Head -Repo $lab.Primary -Rev 'refs/heads/fix/lyp/detached') -Actual $r.json.data.head

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'attach', '-Branch', 'fix/lyp/detached'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '重复挂接被拦截并指向 enter' -Expected 'branch-already-checked-out' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'attach', '-Branch', 'fix/lyp/does-not-exist'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '不存在的分支被拦截' -Expected 'branch-not-found' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'attach', '-Branch', 'main'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '受保护分支被拦截' -Expected 'protected-branch-name' -Actual $r.json.errorCode

# create 只建新分支，这正是 attach 必须存在的原因
$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'create', '-Name', 'detached-dup', '-Branch', 'fix/lyp/detached', '-AllowFetch'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label 'create 拒绝既有分支（所以才有 attach）' -Expected 'branch-already-exists' -Actual $r.json.errorCode

# 挂接之后再 find，该分支的 hasWorktree 应变为真 —— 这条路就是「接着旧分支干活」
$r = Invoke-Skill -Script 'wt.ps1' -Arguments @('-Action', 'find') -WorkingDirectory $lab.Primary
$reattached = $r.json.data.candidates | Where-Object { $_.name -eq 'fix/lyp/detached' }
Assert-Equal -Label '挂接后 find 反映为已有工作区' -Expected $true -Actual $reattached.hasWorktree
Assert-Equal -Label '挂接后带出的工作区路径一致' -Expected $attachPath -Actual $reattached.worktreePath

# ===========================================================================
Write-Head 'commit.ps1 守卫'

$msgFile = Join-Path $labPath 'msg-good.txt'
[System.IO.File]::WriteAllText($msgFile, "fix(仓库): 修正储位同步守卫`n`n- 补充校验", (New-Object System.Text.UTF8Encoding($false)))

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'a.txt', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '未变更路径被拦截' -Expected 'path-not-changed' -Actual $r.json.errorCode

# -u 能到达脚本自身的守卫；-A 会被 PowerShell 的参数绑定器更早拦下，
# 两条路径都拒绝，属于纵深防御。
$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', '-u', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label 'git add -u 写法被脚本守卫拦截' -Expected 'invalid-path-specifier' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', '-A', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label 'git add -A 写法被参数绑定器拦截（非零退出且无 JSON）' -Expected 1 -Actual $r.exitCode
Assert-True -Label '被拦截时不产生 JSON 结果' -Condition ($null -eq $r.json)

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', '.', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '仓库根目录写法被拦截' -Expected 'invalid-path-specifier' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', '*.cs', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '通配符被拦截' -Expected 'invalid-path-specifier' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', (Join-Path $env:TEMP 'outside.txt'), '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '仓库外路径被拦截' -Expected 'invalid-path-specifier' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'readme.md', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '空路径清单被拦截' -Expected 'path-not-changed' -Actual $r.json.errorCode

# 署名行拦截
$msgAttribution = Join-Path $labPath 'msg-attribution.txt'
[System.IO.File]::WriteAllText($msgAttribution, "fix(仓库): 测试`n`nCo-Authored-By: Claude Code <noreply@anthropic.com>", (New-Object System.Text.UTF8Encoding($false)))
Set-Content -LiteralPath (Join-Path $lab.Primary 'a.txt') -Value 'a' -Encoding UTF8
$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'a.txt', '-MessageFile', $msgAttribution
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '署名行被硬拦截' -Expected 'attribution-line-forbidden' -Actual $r.json.errorCode

# 非规范标题拦截
$msgBad = Join-Path $labPath 'msg-bad.txt'
[System.IO.File]::WriteAllText($msgBad, '随手改了点东西', (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'a.txt', '-MessageFile', $msgBad
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '非规范标题被拦截' -Expected 'non-conventional-subject' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'a.txt', '-MessageFile', $msgBad, '-AllowNonConventional'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '显式放行后可通过' -Expected 'ok' -Actual $r.json.status

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'a.txt', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '合规提交计划成功' -Expected 'ok' -Actual $r.json.status
Assert-Equal -Label '计划里列出将暂存的路径' -Expected 'a.txt' -Actual $r.json.data.stagedPaths[0]

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'commit', '-Path', 'a.txt', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '提交成功' -Expected 'ok' -Actual $r.json.status
$headA = Get-Head -Repo $lab.Primary
Assert-Equal -Label '提交确实落到了 HEAD' -Expected $headA -Actual $r.json.data.commit

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'commit', '-Path', 'readme.md', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '重复提交同一路径被拦截' -Expected 'path-not-changed' -Actual $r.json.errorCode

# 多文件：powershell -File 模式不会把数组参数拆成多个 token，
# `-Path a.txt,b.txt` 会作为单个字符串进来，脚本必须自己按逗号再拆一次。
Set-Content -LiteralPath (Join-Path $lab.Primary 'b.txt') -Value 'b' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $lab.Primary 'c.txt') -Value 'c' -Encoding UTF8

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'plan', '-Path', 'b.txt,c.txt', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '逗号分隔的多路径被正确拆分' -Expected 2 -Actual $r.json.data.stagedCount
Assert-True -Label '拆分后两个路径都在计划内' -Condition (@($r.json.data.stagedPaths) -contains 'c.txt')

$r = Invoke-Skill -Script 'commit.ps1' -Arguments @(
    '-Action', 'commit', '-Path', 'b.txt,c.txt', '-MessageFile', $msgFile
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '多文件一次提交成功' -Expected 2 -Actual $r.json.data.stagedCount

# ===========================================================================
Write-Head 'prepush.ps1 检查与变基'

# 在特性分支上产生一个提交
Set-Content -LiteralPath (Join-Path $worktreeA 'feature.txt') -Value 'feature' -Encoding UTF8
& git -C $worktreeA add feature.txt | Out-Null
& git -C $worktreeA commit -m 'feat(仓库): 新增特性文件' | Out-Null

# 让远端 main 前进
Set-Content -LiteralPath (Join-Path $lab.Primary 'upstream.txt') -Value 'upstream' -Encoding UTF8
& git -C $lab.Primary add upstream.txt | Out-Null
& git -C $lab.Primary commit -m 'chore(仓库): 远端前进' | Out-Null
& git -C $lab.Primary push origin main | Out-Null

$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'check', '-Target', 'main', '-AllowFetch'
) -WorkingDirectory $worktreeA
Assert-Equal -Label 'prepush.check 成功' -Expected 'ok' -Actual $r.json.status
Assert-True -Label '确实落后于远端' -Condition ($r.json.data.behindTarget -gt 0)

# 期望值用 git 独立算一遍（此刻 -AllowFetch 已更新 origin/main），
# 不把测试写死在与脚本同一套逻辑上。
$counts = (& git -C $worktreeA rev-list --left-right --count 'refs/remotes/origin/main...HEAD') -split '\s+'
Assert-Equal -Label '落后提交数与 git 独立计算一致' -Expected ([int]$counts[0]) -Actual $r.json.data.behindTarget
Assert-Equal -Label '需要变基' -Expected $true -Actual $r.json.data.needsRebase
Assert-Equal -Label '识别出处在链接工作区内' -Expected $true -Actual $r.json.data.insideLinkedWorktree

$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'check', '-Target', 'main'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '在 main 上执行被拦截' -Expected 'protected-branch' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'rebase', '-Target', 'main', '-AllowFetch'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '变基成功' -Expected 'ok' -Actual $r.json.status
Assert-True -Label '变基确实改写了 HEAD' -Condition ($r.json.data.headBefore -ne $r.json.data.headAfter)

# behindTarget 是变基前的触发依据，变基后的真实状态看 AfterRebase 字段。
# 两者都要有，才能既说明为什么变基、又证明变基生效了。
Assert-True -Label '保留变基前的落后数作为依据' -Condition ($r.json.data.behindTarget -gt 0)
Assert-Equal -Label '变基后不再落后' -Expected 0 -Actual $r.json.data.behindTargetAfterRebase
$countsAfter = (& git -C $worktreeA rev-list --left-right --count 'refs/remotes/origin/main...HEAD') -split '\s+'
Assert-Equal -Label '变基后状态与 git 独立计算一致' -Expected ([int]$countsAfter[0]) -Actual $r.json.data.behindTargetAfterRebase

$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'rebase', '-Target', 'main', '-AllowFetch'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '已同步时变基为幂等空操作' -Expected 'ok' -Actual $r.json.status

# -AllowUntracked：只有未跟踪文件时放行变基
Set-Content -LiteralPath (Join-Path $worktreeA 'untracked-only.txt') -Value 'noise' -Encoding UTF8
Set-Content -LiteralPath (Join-Path $lab.Primary 'upstream2.txt') -Value 'upstream2' -Encoding UTF8
& git -C $lab.Primary add upstream2.txt | Out-Null
& git -C $lab.Primary commit -m 'chore(仓库): 远端再次前进' | Out-Null
& git -C $lab.Primary push origin main | Out-Null

$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'rebase', '-Target', 'main', '-AllowFetch', '-AllowUntracked'
) -WorkingDirectory $worktreeA
Assert-Equal -Label 'AllowUntracked 放行未跟踪文件' -Expected 'ok' -Actual $r.json.status
Assert-Equal -Label '放行后确实完成变基' -Expected 0 -Actual $r.json.data.behindTargetAfterRebase
Assert-True -Label '未跟踪文件变基后仍在' -Condition (Test-Path -LiteralPath (Join-Path $worktreeA 'untracked-only.txt'))
Remove-Item -LiteralPath (Join-Path $worktreeA 'untracked-only.txt') -Force

# 脏工作树守卫
Set-Content -LiteralPath (Join-Path $worktreeA 'dirty.txt') -Value 'dirty' -Encoding UTF8
$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'rebase', '-Target', 'main', '-AllowFetch'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '脏工作树被拒绝变基' -Expected 'dirty-tree' -Actual $r.json.errorCode
Remove-Item -LiteralPath (Join-Path $worktreeA 'dirty.txt') -Force

# -AllowUntracked 只放行未跟踪文件，已跟踪改动照拦
Set-Content -LiteralPath (Join-Path $worktreeA 'readme.md') -Value 'tracked-change' -Encoding UTF8
$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'rebase', '-Target', 'main', '-AllowFetch', '-AllowUntracked'
) -WorkingDirectory $worktreeA
Assert-Equal -Label 'AllowUntracked 不能放行已跟踪改动' -Expected 'dirty-tree' -Actual $r.json.errorCode
& git -C $worktreeA checkout -- readme.md | Out-Null

# 冲突场景：两侧改同一文件
Set-Content -LiteralPath (Join-Path $lab.Primary 'conflict.txt') -Value 'from-main' -Encoding UTF8
& git -C $lab.Primary add conflict.txt | Out-Null
& git -C $lab.Primary commit -m 'chore(仓库): main 侧改动' | Out-Null
& git -C $lab.Primary push origin main | Out-Null

Set-Content -LiteralPath (Join-Path $worktreeA 'conflict.txt') -Value 'from-feature' -Encoding UTF8
& git -C $worktreeA add conflict.txt | Out-Null
& git -C $worktreeA commit -m 'feat(仓库): 特性侧改动' | Out-Null

$headBeforeConflict = Get-Head -Repo $worktreeA
$r = Invoke-Skill -Script 'prepush.ps1' -Arguments @(
    '-Action', 'rebase', '-Target', 'main', '-AllowFetch'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '冲突时判定为阻塞' -Expected 'blocked' -Actual $r.json.status
Assert-Equal -Label '冲突错误码正确' -Expected 'rebase-conflict' -Actual $r.json.errorCode
Assert-True -Label '列出了冲突文件' -Condition (@($r.json.data.conflictedFiles) -contains 'conflict.txt')
Assert-Equal -Label '冲突后已自动中止并还原' -Expected $true -Actual $r.json.data.aborted
Assert-Equal -Label 'HEAD 已还原到冲突前' -Expected $headBeforeConflict -Actual (Get-Head -Repo $worktreeA)
$rebaseInProgress = Test-Path -LiteralPath (Join-Path $worktreeA '.git')
Assert-True -Label '工作区仍完好' -Condition (Test-Path -LiteralPath $worktreeA)

# ===========================================================================
Write-Head 'mr.ps1 降级行为'

$r = Invoke-Skill -Script 'mr.ps1' -Arguments @(
    '-Action', 'query', '-Source', 'fix/lyp/feature-a', '-Target', 'main'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '非 GitLab 远端判定为阻塞' -Expected 'blocked' -Actual $r.json.status
Assert-Equal -Label '非 GitLab 错误码正确' -Expected 'not-gitlab' -Actual $r.json.errorCode
Assert-Equal -Label '降级时不编造创建链接' -Expected $null -Actual $r.json.data.createUrl

$r = Invoke-Skill -Script 'mr.ps1' -Arguments @(
    '-Action', 'query', '-Source', 'main', '-Target', 'main'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '源与目标相同被拦截' -Expected 'source-equals-target' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'mr.ps1' -Arguments @(
    '-Action', 'query', '-Source', 'fix/lyp/feature-a', '-Target', '不存在的分支'
) -WorkingDirectory $worktreeA
Assert-Equal -Label '不存在的目标分支被拦截' -Expected 'target-branch-unresolved' -Actual $r.json.errorCode

# ===========================================================================
Write-Head 'cleanup.ps1 两阶段清理'

# 造一个「已合并」的工作区：分支与 origin/main 同点
$r = Invoke-Skill -Script 'wt.ps1' -Arguments @(
    '-Action', 'create', '-Name', 'merged-b', '-Branch', 'fix/lyp/merged-b', '-AllowFetch'
) -WorkingDirectory $lab.Primary
$worktreeB = $r.json.data.path
Assert-Equal -Label '第二个工作区创建成功' -Expected 'ok' -Actual $r.json.status

$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Target', 'main'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '清理预检成功' -Expected 'ok' -Actual $r.json.status
$planToken = $r.json.data.confirmToken
Assert-True -Label '预检返回确认令牌' -Condition (-not [string]::IsNullOrWhiteSpace($planToken))

$mergedItem = @($r.json.data.deletable | Where-Object { $_.name -eq 'merged-b' })
Assert-Equal -Label '已合并分支判定为可清理' -Expected 1 -Actual $mergedItem.Count
Assert-Equal -Label '合并判定依据是 rev-list 计数' -Expected 'merged' -Actual $mergedItem[0].mergedVerdict

$featureItem = @($r.json.data.blocked | Where-Object { $_.name -eq 'feature-a' })
Assert-Equal -Label '未合并分支判定为需保留' -Expected 1 -Actual $featureItem.Count
Assert-True -Label '给出了保留原因' -Condition (@($featureItem[0].blockers).Count -gt 0)

# 未合并强制删除应被拒绝
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Name', 'feature-a', '-Target', 'main'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '未合并分支不可删' -Expected 0 -Actual $r.json.data.deletableCount
Assert-Equal -Label '未合并分支进阻塞清单' -Expected 1 -Actual $r.json.data.blockedCount

# 脏工作区不可删
Set-Content -LiteralPath (Join-Path $worktreeB 'untracked.txt') -Value 'x' -Encoding UTF8
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Name', 'merged-b', '-Target', 'main'
) -WorkingDirectory $lab.Primary
$dirtyItem = @($r.json.data.blocked | Where-Object { $_.name -eq 'merged-b' })
Assert-Equal -Label '带未跟踪文件的工作区不可删' -Expected 1 -Actual $dirtyItem.Count

# -AllowUntracked：只有未跟踪文件时转为可删，且标记需要 --force
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Name', 'merged-b', '-Target', 'main', '-AllowUntracked'
) -WorkingDirectory $lab.Primary
$allowedItem = @($r.json.data.deletable | Where-Object { $_.name -eq 'merged-b' })
Assert-Equal -Label 'AllowUntracked 后未跟踪工作区可删' -Expected 1 -Actual $allowedItem.Count
Assert-Equal -Label '未跟踪放行项标记需要 --force' -Expected $true -Actual $allowedItem[0].needsForce

# -AllowUntracked 不能放行已跟踪改动
Set-Content -LiteralPath (Join-Path $worktreeB 'readme.md') -Value 'tracked-change' -Encoding UTF8
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Name', 'merged-b', '-Target', 'main', '-AllowUntracked'
) -WorkingDirectory $lab.Primary
$stillBlocked = @($r.json.data.blocked | Where-Object { $_.name -eq 'merged-b' })
Assert-Equal -Label 'AllowUntracked 不能放行已跟踪改动' -Expected 1 -Actual $stillBlocked.Count
& git -C $worktreeB checkout -- readme.md | Out-Null

Remove-Item -LiteralPath (Join-Path $worktreeB 'untracked.txt') -Force

# 令牌错误应被拒绝
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'apply', '-Name', 'merged-b', '-Target', 'main', '-ConfirmToken', 'deadbeefdeadbeef'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '令牌不匹配时拒绝执行' -Expected 'state-changed-since-plan' -Actual $r.json.errorCode

$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'apply', '-Name', 'merged-b', '-Target', 'main'
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '缺少令牌时拒绝执行' -Expected 'confirm-token-required' -Actual $r.json.errorCode
Assert-True -Label '拒绝执行时工作区仍在' -Condition (Test-Path -LiteralPath $worktreeB)

# 正确流程：plan 取令牌 → apply
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Name', 'merged-b', '-Target', 'main'
) -WorkingDirectory $lab.Primary
$planToken = $r.json.data.confirmToken
Assert-Equal -Label '定向预检只含一个可删项' -Expected 1 -Actual $r.json.data.deletableCount

$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'apply', '-Name', 'merged-b', '-Target', 'main', '-ConfirmToken', $planToken
) -WorkingDirectory $lab.Primary
Assert-Equal -Label '带正确令牌执行成功' -Expected 'ok' -Actual $r.json.status
Assert-Equal -Label '移除了 1 个工作区' -Expected 1 -Actual $r.json.data.removedCount
Assert-Equal -Label '分支一并删除' -Expected $true -Actual $r.json.data.removed[0].branchDeleted
Assert-True -Label '工作区目录已消失' -Condition (-not (Test-Path -LiteralPath $worktreeB))

$branchGone = & git -C $lab.Primary branch --list 'fix/lyp/merged-b'
Assert-True -Label '分支确实已删除' -Condition ([string]::IsNullOrWhiteSpace((@($branchGone) -join '')))

# 在目标工作区内执行清理应被拦截
Set-Content -LiteralPath (Join-Path $worktreeA 'still-dirty.txt') -Value 'x' -Encoding UTF8
$r = Invoke-Skill -Script 'cleanup.ps1' -Arguments @(
    '-Action', 'plan', '-Name', 'feature-a', '-Target', 'main'
) -WorkingDirectory $worktreeA
$selfItem = @($r.json.data.blocked | Where-Object { $_.name -eq 'feature-a' })
Assert-True -Label '位于该工作区内时列为阻塞' -Condition ($selfItem.Count -eq 1)
Remove-Item -LiteralPath (Join-Path $worktreeA 'still-dirty.txt') -Force

# ===========================================================================
Write-Head '结果'

Write-Host ''
Write-Host "通过 $($script:PassCount) 项，失败 $($script:FailCount) 项。" -ForegroundColor $(if ($script:FailCount -eq 0) { 'Green' } else { 'Red' })

if ($script:FailCount -gt 0) {
    Write-Host ''
    Write-Host '失败明细：' -ForegroundColor Red
    foreach ($item in $script:Failures) { Write-Host "  - $item" -ForegroundColor Red }
}

if (-not $KeepLab) {
    if (Test-Path -LiteralPath $labPath) { Remove-Item -Recurse -Force -LiteralPath $labPath -ErrorAction SilentlyContinue }
    Write-Host ''
    Write-Host '实验室已清理。'
} else {
    Write-Host ''
    Write-Host "实验室保留在：$labPath"
}

if ($script:FailCount -gt 0) { exit 1 }
exit 0
