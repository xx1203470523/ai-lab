# 个人 /git 技能脚本的公共函数库。
#
# 三条不要改回去的约定：
# - PS 5.1 的 .NET Framework 没有 ProcessStartInfo.ArgumentList，原生命令必须自己拼参数
#   并用 System.Diagnostics.Process 启动，才拿得到分离的 stdout/stderr 与可信退出码。
# - 不要全局设 $ErrorActionPreference = 'Stop'：git 把提示写进 stderr，PS 5.1 会包装成
#   NativeCommandError，设 Stop 会中断一条其实成功的命令。
# - 除最后一段 JSON 之外，任何脚本都不得向 stdout 输出内容。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# UTF-8 输入输出
# ---------------------------------------------------------------------------

function Initialize-GitSkillEncoding {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
}

function Write-GitSkillStdout {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($null -eq $Text) { return }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

# ---------------------------------------------------------------------------
# 原生命令执行
# ---------------------------------------------------------------------------

function ConvertTo-WindowsArgumentString {
    param([AllowEmptyString()][string]$Argument)

    # 按 MSVC 运行库的解析规则转义，避免把含空格或引号的路径交给
    # 原生进程时被拆断。
    if ([string]::IsNullOrEmpty($Argument)) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append('\' * ($backslashes * 2 + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append('\' * ($backslashes * 2))
    }

    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 120
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }

    $quoted = foreach ($argument in @($Arguments)) {
        ConvertTo-WindowsArgumentString -Argument ([string]$argument)
    }
    $startInfo.Arguments = ($quoted -join ' ')

    $display = "$FilePath $($startInfo.Arguments)"

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
    } catch {
        return [pscustomobject]@{
            command  = $display
            exitCode = -1
            stdout   = @()
            stderr   = @("进程启动失败：$($_.Exception.Message)")
            timedOut = $false
        }
    }

    # 两个流必须异步读取，否则输出量一大就会互相堵死。
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    $timedOut = -not $exited
    if ($timedOut) {
        try { $process.Kill() } catch { }
        try { [void]$process.WaitForExit(5000) } catch { }
    }

    $stdoutText = ''
    $stderrText = ''
    try { $stdoutText = $stdoutTask.Result } catch { }
    try { $stderrText = $stderrTask.Result } catch { }

    $exitCode = if ($timedOut) { -1 } else { $process.ExitCode }
    $process.Dispose()

    $stdoutLines = @()
    if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
        $stdoutLines = @($stdoutText -split "\r?\n" | Where-Object { $_ -ne '' })
    }
    $stderrLines = @()
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
        $stderrLines = @($stderrText -split "\r?\n" | Where-Object { $_ -ne '' })
    }

    return [pscustomobject]@{
        command  = $display
        exitCode = $exitCode
        stdout   = $stdoutLines
        stderr   = $stderrLines
        timedOut = $timedOut
    }
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )

    # core.quotepath=false：让含中文的路径原样输出，便于直接把路径交给用户。
    $full = @('-C', $RepoRoot, '-c', 'core.quotepath=false') + @($Arguments)
    $result = Invoke-NativeCapture -FilePath 'git' -Arguments $full -TimeoutSeconds $TimeoutSeconds

    return [pscustomobject]@{
        command  = $result.command
        exitCode = $result.exitCode
        stdout   = $result.stdout
        stderr   = $result.stderr
        timedOut = $result.timedOut
    }
}

# ---------------------------------------------------------------------------
# 结果契约
# ---------------------------------------------------------------------------

function New-GitSkillResult {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Reason = '',
        [string]$RepoRoot,
        [string]$ErrorCode,
        [object]$Data,
        [object[]]$CommandsRun = @(),
        [string[]]$NextActions = @()
    )

    if ($null -eq $Data) { $Data = [pscustomobject]@{} }
    if ($null -eq $ErrorCode) { $ErrorCode = '' }

    return [pscustomobject]@{
        schemaVersion = 1
        success       = ($Status -eq 'ok')
        status        = $Status
        action        = $Action
        repoRoot      = $RepoRoot
        errorCode     = $(if ([string]::IsNullOrWhiteSpace($ErrorCode)) { $null } else { $ErrorCode })
        reason        = $Reason
        data          = $Data
        commandsRun   = @($CommandsRun | ForEach-Object {
                [pscustomobject]@{ command = $_.command; exitCode = $_.exitCode }
            })
        nextActions   = @($NextActions)
    }
}

function Write-GitSkillResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [string]$OutputJson
    )

    $json = $Result | ConvertTo-Json -Depth 12

    if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
        $parent = Split-Path -Parent $OutputJson
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        # 用无 BOM 的 UTF-8 写，避免下游按字节读取时多出 ﻿。
        [System.IO.File]::WriteAllText($OutputJson, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    Write-GitSkillStdout -Text $json

    # 退出码约定：0 正常，1 判定为阻塞（需要用户决定），2 执行出错。
    $code = switch ($Result.status) {
        'ok' { 0 }
        'blocked' { 1 }
        default { 2 }
    }
    exit $code
}

function Write-GitSkillFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$RepoRoot,
        [object[]]$CommandsRun = @(),
        [string[]]$NextActions = @()
    )

    $result = New-GitSkillResult -Action $Action -Status 'error' -Reason $Reason `
        -RepoRoot $RepoRoot -ErrorCode $ErrorCode -CommandsRun $CommandsRun -NextActions $NextActions
    Write-GitSkillResult -Result $result
}

function Write-GitSkillBlocked {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][string]$Reason,
        [string]$RepoRoot,
        [object]$Data,
        [object[]]$CommandsRun = @(),
        [string[]]$NextActions = @()
    )

    $result = New-GitSkillResult -Action $Action -Status 'blocked' -Reason $Reason `
        -RepoRoot $RepoRoot -ErrorCode $ErrorCode -Data $Data `
        -CommandsRun $CommandsRun -NextActions $NextActions
    Write-GitSkillResult -Result $result
}

# ---------------------------------------------------------------------------
# 仓库读取
# ---------------------------------------------------------------------------

function Get-GitRepoRoot {
    param([string]$StartPath)

    $workingDirectory = if ([string]::IsNullOrWhiteSpace($StartPath)) { (Get-Location).Path } else { $StartPath }
    $result = Invoke-NativeCapture -FilePath 'git' -Arguments @('rev-parse', '--show-toplevel') -WorkingDirectory $workingDirectory

    if ($result.exitCode -ne 0 -or @($result.stdout).Count -eq 0) {
        return [pscustomobject]@{ ok = $false; root = $null; result = $result }
    }

    $root = ([string]$result.stdout[0]).Trim() -replace '/', '\'
    return [pscustomobject]@{ ok = $true; root = $root; result = $result }
}

function Get-GitWorktrees {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('worktree', 'list', '--porcelain')

    if ($result.exitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; worktrees = @(); result = $result }
    }

    $worktrees = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in @($result.stdout)) {
        $text = [string]$line

        if ($text.StartsWith('worktree ')) {
            if ($null -ne $current) { $worktrees.Add($current) }
            $current = [pscustomobject]@{
                path       = ($text.Substring(9).Trim() -replace '/', '\')
                head       = $null
                branch     = $null
                detached   = $false
                bare       = $false
                locked     = $false
                prunable   = $false
                isMain     = $false
            }
            continue
        }

        if ($null -eq $current) { continue }

        if ($text.StartsWith('HEAD ')) { $current.head = $text.Substring(5).Trim(); continue }
        if ($text.StartsWith('branch ')) {
            $ref = $text.Substring(7).Trim()
            $current.branch = $ref -replace '^refs/heads/', ''
            continue
        }
        if ($text -eq 'detached') { $current.detached = $true; continue }
        if ($text -eq 'bare') { $current.bare = $true; continue }
        if ($text.StartsWith('locked')) { $current.locked = $true; continue }
        if ($text.StartsWith('prunable')) { $current.prunable = $true; continue }
    }

    if ($null -ne $current) { $worktrees.Add($current) }

    # git worktree list 的第一条即主工作目录。
    $items = @($worktrees.ToArray())
    if ($items.Count -gt 0) { $items[0].isMain = $true }

    return [pscustomobject]@{ ok = $true; worktrees = $items; result = $result }
}

function Get-GitCurrentBranch {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('branch', '--show-current')
    $branch = ''
    if (@($result.stdout).Count -gt 0) { $branch = ([string]$result.stdout[0]).Trim() }

    return [pscustomobject]@{
        ok       = ($result.exitCode -eq 0)
        branch   = $branch
        # 游离头指针时 --show-current 返回空串，这是最省事的判定方式。
        detached = [string]::IsNullOrWhiteSpace($branch)
        result   = $result
    }
}

function Test-ProtectedBranch {
    param([string]$Branch)

    if ([string]::IsNullOrWhiteSpace($Branch)) { return $true }
    return (@('main', 'master', 'production', 'staging') -contains $Branch.Trim().ToLowerInvariant())
}

# ---------------------------------------------------------------------------
# 工作区拓扑
# ---------------------------------------------------------------------------

function Get-GitMainWorktree {
    param([Parameter(Mandatory = $true)][object[]]$Worktrees)

    # git worktree list 已把主工作目录标记为 isMain；没有标记时退回第一条。
    $main = @($Worktrees | Where-Object { $_.isMain } | Select-Object -First 1)
    if ($main.Count -gt 0) { return $main[0] }
    if (@($Worktrees).Count -gt 0) { return @($Worktrees)[0] }
    return $null
}

function Get-GitCurrentWorktree {
    param(
        [Parameter(Mandatory = $true)][object[]]$Worktrees,
        [Parameter(Mandatory = $true)][string]$CurrentDirectory
    )

    # 路径最长的那条命中：当前目录可能落在某个工作区的子目录里。
    $match = @($Worktrees | Where-Object {
            (Get-GitPathComparison -Left $_.path -Right $CurrentDirectory) -or
            $CurrentDirectory.StartsWith($_.path, [System.StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object { $_.path.Length } -Descending | Select-Object -First 1)

    if ($match.Count -eq 0) { return $null }
    return $match[0]
}

function Find-GitWorktreeByName {
    param(
        [Parameter(Mandatory = $true)][object[]]$Worktrees,
        [Parameter(Mandatory = $true)][string]$Name
    )

    # 目录名、规范化目录名、分支名三种写法都接受。
    $needle = $Name.Trim()
    $directoryName = ConvertTo-WorktreeDirectoryName -Name $needle
    $normalizedBranch = $needle -replace '/', '-'

    # 包一层对象返回：PowerShell 函数直接返回空数组会被解包成 $null，
    # 调用方再包一次 @() 就会得到一个「含一个 $null 的数组」，误判成命中。
    $matches = @($Worktrees | Where-Object {
            (Get-GitPathComparison -Left (Split-Path -Leaf $_.path) -Right $needle) -or
            (Get-GitPathComparison -Left (Split-Path -Leaf $_.path) -Right $directoryName) -or
            ($null -ne $_.branch -and (Get-GitPathComparison -Left ($_.branch -replace '/', '-') -Right $normalizedBranch))
        })

    return [pscustomobject]@{ matches = $matches }
}

function Get-GitLocalBranches {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @(
        'for-each-ref', '--format=%(refname:short)', 'refs/heads'
    )

    if ($result.exitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; branches = @(); result = $result }
    }

    $branches = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($result.stdout)) {
        $name = ([string]$line).Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) { $branches.Add($name) }
    }

    return [pscustomobject]@{ ok = $true; branches = @($branches.ToArray()); result = $result }
}

function Test-GitLocalBranchExists {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    $list = Get-GitLocalBranches -RepoRoot $RepoRoot
    if (-not $list.ok) {
        return [pscustomobject]@{ ok = $false; exists = $false; result = $list.result }
    }

    $match = @($list.branches | Where-Object { (Get-GitPathComparison -Left $_ -Right $Branch) })
    return [pscustomobject]@{ ok = $true; exists = ($match.Count -gt 0); result = $list.result }
}

function Get-GitBranchRefs {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$ComparedTo
    )

    # 一次 for-each-ref 取全部本地与远端分支，避免逐分支 fork（每次 rev-list 约 128ms）。
    # ahead-behind 原子的输出是「领先 落后」，与 rev-list --left-right --count 的
    # 左=落后 右=领先 相反；判「已合并」看的是第一列。改动前先交叉验证。
    # subject 放最后一列，含制表符时不会被误当成字段分隔。
    $atoms = @(
        '%(refname:short)'
        '%(objectname:short)'
        '%(committerdate:iso-strict)'
        '%(upstream:short)'
        '%(upstream:trackshort)'
        $(if ([string]::IsNullOrWhiteSpace($ComparedTo)) { '' } else { "%(ahead-behind:$ComparedTo)" })
        '%(subject)'
    )
    $format = $atoms -join '%09'

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @(
        'for-each-ref', "--format=$format", '--sort=-committerdate', 'refs/heads', 'refs/remotes/origin'
    )

    if ($result.exitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; refs = @(); result = $result }
    }

    $refs = New-Object System.Collections.Generic.List[object]

    foreach ($line in @($result.stdout)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $parts = $text -split "`t"
        if ($parts.Count -lt 7) { continue }

        $shortName = $parts[0].Trim()
        $isRemote = $shortName.StartsWith('origin/', [System.StringComparison]::Ordinal)
        $name = if ($isRemote) { $shortName.Substring(7) } else { $shortName }

        # origin/HEAD 是符号引用，不是一条真实的分支迭代。
        if ($isRemote -and $name -eq 'HEAD') { continue }

        $committedAt = $null
        try {
            $committedAt = [datetime]::Parse($parts[2].Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            # 解析失败就留空，由调用方按「时间未知」处理，不要拿当前时间顶替。
        }

        # 原子为空说明无法比较（通常是 ComparedTo 那个引用不存在），此时不能推断。
        $ahead = $null
        $behind = $null
        $pair = $parts[5].Trim()
        if (-not [string]::IsNullOrWhiteSpace($pair)) {
            $numbers = $pair -split '\s+'
            if ($numbers.Count -ge 2) {
                $ahead = [int]$numbers[0]
                $behind = [int]$numbers[1]
            }
        }

        $refs.Add([pscustomobject]@{
            name        = $name
            shortName   = $shortName
            isRemote    = $isRemote
            refName     = $(if ($isRemote) { "refs/remotes/$shortName" } else { "refs/heads/$name" })
            tip         = $parts[1].Trim()
            committedAt = $committedAt
            upstream    = $parts[3].Trim()
            trackShort  = $parts[4].Trim()
            ahead       = $ahead
            behind      = $behind
            subject     = ($parts[6..($parts.Count - 1)] -join "`t").Trim()
        })
    }

    return [pscustomobject]@{ ok = $true; refs = @($refs.ToArray()); result = $result }
}

function Get-GitBranchRecentLog {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Ref,
        [int]$Count = 3
    )

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @(
        'log', "-n$Count", '--date=short', '--format=%h%x09%ad%x09%s', $Ref
    )

    $commits = New-Object System.Collections.Generic.List[object]
    if ($result.exitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; commits = @(); result = $result }
    }

    foreach ($line in @($result.stdout)) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $parts = $text -split "`t"
        if ($parts.Count -lt 3) { continue }
        $commits.Add([pscustomobject]@{
            hash    = $parts[0].Trim()
            date    = $parts[1].Trim()
            subject = ($parts[2..($parts.Count - 1)] -join "`t").Trim()
        })
    }

    return [pscustomobject]@{ ok = $true; commits = @($commits.ToArray()); result = $result }
}

function Get-GitCandidateBranches {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$Target,
        [int]$SinceDays = 30,
        [int]$Top = 20,
        [int]$DetailTop = 10,
        [int]$RecentSubjectCount = 3,
        [object[]]$Worktrees = @()
    )

    $commands = New-Object System.Collections.Generic.List[object]

    # 计数必须预先声明：StrictMode 2.0 下给 [pscustomobject] 追加新属性会抛异常。
    $excluded = [pscustomobject]@{
        protectedBranch    = 0
        tooOld             = 0
        undated            = 0
        merged             = 0
        mergedWithWorktree = 0
    }

    $targetRef = $null
    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        $probe = Test-GitRemoteRefExists -RepoRoot $RepoRoot -Ref "refs/remotes/origin/$Target"
        $commands.Add($probe.result)
        if ($probe.exists) { $targetRef = "refs/remotes/origin/$Target" }
    }

    $refs = Get-GitBranchRefs -RepoRoot $RepoRoot -ComparedTo $targetRef
    if ($null -ne $refs.result) { $commands.Add($refs.result) }

    if (-not $refs.ok) {
        return [pscustomobject]@{
            ok = $false; candidates = @(); excluded = $excluded
            totalScanned = 0; targetRef = $targetRef; commands = @($commands.ToArray())
        }
    }

    $local = @{}
    $remote = @{}
    foreach ($ref in @($refs.refs)) {
        if ($ref.isRemote) {
            if (-not $remote.ContainsKey($ref.name)) { $remote[$ref.name] = $ref }
        } else {
            $local[$ref.name] = $ref
        }
    }

    # 本地优先：本地分支带 upstream 与跟踪状态，且工作区只能挂在本地分支上。
    $names = @($local.Keys) + @($remote.Keys | Where-Object { -not $local.ContainsKey($_) })

    $cutoff = (Get-Date).AddDays(-1 * $SinceDays)
    $survivors = New-Object System.Collections.Generic.List[object]

    foreach ($name in $names) {
        if (Test-ProtectedBranch -Branch $name) { $excluded.protectedBranch++; continue }

        $ref = if ($local.ContainsKey($name)) { $local[$name] } else { $remote[$name] }

        if ($null -eq $ref.committedAt) { $excluded.undated++; continue }
        if ($ref.committedAt -lt $cutoff) { $excluded.tooOld++; continue }

        # 领先为 0 说明它没有任何提交是集成分支没有的 —— 这个迭代已经结束了。
        # 但「已挂工作区」必须留例外：刚建好、还没提交的工作区分支领先同样是 0，
        # 按已合并丢掉它，用户回头找这个迭代就找不到，会以为没在做而重开一个。
        $attached = @(@($Worktrees) | Where-Object { $null -ne $_.branch -and $_.branch -eq $ref.name })
        if ($null -ne $targetRef -and $ref.ahead -eq 0) {
            if ($attached.Count -eq 0) { $excluded.merged++; continue }
            $excluded.mergedWithWorktree++
        }

        $survivors.Add($ref)
    }

    # 先按最后提交时间倒排再截断，保证留下的确实是「最近」的那批。
    $ordered = @($survivors.ToArray() | Sort-Object -Property @{ Expression = { $_.committedAt }; Descending = $true })
    $totalScanned = $ordered.Count
    if ($ordered.Count -gt $Top) { $ordered = @($ordered[0..($Top - 1)]) }

    $now = Get-Date
    $index = 0
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($ref in $ordered) {
        $worktree = @($Worktrees) | Where-Object {
            $null -ne $_.branch -and ($_.branch -eq $ref.name)
        } | Select-Object -First 1

        # 拉每个分支的最近几条提交是逐分支 fork（每次约 128ms），所以只对
        # 最可能被选中的前 DetailTop 个做，其余靠分支名与末端提交标题判断。
        $recent = @()
        if ($index -lt $DetailTop) {
            $log = Get-GitBranchRecentLog -RepoRoot $RepoRoot -Ref $ref.refName -Count $RecentSubjectCount
            if ($null -ne $log.result) { $commands.Add($log.result) }
            if ($log.ok) { $recent = @($log.commits) }
        }

        $items.Add([pscustomobject]@{
            name            = $ref.name
            localOnly       = (-not $ref.isRemote -and -not $remote.ContainsKey($ref.name))
            remoteOnly      = $ref.isRemote
            tip             = $ref.tip
            committedAt     = $(if ($null -eq $ref.committedAt) { $null } else { $ref.committedAt.ToString('yyyy-MM-dd HH:mm') })
            daysAgo         = $(if ($null -eq $ref.committedAt) { $null } else { [int]($now - $ref.committedAt).TotalDays })
            tipSubject      = $ref.subject
            recentCommits   = @($recent)
            hasUpstream     = (-not [string]::IsNullOrWhiteSpace($ref.upstream))
            upstream        = $ref.upstream
            aheadOfUpstream = $(if ($ref.trackShort -like '*>*') { $true } elseif ([string]::IsNullOrWhiteSpace($ref.trackShort)) { $null } else { $false })
            aheadOfTarget   = $ref.ahead
            behindTarget    = $ref.behind
            hasWorktree     = ($null -ne $worktree)
            worktreePath    = $(if ($null -eq $worktree) { $null } else { $worktree.path })
            worktreeIsMain  = $(if ($null -eq $worktree) { $null } else { $worktree.isMain })
        })
        $index++
    }

    return [pscustomobject]@{
        ok           = $true
        candidates   = @($items.ToArray())
        excluded     = $excluded
        totalScanned = $totalScanned
        targetRef    = $targetRef
        commands     = @($commands.ToArray())
    }
}

function Get-GitStatusEntries {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('status', '--porcelain=v1', '-z', '-uall')

    if ($result.exitCode -ne 0) {
        return [pscustomobject]@{ ok = $false; entries = @(); result = $result }
    }

    # -z 用 NUL 分隔记录，含空格和中文的路径都不需要额外反转义。
    $text = [string]::Join("`n", @($result.stdout))
    $tokens = @($text -split [char]0 | Where-Object { $_ -ne '' })
    $entries = New-Object System.Collections.Generic.List[object]

    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = [string]$tokens[$i]
        if ($token.Length -lt 4) { continue }

        $xy = $token.Substring(0, 2)
        $path = $token.Substring(3)
        $originalPath = $null

        # 重命名/复制在 -z 模式下把原路径作为下一条记录跟在后面。
        if ($xy[0] -eq 'R' -or $xy[0] -eq 'C') {
            if (($i + 1) -lt $tokens.Count) {
                $i++
                $originalPath = [string]$tokens[$i]
            }
        }

        $entries.Add([pscustomobject]@{
            xy           = $xy
            path         = $path
            originalPath = $originalPath
            isStaged     = ($xy -ne '??' -and $xy[0] -ne ' ')
            isUntracked  = ($xy -eq '??')
        })
    }

    return [pscustomobject]@{ ok = $true; entries = @($entries.ToArray()); result = $result }
}

function Test-GitRemoteRefExists {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Ref
    )

    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('rev-parse', '--verify', '--quiet', $Ref)
    return [pscustomobject]@{ exists = ($result.exitCode -eq 0); result = $result }
}

function Get-GitAheadBehind {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Range
    )

    # left = 左侧独有（落后目标的数量），right = 右侧独有（领先目标的数量）。
    $result = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments @('rev-list', '--left-right', '--count', $Range)
    if ($result.exitCode -ne 0 -or @($result.stdout).Count -eq 0) {
        return [pscustomobject]@{ ok = $false; left = $null; right = $null; result = $result }
    }

    $parts = (([string]$result.stdout[0]).Trim() -split '\s+')
    if ($parts.Count -lt 2) {
        return [pscustomobject]@{ ok = $false; left = $null; right = $null; result = $result }
    }

    return [pscustomobject]@{
        ok     = $true
        left   = [int]$parts[0]
        right  = [int]$parts[1]
        result = $result
    }
}

# ---------------------------------------------------------------------------
# 目标分支解析
# ---------------------------------------------------------------------------

function Resolve-GitTargetBranch {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$Requested,
        [string[]]$Candidates = @('main', 'production')
    )

    # 优先级：用户显式指定 > 主工作目录当前所在分支 > 远端唯一存在的集成分支。
    # 三者都定不下来就停下询问，绝不猜。
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $explicit = $Requested.Trim()
        $exists = Test-GitRemoteRefExists -RepoRoot $RepoRoot -Ref "refs/remotes/origin/$explicit"
        if (-not $exists.exists) {
            return [pscustomobject]@{
                ok = $false; branch = $null; source = $null
                reason = "指定的目标分支 origin/$explicit 不存在。"
                candidates = @()
            }
        }
        return [pscustomobject]@{
            ok = $true; branch = $explicit; source = 'explicit'
            reason = "目标分支取用户显式指定的 $explicit。"
            candidates = @($explicit)
        }
    }

    $worktreeInfo = Get-GitWorktrees -RepoRoot $RepoRoot
    if ($worktreeInfo.ok) {
        $mainWorktree = @($worktreeInfo.worktrees) | Where-Object { $_.isMain } | Select-Object -First 1
        if ($null -ne $mainWorktree -and -not $mainWorktree.detached -and -not [string]::IsNullOrWhiteSpace($mainWorktree.branch)) {
            $mainBranch = $mainWorktree.branch.Trim().ToLowerInvariant()
            if ($Candidates -contains $mainBranch) {
                return [pscustomobject]@{
                    ok = $true; branch = $mainBranch; source = 'main-worktree-branch'
                    reason = "主工作目录当前在 $mainBranch 上，据此确定集成分支。"
                    candidates = @($mainBranch)
                }
            }
        }
    }

    $present = @()
    foreach ($name in $Candidates) {
        $exists = Test-GitRemoteRefExists -RepoRoot $RepoRoot -Ref "refs/remotes/origin/$name"
        if ($exists.exists) { $present += $name }
    }

    if ($present.Count -eq 1) {
        return [pscustomobject]@{
            ok = $true; branch = $present[0]; source = 'single-remote-candidate'
            reason = "候选集成分支里只有 origin/$($present[0]) 存在。"
            candidates = $present
        }
    }

    return [pscustomobject]@{
        ok = $false; branch = $null; source = 'ambiguous'
        reason = '无法判断该并入 main 还是 production。请向用户确认后显式传入目标分支。'
        candidates = $present
    }
}

# ---------------------------------------------------------------------------
# 工作区命名
# ---------------------------------------------------------------------------

function Get-GitSkillWorktreesRoot {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return (Join-Path $RepoRoot '.claude\worktree')
}

function ConvertTo-WorktreeDirectoryName {
    param([Parameter(Mandatory = $true)][string]$Name)

    # 约定：目录名用 '-' 分隔，分支名用 '/' 分隔。
    $normalized = $Name.Trim()
    $normalized = $normalized -replace '^refs/heads/', ''
    $normalized = $normalized -replace '/', '-'
    $normalized = $normalized -replace '[^0-9A-Za-z\-\._]', '-'
    $normalized = $normalized -replace '-{2,}', '-'
    return $normalized.Trim('-')
}

function Get-GitPathComparison {
    param([string]$Left, [string]$Right)

    $a = ([string]$Left).TrimEnd('\', '/') -replace '/', '\'
    $b = ([string]$Right).TrimEnd('\', '/') -replace '/', '\'
    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------------------
# 工作区创建
# ---------------------------------------------------------------------------

function Assert-GitNotInsideLinkedWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Action,
        [object]$Log,
        [object]$CurrentWorktree,
        [object]$MainWorktree,
        [string]$CurrentDirectory
    )

    if ($null -eq $CurrentWorktree -or $CurrentWorktree.isMain) { return }

    Write-GitSkillBlocked -Action $Action -ErrorCode 'nested-worktree-forbidden' `
        -Reason "当前目录位于链接工作区 $($CurrentWorktree.path) 内。请先切回主工作目录 $($MainWorktree.path)。" `
        -RepoRoot $RepoRoot `
        -Data ([pscustomobject]@{ currentPath = $CurrentDirectory; mainWorktree = $MainWorktree.path }) `
        -CommandsRun $Log `
        -NextActions @("Set-Location -LiteralPath '$($MainWorktree.path)'")
}

function Get-GitSkillWorktreeTargetPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Action,
        [object]$Log
    )

    $directoryName = ConvertTo-WorktreeDirectoryName -Name $Name
    if ([string]::IsNullOrWhiteSpace($directoryName)) {
        Write-GitSkillBlocked -Action $Action -ErrorCode 'invalid-worktree-name' `
            -Reason "工作区名称 $Name 规范化后是空目录名。" -RepoRoot $RepoRoot -CommandsRun $Log
    }

    $targetPath = Join-Path (Get-GitSkillWorktreesRoot -RepoRoot $RepoRoot) $directoryName
    if (Test-Path -LiteralPath $targetPath) {
        Write-GitSkillBlocked -Action $Action -ErrorCode 'target-path-exists' `
            -Reason "目标路径 $targetPath 已存在。" -RepoRoot $RepoRoot `
            -Data ([pscustomobject]@{ targetPath = $targetPath }) -CommandsRun $Log
    }

    return [pscustomobject]@{ directoryName = $directoryName; targetPath = $targetPath }
}

function Add-GitSkillWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Action,
        [object]$Log
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $TargetPath) | Out-Null

    $add = Invoke-GitCommand -RepoRoot $RepoRoot -Arguments $Arguments
    if ($null -ne $Log) { [void]$Log.Add($add) }
    if ($add.exitCode -ne 0) {
        Write-GitSkillFailure -Action $Action -ErrorCode 'worktree-add-failed' `
            -Reason "git worktree add 失败：$(@($add.stderr) -join ' ')" `
            -RepoRoot $RepoRoot -CommandsRun $Log
    }

    # 退出码为 0 不等于真的建好了，回读工作区列表核对。
    $verify = Get-GitWorktrees -RepoRoot $RepoRoot
    if ($null -ne $Log) { [void]$Log.Add($verify.result) }
    $created = @($verify.worktrees | Where-Object { (Get-GitPathComparison -Left $_.path -Right $TargetPath) })

    if ($created.Count -eq 0) {
        Write-GitSkillFailure -Action $Action -ErrorCode 'worktree-create-unverified' `
            -Reason "git worktree add 报告成功，但 $TargetPath 未出现在工作区列表里。" `
            -RepoRoot $RepoRoot -CommandsRun $Log
    }

    return $created[0]
}

function New-GitSkillCdFields {
    param([Parameter(Mandatory = $true)][string]$Path)

    # 子进程改不了父 Shell 的当前目录，所以只给出命令；由调用方自己执行并回读确认。
    return [pscustomobject]@{
        cdCommand       = "Set-Location -LiteralPath '$Path'"
        parentShellNote = '由调用方（AI）自己执行 cdCommand，再用 (Get-Location).Path 回读确认；不要把命令丢给用户。'
    }
}
