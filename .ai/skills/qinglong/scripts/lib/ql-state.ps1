# QingLong 状态层：期望态对照 / 调度冲突 / 停滞 / 格式风险
# 依赖 ql-api.ps1、ql-task.ps1
#
# 只报事实与差值，不做因果推断。根因需要证据链时另行取证。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-QlStateReport {
    param($Tasks = $null)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($key in (Get-QlDesiredKeys)) {
        $d = Get-QlDesired -Key $key
        $a = Get-QlTaskByKey -Key $key -Tasks $Tasks
        # 同步状态下 Compare-QlTask 返回空数组，跨函数边界会被解包成 $null，
        # 下面 $diff.Count 会抛错。必须 @() 兜回数组。
        $diff = @(Compare-QlTask -Desired $d -Actual $a)
        $action = 'no-op'
        if ($null -eq $a) { $action = 'create' }
        elseif ($diff.Count -gt 0) { $action = 'update' }
        $rows.Add([ordered]@{
            key        = $key
            action     = $action
            platformId = if ($null -ne $a) { [int]$a.id } else { $null }
            enabled    = if ($null -ne $a) { ([int]$a.isDisabled -eq 0) } else { $null }
            schedule   = [string]$d.schedule
            diff       = $diff
            desired    = $d
        })
    }
    return $rows.ToArray()
}

# 平台上有 qls.key 标签、但本地没有对应期望态文件 == 漂移出来的孤儿
function Get-QlOrphans {
    param($Tasks = $null)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    $local = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in (Get-QlDesiredKeys)) { [void]$local.Add($k) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tasks) {
        $k = Get-QlLabelValue -Labels $t.labels -Key 'qls.key'
        if ($null -ne $k -and -not $local.Contains($k)) {
            $out.Add([ordered]@{ key = $k; id = [int]$t.id; name = [string]$t.name })
        }
    }
    return $out.ToArray()
}

# 5 段 cron 在本部署不触发：容器系统 crontab 路径未生效
function Get-QlScheduleFormatRisks {
    param($Tasks = $null)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tasks) {
        $n = @(([string]$t.schedule).Trim() -split '\s+' | Where-Object { $_ -ne '' }).Count
        if ($n -ne 6) {
            $out.Add([ordered]@{
                id       = [int]$t.id
                name     = [string]$t.name
                schedule = [string]$t.schedule
                fields   = $n
                enabled  = ([int]$t.isDisabled -eq 0)
            })
        }
    }
    return $out.ToArray()
}

# 同一分钟槽位上的并发任务数。已停用与 5 段任务不计入（它们实际不触发）。
function Get-QlConcurrencyReport {
    param($Tasks = $null, [int]$Threshold = 8, [int]$Top = 5)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    $slots = @{}
    foreach ($t in $Tasks) {
        if ([int]$t.isDisabled -ne 0) { continue }
        $f = @(([string]$t.schedule).Trim() -split '\s+' | Where-Object { $_ -ne '' })
        if ($f.Count -ne 6) { continue }
        foreach ($k in (Expand-QlSchedule -Schedule $t.schedule)) {
            if (-not $slots.ContainsKey($k)) { $slots[$k] = New-Object System.Collections.Generic.List[string] }
            $slots[$k].Add([string]$t.name)
        }
    }
    $hot = New-Object System.Collections.Generic.List[object]
    foreach ($k in $slots.Keys) {
        if ($slots[$k].Count -ge $Threshold) {
            $hot.Add([ordered]@{ slot = $k; count = $slots[$k].Count; tasks = $slots[$k].ToArray() })
        }
    }
    $sorted = @($hot | Sort-Object { -$_.count })
    if ($sorted.Count -gt $Top) { $sorted = $sorted[0..($Top - 1)] }

    $maxCount = 0
    foreach ($k in $slots.Keys) { if ($slots[$k].Count -gt $maxCount) { $maxCount = $slots[$k].Count } }

    return [ordered]@{
        distinctSlots = $slots.Keys.Count
        maxConcurrent = $maxCount
        threshold     = $Threshold
        hotSlots      = $sorted
    }
}

# 已启用但超过期望间隔 3 倍仍未执行
function Get-QlStaleReport {
    param($Tasks = $null, [double]$Factor = 3.0)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    $now = Get-Date
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tasks) {
        if ([int]$t.isDisabled -ne 0) { continue }
        $iv = Get-QlExpectedIntervalSec -Schedule ([string]$t.schedule)
        if ($null -eq $iv) { continue }
        if ($null -eq $t.last_execution_time -or [int64]$t.last_execution_time -le 0) {
            $out.Add([ordered]@{
                id = [int]$t.id; name = [string]$t.name; schedule = [string]$t.schedule
                lastRun = $null; expectedSec = $iv; missedRuns = $null; reason = 'never-ran'
            })
            continue
        }
        $last = [DateTimeOffset]::FromUnixTimeSeconds([int64]$t.last_execution_time).LocalDateTime
        $gapSec = ($now - $last).TotalSeconds
        if ($gapSec -gt ($iv * $Factor)) {
            $out.Add([ordered]@{
                id = [int]$t.id; name = [string]$t.name; schedule = [string]$t.schedule
                lastRun = $last.ToString('yyyy-MM-dd HH:mm:ss')
                expectedSec = $iv
                missedRuns  = [int][Math]::Floor($gapSec / $iv)
                reason      = 'overdue'
            })
        }
    }
    return @($out | Sort-Object { -[int]$_['missedRuns'] })
}
