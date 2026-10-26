# AI Observer 查看器 —— 只读聚合，不写任何文件、不改任何配置
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Mode versions
#   powershell -NoProfile -ExecutionPolicy Bypass -File report.ps1 -Skill git -Since 2026-09-01
#
# 注意：本文件必须保持 UTF-8 with BOM，否则 Windows PowerShell 5.1 按 ANSI 读取会解析失败。

[CmdletBinding()]
param(
    [ValidateSet('summary', 'versions', 'detail', 'content')]
    [string]$Mode = 'summary',
    [string[]]$Skill = @(),
    [string]$Project = '',
    [datetime]$Since = [datetime]::MinValue,
    [datetime]$Until = [datetime]::MinValue,
    [int]$Top = 20,
    [string]$LogRoot = ''
)

$ErrorActionPreference = 'Stop'

$script:UnknownVersion = '(未记录版本)'

function Resolve-ViewLogRoot {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override }
    return (Join-Path (Join-Path $env:USERPROFILE '.claude') 'ai-observer\logs')
}

function Read-ViewRecords {
    param([string]$Root)

    $dir = Join-Path $Root 'skills'
    $list = New-Object System.Collections.Generic.List[object]
    if (-not [System.IO.Directory]::Exists($dir)) { return $list }

    foreach ($file in (Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
        # 观察器可能正在追加同一个文件，因此按行读并在单行解析失败时跳过，不整体失败。
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $list.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
        }
    }
    return $list
}

function Select-ViewRecords {
    param($Records, [string[]]$SkillPatterns, [string]$ProjectName, [datetime]$From, [datetime]$To)

    $hasFrom = ($From -ne [datetime]::MinValue)
    $hasTo = ($To -ne [datetime]::MinValue)

    $fromUtc = [datetime]::MinValue
    if ($hasFrom) { $fromUtc = $From.ToUniversalTime() }

    $toUtc = [datetime]::MaxValue
    if ($hasTo) {
        # 只给日期（时间为 0 点）时视为"含当天整日"，否则用户要手写 23:59 才能包含当天。
        if ($To.TimeOfDay -eq [timespan]::Zero) { $toUtc = $To.Date.AddDays(1).AddTicks(-1).ToUniversalTime() }
        else { $toUtc = $To.ToUniversalTime() }
    }

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($r in $Records) {
        if ($SkillPatterns.Count -gt 0) {
            $hit = $false
            foreach ($p in $SkillPatterns) { if ([string]$r.skillName -like $p) { $hit = $true; break } }
            if (-not $hit) { continue }
        }
        if (-not [string]::IsNullOrWhiteSpace($ProjectName) -and [string]$r.project -ne $ProjectName) { continue }

        if ($hasFrom -or $hasTo) {
            $t = $null
            try {
                $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
                $t = [datetime]::Parse([string]$r.ts, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
            } catch { $t = $null }
            if ($null -eq $t) { continue }
            if ($t -lt $fromUtc -or $t -gt $toUtc) { continue }
        }
        $out.Add($r)
    }
    return $out
}

function Get-ViewText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [string]$Value
}

function Get-ViewCallKey {
    param($Record)

    # 关联 skill_start / skill_end / skill_end_revised 的首选键是 toolUseId：
    # 它是转录里那条 tool_use 的 id，模型调用路径下每次调用唯一，且 2026-09-17 之前的
    # 记录就已经在写它，所以旧数据也能正确关联。
    $skill = Get-ViewText $Record.skillName
    $tid = Get-ViewText $Record.toolUseId
    if (-not [string]::IsNullOrEmpty($tid)) { return $skill + '#' + $tid }

    # 手敲 /skill 没有工具调用，toolUseId 为空，退回 startedUtc。
    $s = Get-ViewText $Record.startedUtc
    if (-not [string]::IsNullOrEmpty($s)) { return $skill + '@' + $s }

    # 最旧的斜杠记录两者都没有：只能按 ts 兜底。
    # 关键是不能让它们全部塌进同一个键，否则多条记录会被折叠成一条。
    return $skill + '@ts:' + (Get-ViewText $Record.ts)
}

function Get-ViewRevisionKey {
    param($Record)

    $skill = Get-ViewText $Record.skillName
    $tid = Get-ViewText $Record.toolUseId
    if (-not [string]::IsNullOrEmpty($tid)) { return $skill + '#' + $tid }

    $s = Get-ViewText $Record.revisesSkillStartUtc
    if (-not [string]::IsNullOrEmpty($s)) { return $skill + '@' + $s }

    return ''
}

function Get-ViewEnds {
    param($Records)

    $map = [ordered]@{}
    $orphans = 0
    foreach ($r in $Records) {
        if ($r.eventType -ne 'skill_end') { continue }
        $k = Get-ViewCallKey -Record $r
        if ($map.Contains($k)) { continue }
        $map[$k] = [ordered]@{
            Record     = $r
            Skill      = Get-ViewText $r.skillName
            Hash       = Get-ViewText $r.skillHash
            StartedUtc = Get-ViewText $r.startedUtc
            EndTs      = Get-ViewText $r.ts
            EndTsLocal = Get-ViewText $r.tsLocal
            Duration   = $r.durationMs
            EndReason  = Get-ViewText $r.endReason
            Complete   = $r.metrics.complete
            Files      = $r.metrics.filesChanged
            Commands   = $r.metrics.commandsExecuted
            Chars      = $r.metrics.assistantOutputChars
            Revised    = $false
        }
    }

    # skill_end_revised 是对同一窗口的补正：指标以补正为准，但 durationMs 只有原始记录才有。
    # 它绝不能凭空生成一次新调用 —— 关联不上时只计为孤立补正，否则闭合数会超过调用数。
    foreach ($r in $Records) {
        if ($r.eventType -ne 'skill_end_revised') { continue }
        $k = Get-ViewRevisionKey -Record $r
        if ([string]::IsNullOrEmpty($k) -or -not $map.Contains($k)) { $orphans++; continue }
        $map[$k].Files = $r.metrics.filesChanged
        $map[$k].Commands = $r.metrics.commandsExecuted
        $map[$k].Chars = $r.metrics.assistantOutputChars
        $map[$k].Complete = $r.metrics.complete
        $map[$k].Revised = $true
    }

    return [ordered]@{ Map = $map; Orphans = $orphans }
}

function Get-ViewSum {
    param($Values)
    $s = (@($Values | Where-Object { $null -ne $_ }) | Measure-Object -Sum).Sum
    if ($null -eq $s) { return 0 }
    return [int]$s
}

function Get-ViewAvg {
    param($Values)
    $v = @($Values | Where-Object { $null -ne $_ })
    if ($v.Count -eq 0) { return $null }
    return (($v | Measure-Object -Average).Average)
}

function Get-ViewPercentile {
    param($Values, [double]$P)
    $v = @($Values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $idx = [int][Math]::Ceiling($P * $v.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $v.Count) { $idx = $v.Count - 1 }
    return $v[$idx]
}

function Format-ViewSeconds {
    param($Ms)
    if ($null -eq $Ms) { return '-' }
    return [string][math]::Round(([double]$Ms) / 1000, 1)
}

function Get-ViewTrustLabel {
    param($Complete)
    # metrics 为 null 时（技能体加载后没产出窗口）可信度是未知，不能默认成"是"。
    if ($null -eq $Complete) { return '-' }
    if ($Complete -eq $false) { return '否' }
    return '是'
}

function Format-ViewVersion {
    param([string]$Hash)
    if ([string]::IsNullOrEmpty($Hash)) { return $script:UnknownVersion }
    return $Hash
}

function Format-ViewText {
    param([string]$Text, [int]$Max = 80)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -gt $Max) { return $flat.Substring(0, $Max) + '...' }
    return $flat
}

function Show-ViewSummary {
    param($Records, $Ends, [int]$Top)

    $starts = @($Records | Where-Object { $_.eventType -eq 'skill_start' })
    if ($starts.Count -eq 0) { Write-Output '没有匹配的 skill_start 记录。'; return }

    $names = @($starts | Group-Object skillName | Sort-Object Count -Descending | Select-Object -First $Top | ForEach-Object { $_.Name })

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        $s = @($starts | Where-Object { $_.skillName -eq $n })
        $userCount = @($s | Where-Object { $_.invocation -eq 'user' }).Count
        $modelCount = @($s | Where-Object { $_.invocation -eq 'model' }).Count
        $e = @($Ends.Map.Values | Where-Object { $_.Skill -eq $n })
        $durs = @($e | ForEach-Object { $_.Duration })

        $rows.Add([pscustomobject]@{
            '技能'       = $n
            '调用'       = $s.Count
            '用户/模型'  = "$userCount/$modelCount"
            '闭合'       = $e.Count
            '均值s'      = Format-ViewSeconds (Get-ViewAvg $durs)
            '中位s'      = Format-ViewSeconds (Get-ViewPercentile $durs 0.5)
            'P95s'       = Format-ViewSeconds (Get-ViewPercentile $durs 0.95)
            '改文件'     = Get-ViewSum ($e | ForEach-Object { $_.Files })
            '命令'       = Get-ViewSum ($e | ForEach-Object { $_.Commands })
            '掉线'       = @($e | Where-Object { $_.Complete -eq $false }).Count
        })
    }
    $rows | Format-Table -AutoSize

    $unclosed = $starts.Count - $Ends.Map.Count
    Write-Output '说明：'
    if ($unclosed -ge 0) {
        Write-Output ('  调用 = skill_start 次数；闭合 = 有 skill_end 的次数。差值 ' + $unclosed + ' 通常是尚未结束的当前回合。')
    } else {
        # 闭合多于调用说明有关联不上的结束记录，属于数据异常，必须显式暴露而不是掩盖。
        Write-Output ('  调用 ' + $starts.Count + ' 少于闭合 ' + $Ends.Map.Count + '：有关联不上的结束记录，详见 detail 模式。')
    }
    if ($Ends.Orphans -gt 0) {
        Write-Output ('  另有 ' + $Ends.Orphans + ' 条补正记录无法关联到原始结束记录（改前写入的斜杠调用没有关联键），未计入统计。')
    }
    Write-Output '  掉线 = metrics.complete=false（会话中断导致窗口未正常收尾），这些时长不可信。'
    Write-Output '  窗口时长口径是"技能被调用到本回合结束"，不等于技能独占耗时。'
}

function Show-ViewVersions {
    param($Records, [int]$Top)

    $starts = @($Records | Where-Object { $_.eventType -eq 'skill_start' })
    if ($starts.Count -eq 0) { Write-Output '没有匹配的 skill_start 记录。'; return }

    $groups = [ordered]@{}
    foreach ($s in $starts) {
        $h = Format-ViewVersion (Get-ViewText $s.skillHash)
        $k = (Get-ViewText $s.skillName) + '|' + $h
        if (-not $groups.Contains($k)) {
            $groups[$k] = [ordered]@{
                Skill = Get-ViewText $s.skillName
                Hash  = $h
                Calls = 0
                First = Get-ViewText $s.ts
                Last  = Get-ViewText $s.ts
                Ends  = New-Object System.Collections.Generic.List[object]
            }
        }
        $g = $groups[$k]
        $g.Calls++
        if ((Get-ViewText $s.ts) -lt $g.First) { $g.First = Get-ViewText $s.ts }
        if ((Get-ViewText $s.ts) -gt $g.Last) { $g.Last = Get-ViewText $s.ts }
    }

    foreach ($e in (Get-ViewEnds -Records $Records).Map.Values) {
        $h = Format-ViewVersion $e.Hash
        $k = $e.Skill + '|' + $h
        if ($groups.Contains($k)) { $groups[$k].Ends.Add($e) }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($k in $groups.Keys) {
        $g = $groups[$k]
        $durs = @($g.Ends | ForEach-Object { $_.Duration })
        $rows.Add([pscustomobject]@{
            '技能'   = $g.Skill
            '版本'   = $g.Hash
            '调用'   = $g.Calls
            '首次'   = ($g.First.Substring(0, [Math]::Min(16, $g.First.Length)) -replace 'T', ' ')
            '末次'   = ($g.Last.Substring(0, [Math]::Min(16, $g.Last.Length)) -replace 'T', ' ')
            '均值s'  = Format-ViewSeconds (Get-ViewAvg $durs)
            '中位s'  = Format-ViewSeconds (Get-ViewPercentile $durs 0.5)
            '改文件' = Get-ViewSum ($g.Ends | ForEach-Object { $_.Files })
            '命令'   = Get-ViewSum ($g.Ends | ForEach-Object { $_.Commands })
        })
    }
    $rows | Sort-Object '技能', '首次' | Format-Table -AutoSize

    Write-Output '版本对比（同一技能按最近使用排序的相邻两版）：'
    Write-Output ''
    # 必须用脚本块形式取属性：Sort-Object/Group-Object 对有序字典做属性名绑定会给出错误顺序
    # （实测 Sort-Object Last 在 [ordered] 上得到的是倒序）。按首次出现时间排，即版本先后。
    $bySkill = $groups.Values | Group-Object { $_.Skill }
    $any = $false
    foreach ($grp in $bySkill) {
        $known = @($grp.Group | Where-Object { $_.Hash -ne $script:UnknownVersion } | Sort-Object { $_.First })
        if ($known.Count -lt 2) { continue }
        $any = $true
        $a = $known[$known.Count - 2]
        $b = $known[$known.Count - 1]
        $da = @($a.Ends | ForEach-Object { $_.Duration })
        $db = @($b.Ends | ForEach-Object { $_.Duration })

        $note = ''
        if ($a.Calls -lt 3 -or $b.Calls -lt 3) { $note = '   [样本过少，别据此下结论]' }

        Write-Output ($grp.Name + '  旧 ' + $a.Hash + ' -> 新 ' + $b.Hash + $note)
        Write-Output ('   调用     ' + $a.Calls + ' -> ' + $b.Calls)
        Write-Output ('   均值窗口 ' + (Format-ViewSeconds (Get-ViewAvg $da)) + 's -> ' + (Format-ViewSeconds (Get-ViewAvg $db)) + 's')
        Write-Output ('   改文件   ' + (Get-ViewSum ($a.Ends | ForEach-Object { $_.Files })) + ' -> ' + (Get-ViewSum ($b.Ends | ForEach-Object { $_.Files })))
        Write-Output ('   命令     ' + (Get-ViewSum ($a.Ends | ForEach-Object { $_.Commands })) + ' -> ' + (Get-ViewSum ($b.Ends | ForEach-Object { $_.Commands })))
        Write-Output ''
    }
    if (-not $any) {
        Write-Output '  暂无可对比的版本：同一技能需要至少两个不同的 skillHash 才有对比。'
        Write-Output ('  skillHash 是 2026-09-17 之后才写入的字段，此前的记录都归入 ' + $script:UnknownVersion + '。')
    }
}

function Show-ViewDetail {
    param($Records, [int]$Top)

    $ends = Get-ViewEnds -Records $Records
    if ($ends.Map.Count -eq 0) { Write-Output '没有匹配的 skill_end 记录。'; return }

    $starts = [ordered]@{}
    foreach ($r in $Records) {
        if ($r.eventType -ne 'skill_start') { continue }
        $k = Get-ViewCallKey -Record $r
        if (-not $starts.Contains($k)) { $starts[$k] = $r }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($k in $ends.Map.Keys) {
        $e = $ends.Map[$k]
        $st = $null
        if ($starts.Contains($k)) { $st = $starts[$k] }

        $invocation = ''
        $entry = ''
        if ($null -ne $st) {
            $invocation = Get-ViewText $st.invocation
            $entry = Get-ViewText $st.entry
        }
        $source = $invocation
        if (-not [string]::IsNullOrEmpty($entry)) { $source = $invocation + '/' + $entry }

        $rows.Add([pscustomobject]@{
            '结束时间' = ((Get-ViewText $e.EndTsLocal).Substring(0, [Math]::Min(19, (Get-ViewText $e.EndTsLocal).Length)) -replace 'T', ' ')
            '技能'     = $e.Skill
            '版本'     = Format-ViewVersion $e.Hash
            '来源'     = $source
            '窗口s'    = Format-ViewSeconds $e.Duration
            '结束原因' = $e.EndReason
            '可信'     = (Get-ViewTrustLabel $e.Complete)
            '改文件'   = $e.Files
            '命令'     = $e.Commands
            '输出字符' = $e.Chars
        })
    }
    $rows | Sort-Object '结束时间' -Descending | Select-Object -First $Top | Format-Table -AutoSize
    Write-Output ('共 ' + $ends.Map.Count + ' 条已闭合调用，显示最近 ' + [Math]::Min($Top, $ends.Map.Count) + ' 条。')
    if ($ends.Orphans -gt 0) {
        Write-Output ('另有 ' + $ends.Orphans + ' 条补正记录无法关联到原始记录，未计入。')
    }
    Write-Output ('版本为 ' + $script:UnknownVersion + ' 表示该记录写入时还没有 skillHash 字段（2026-09-17 之前）。')
}

function Show-ViewContent {
    param($Records, [int]$Top)

    $ends = @((Get-ViewEnds -Records $Records).Map.Values)
    if ($ends.Count -eq 0) { Write-Output '没有匹配的 skill_end 记录。'; return }

    $fileCounts = @{}
    $cmdCounts = @{}
    $prefixCounts = @{}
    $haveFiles = 0
    $haveCmds = 0

    foreach ($e in $ends) {
        $m = $e.Record.metrics
        if ($null -eq $m) { continue }

        # 必须先滤掉空值：@($null) 的元素个数是 1 而不是 0，直接判 Count 会把没有内容字段的
        # 旧记录也算成"有内容"，于是下面的空表提示永不触发，输出自相矛盾。
        $paths = @(@($m.FilePaths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($paths.Count -gt 0) {
            $haveFiles++
            foreach ($p in $paths) {
                $key = [string]$p
                if ($fileCounts.ContainsKey($key)) { $fileCounts[$key]++ } else { $fileCounts[$key] = 1 }
            }
        }

        $cmds = @(@($m.Commands) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($cmds.Count -gt 0) {
            $haveCmds++
            foreach ($c in $cmds) {
                $key = Format-ViewText ([string]$c) 100
                if ($cmdCounts.ContainsKey($key)) { $cmdCounts[$key]++ } else { $cmdCounts[$key] = 1 }

                $tokens = @(([string]$c).Trim() -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                $prefix = ''
                if ($tokens.Count -ge 2) { $prefix = $tokens[0] + ' ' + $tokens[1] }
                elseif ($tokens.Count -eq 1) { $prefix = $tokens[0] }
                if (-not [string]::IsNullOrEmpty($prefix)) {
                    if ($prefixCounts.ContainsKey($prefix)) { $prefixCounts[$prefix]++ } else { $prefixCounts[$prefix] = 1 }
                }
            }
        }
    }

    if ($haveFiles -eq 0 -and $haveCmds -eq 0) {
        Write-Output '这些记录里没有文件路径和命令正文。'
        Write-Output '原因通常是：记录写在 2026-09-17 打开采集开关之前，或被过滤掉的技能本来就没有窗口内容。'
        Write-Output '开关在 ~/.claude/ai-observer/config.json 的 capture.storeFilePaths / capture.storeCommandText。'
        return
    }

    Write-Output ('被改动的文件（出现在 ' + $haveFiles + ' 条记录中）：')
    Write-Output ''
    $fileRows = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($fileCounts.Keys | Sort-Object { -$fileCounts[$_] } | Select-Object -First $Top)) {
        $fileRows.Add([pscustomobject]@{ '文件' = $k; '次数' = $fileCounts[$k] })
    }
    $fileRows | Format-Table -AutoSize

    Write-Output ('执行的命令前缀（出现在 ' + $haveCmds + ' 条记录中）：')
    Write-Output ''
    $prefixRows = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($prefixCounts.Keys | Sort-Object { -$prefixCounts[$_] } | Select-Object -First $Top)) {
        $prefixRows.Add([pscustomobject]@{ '命令前缀' = $k; '次数' = $prefixCounts[$k] })
    }
    $prefixRows | Format-Table -AutoSize

    Write-Output ('完整命令（前 ' + $Top + ' 条高频）：')
    Write-Output ''
    $cmdRows = New-Object System.Collections.Generic.List[object]
    foreach ($k in ($cmdCounts.Keys | Sort-Object { -$cmdCounts[$_] } | Select-Object -First $Top)) {
        $cmdRows.Add([pscustomobject]@{ '命令' = $k; '次数' = $cmdCounts[$k] })
    }
    $cmdRows | Format-Table -AutoSize

    Write-Output '注意：命令正文来自转录，可能包含连接串、令牌等敏感字符串。'
    Write-Output '原始转录本身就以明文存于 ~/.claude/projects/ 下，本查看器没有引入新的暴露面，但分享输出前请自行检查。'
}

# ---- 主流程 ----

$root = Resolve-ViewLogRoot -Override $LogRoot
if (-not [System.IO.Directory]::Exists($root)) {
    Write-Output ('日志目录不存在：' + $root)
    exit 0
}

$all = Read-ViewRecords -Root $root
$filtered = Select-ViewRecords -Records $all -SkillPatterns $Skill -ProjectName $Project -From $Since -To $Until

Write-Output ('日志根：' + $root)
$scope = '全部'
if ($Skill.Count -gt 0) { $scope = '技能=' + ($Skill -join ',') }
if (-not [string]::IsNullOrWhiteSpace($Project)) { $scope = $scope + ' 项目=' + $Project }
Write-Output ('范围：' + $scope + '  记录 ' + $filtered.Count + ' 条（原始 ' + $all.Count + ' 条）')
Write-Output ''

switch ($Mode) {
    'summary' { Show-ViewSummary -Records $filtered -Ends (Get-ViewEnds -Records $filtered) -Top $Top }
    'versions' { Show-ViewVersions -Records $filtered -Top $Top }
    'detail' { Show-ViewDetail -Records $filtered -Top $Top }
    'content' { Show-ViewContent -Records $filtered -Top $Top }
}

exit 0
