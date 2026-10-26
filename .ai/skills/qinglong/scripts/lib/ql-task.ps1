# QingLong 任务层：调度校验 / 期望态读取 / 差异计算 / 任务写动词
# 依赖 ql-api.ps1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QlLabelPrefix = 'qls.'

# ---- 调度校验 ----------------------------------------------------------

# 本部署的 5 段 cron 走容器系统 crontab 且不触发，6 段走进程内 node-schedule。
# 因此只接受 6 段 Quartz 风格表达式。
function Assert-QlScheduleFormat {
    param([string]$Schedule, [string]$Name = 'schedule')
    if ([string]::IsNullOrWhiteSpace($Schedule)) { throw "$Name 为空" }
    $f = @($Schedule.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($f.Count -eq 5) {
        throw ("$Name 是 5 段表达式 '$Schedule'。本部署 5 段走系统 crontab 且不触发，必须改成 6 段（秒 分 时 日 月 周），例如 '0 * * * * ?'")
    }
    if ($f.Count -ne 6) {
        throw ("$Name 段数={0}，只接受 6 段（秒 分 时 日 月 周）：'$Schedule'" -f $f.Count)
    }
    foreach ($part in $f) { Assert-QlCronField -Expr $part -Name $Name }
    return ($f -join ' ')
}

function Assert-QlCronField {
    param([string]$Expr, [string]$Name = 'schedule')
    if ([string]::IsNullOrWhiteSpace($Expr)) { throw "$Name 含空字段" }
    foreach ($seg in ($Expr -split ',')) {
        if ($seg -eq '') { throw "$Name 含空列表项：'$Expr'" }
        $body = $seg
        $slash = $seg.IndexOf('/')
        if ($slash -ge 0) {
            $body = $seg.Substring(0, $slash)
            $step = $seg.Substring($slash + 1)
            if ($step -notmatch '^\d+$' -or [int]$step -lt 1) { throw "$Name 步长非法：'$seg'" }
        }
        if ($body -eq '*' -or $body -eq '?') { continue }
        if ($body -match '^\d+$') { continue }
        if ($body -match '^\d+-\d+$') { continue }
        if ($body -match '^[A-Za-z]{3}(-[A-Za-z]{3})?$') { continue }
        throw "$Name 字段非法：'$seg'"
    }
}

# ---- cron 展开（用于并发峰值与调度冲突诊断）----------------------------

function Expand-QlCronField {
    param([string]$Expr, [int]$Min, [int]$Max)
    $set = New-Object System.Collections.Generic.HashSet[int]
    foreach ($seg in ($Expr -split ',')) {
        $step = 1
        $body = $seg
        $slash = $seg.IndexOf('/')
        if ($slash -ge 0) {
            $body = $seg.Substring(0, $slash)
            $step = [int]$seg.Substring($slash + 1)
        }
        $lo = $Min; $hi = $Max
        if ($body -ne '*' -and $body -ne '?') {
            if ($body -match '^(\d+)-(\d+)$') {
                $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
            } elseif ($body -match '^\d+$') {
                $lo = [int]$body; $hi = [int]$body
            } else {
                continue
            }
        }
        if ($hi -gt $Max) { $hi = $Max }
        for ($i = $lo; $i -le $hi; $i += $step) { [void]$set.Add($i) }
    }
    return $set
}

# 返回该任务在一天中占用的分钟槽位，形如 'HH:mm'
function Expand-QlSchedule {
    param([string]$Schedule)
    $f = @($Schedule.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($f.Count -eq 5) { $min = $f[0]; $hr = $f[1] }
    elseif ($f.Count -eq 6) { $min = $f[1]; $hr = $f[2] }
    else { return @() }

    $minutes = Expand-QlCronField -Expr $min -Min 0 -Max 59
    $hours   = Expand-QlCronField -Expr $hr  -Min 0 -Max 23
    $slots = New-Object System.Collections.Generic.List[string]
    foreach ($h in $hours) {
        foreach ($m in $minutes) {
            $slots.Add(('{0:d2}:{1:d2}' -f $h, $m))
        }
    }
    return $slots.ToArray()
}

# 由 cron 推断期望执行间隔（秒），无法推断返回 $null
function Get-QlExpectedIntervalSec {
    param([string]$Schedule)
    $f = @($Schedule.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($f.Count -lt 5) { return $null }
    if ($f.Count -eq 5) { $min = $f[0]; $hr = $f[1] }
    else { $min = $f[1]; $hr = $f[2] }
    if ($hr -eq '*' -or $hr -eq '?') {
        if ($min -match '^\*/(\d+)$') { return ([int]$Matches[1] * 60) }
        if ($min -match '^\d+$') { return 3600 }
        return $null
    }
    if ($min -match '^\d+$') { return 86400 }
    return $null
}

# ---- 任务读取 ----------------------------------------------------------

function Get-QlTasks {
    $page = 1
    $all = New-Object System.Collections.Generic.List[object]
    while ($true) {
        $r = Invoke-QlApi -Path "crons?page=$page&size=200"
        if ($r.code -ne 200) { throw "读取任务列表失败：$($r.message)" }
        $rows = @($r.data.data)
        foreach ($x in $rows) { $all.Add($x) }
        if ($all.Count -ge [int]$r.data.total -or $rows.Count -eq 0) { break }
        $page++
    }
    return $all.ToArray()
}

function Get-QlLabelValue {
    param($Labels, [string]$Key)
    foreach ($l in @($Labels)) {
        if ([string]$l -like "$Key=*") { return ([string]$l).Substring($Key.Length + 1) }
    }
    return $null
}

# key -> 任务；只认 qls.key 标签，不认名字。找不到返回 $null。
function Get-QlTaskByKey {
    param([string]$Key, $Tasks = $null)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    foreach ($t in $Tasks) {
        if ((Get-QlLabelValue -Labels $t.labels -Key 'qls.key') -eq $Key) { return $t }
    }
    return $null
}

# id -> 任务；纳管等需要按平台 id 定位的场景用。找不到返回 $null。
function Get-QlTaskById {
    param([int]$Id, $Tasks = $null)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    foreach ($t in $Tasks) {
        if ([int]$t.id -eq $Id) { return $t }
    }
    return $null
}

function Test-QlManaged {
    param($Task)
    return ((Get-QlLabelValue -Labels $Task.labels -Key 'qls.managed-by') -eq 'ai')
}

# ---- 期望态 ------------------------------------------------------------

function Get-QlTasksDir { return (Join-Path (Get-QlSkillRoot) 'tasks') }

function Get-QlDesiredKeys {
    $dir = Get-QlTasksDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-QlDesired {
    param([string]$Key)
    $p = Join-Path (Get-QlTasksDir) "$Key.json"
    if (-not (Test-Path -LiteralPath $p)) { throw "期望态文件不存在：$p" }
    $d = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
    $dk = [string](Get-QlProp -Object $d -Name 'key' -Default '')
    if ($dk -ne $Key) { throw "$p 的 key 字段（'$dk'）与文件名不一致" }
    foreach ($f in @('name', 'command', 'schedule')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-QlProp -Object $d -Name $f -Default ''))) {
            throw "$p 缺少必填字段 $f"
        }
    }
    [void](Assert-QlScheduleFormat -Schedule ([string](Get-QlProp -Object $d -Name 'schedule')) -Name "$Key.schedule")
    return $d
}

# 期望态在平台上应有的 labels（只写 qls.* 命名空间）
function Get-QlDesiredLabels {
    param($Desired)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('qls.managed-by=ai')
    $out.Add("qls.key=$([string](Get-QlProp -Object $Desired -Name 'key'))")
    $extra = Get-QlProp -Object $Desired -Name 'labels'
    if ($null -ne $extra) {
        foreach ($p in $extra.PSObject.Properties) {
            $out.Add("qls.$($p.Name)=$($p.Value)")
        }
    }
    return $out.ToArray()
}

# ---- 差异计算 ----------------------------------------------------------

function Compare-QlTask {
    param($Desired, $Actual)
    $diff = New-Object System.Collections.Generic.List[object]

    if ($null -eq $Actual) {
        $diff.Add([ordered]@{ field = '*'; desired = 'create'; actual = 'absent' })
        return $diff.ToArray()
    }

    $dName = [string](Get-QlProp -Object $Desired -Name 'name' -Default '')
    $aName = [string](Get-QlProp -Object $Actual  -Name 'name' -Default '')
    if ($dName -ne $aName) {
        $diff.Add([ordered]@{ field = 'name'; desired = $dName; actual = $aName })
    }
    $dCmd = [string](Get-QlProp -Object $Desired -Name 'command' -Default '')
    $aCmd = [string](Get-QlProp -Object $Actual  -Name 'command' -Default '')
    if ($dCmd -ne $aCmd) {
        $diff.Add([ordered]@{ field = 'command'; desired = $dCmd; actual = $aCmd })
    }
    $dSched = [string](Get-QlProp -Object $Desired -Name 'schedule' -Default '')
    $aSched = [string](Get-QlProp -Object $Actual  -Name 'schedule' -Default '')
    $wantSched = ($dSched.Trim() -split '\s+' | Where-Object { $_ -ne '' }) -join ' '
    $haveSched = ($aSched.Trim() -split '\s+' | Where-Object { $_ -ne '' }) -join ' '
    if ($wantSched -ne $haveSched) {
        $diff.Add([ordered]@{ field = 'schedule'; desired = $wantSched; actual = $haveSched })
    }

    $wantEnabled = $true
    $dEnabled = Get-QlProp -Object $Desired -Name 'enabled'
    if ($null -ne $dEnabled) { $wantEnabled = [bool]$dEnabled }
    $haveEnabled = ([int](Get-QlProp -Object $Actual -Name 'isDisabled' -Default 0) -eq 0)
    if ($wantEnabled -ne $haveEnabled) {
        $diff.Add([ordered]@{ field = 'enabled'; desired = $wantEnabled; actual = $haveEnabled })
    }

    $wantLabels = @(Get-QlDesiredLabels -Desired $Desired)
    $haveManaged = New-Object System.Collections.Generic.List[string]
    foreach ($l in @(Get-QlProp -Object $Actual -Name 'labels' -Default @())) {
        if (([string]$l).StartsWith($script:QlLabelPrefix)) { $haveManaged.Add([string]$l) }
    }
    foreach ($l in $wantLabels) {
        if (-not $haveManaged.Contains($l)) {
            $diff.Add([ordered]@{ field = 'labels.missing'; desired = $l; actual = $null })
        }
    }
    foreach ($l in $haveManaged) {
        if (-not $wantLabels.Contains($l)) {
            $diff.Add([ordered]@{ field = 'labels.stale'; desired = $null; actual = $l })
        }
    }

    foreach ($pair in @(@('taskBefore', 'task_before'), @('taskAfter', 'task_after'))) {
        $d = [string](Get-QlProp -Object $Desired -Name $pair[0] -Default '')
        $a = [string](Get-QlProp -Object $Actual  -Name $pair[1] -Default '')
        if ($d -ne $a) {
            $diff.Add([ordered]@{ field = $pair[1]; desired = $d; actual = $a })
        }
    }

    return $diff.ToArray()
}

# ---- 写动词 ------------------------------------------------------------

function New-QlTaskWireBody {
    param($Desired, $Actual)
    $body = [ordered]@{
        name     = [string](Get-QlProp -Object $Desired -Name 'name' -Default '')
        command  = [string](Get-QlProp -Object $Desired -Name 'command' -Default '')
        schedule = [string](Get-QlProp -Object $Desired -Name 'schedule' -Default '')
        labels   = @(Get-QlDesiredLabels -Desired $Desired)
    }
    if ($null -ne $Actual) { $body['id'] = [int](Get-QlProp -Object $Actual -Name 'id' -Default 0) }
    $tb = [string](Get-QlProp -Object $Desired -Name 'taskBefore' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($tb)) { $body['task_before'] = $tb }
    $ta = [string](Get-QlProp -Object $Desired -Name 'taskAfter' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($ta)) { $body['task_after'] = $ta }
    return $body
}

function New-QlTask {
    param($Desired)
    $r = Invoke-QlApi -Method Post -Path 'crons' -Body (New-QlTaskWireBody -Desired $Desired -Actual $null)
    if ($r.code -ne 200) { throw "创建任务失败：$($r.message)" }
    return $r.data
}

function Set-QlTask {
    param($Desired, $Actual)
    # PUT 是整体替换，必须带 command + schedule + id
    $r = Invoke-QlApi -Method Put -Path 'crons' -Body (New-QlTaskWireBody -Desired $Desired -Actual $Actual)
    if ($r.code -ne 200) { throw "更新任务失败：$($r.message)" }
    return $r.data
}

# 青龙这三个动词的 body 是裸 JSON 数组（如 [12]），不是 {ids:[12]}。
# 用 [int[]] 强转，避免单元素数组被 PS 拆包成标量。
function Set-QlTaskEnabled {
    param([int]$Id, [bool]$Enabled)
    $path = if ($Enabled) { "crons/enable" } else { "crons/disable" }
    $r = Invoke-QlApi -Method Put -Path $path -Body ([int[]]@($Id))
    if ($r.code -ne 200) { throw "启停任务失败：$($r.message)" }
    return $r
}

function Remove-QlTask {
    param([int[]]$Ids)
    $r = Invoke-QlApi -Method Delete -Path 'crons' -Body ([int[]]$Ids)
    if ($r.code -ne 200) { throw "删除任务失败：$($r.message)" }
    return $r
}

function Start-QlTask {
    param([int]$Id)
    $r = Invoke-QlApi -Method Put -Path 'crons/run' -Body ([int[]]@($Id))
    if ($r.code -ne 200) { throw "触发任务失败：$($r.message)" }
    return $r
}

# ---- 计划摘要 ----------------------------------------------------------

function Get-QlPlanDigest {
    param($PlanObject)
    $json = $PlanObject | ConvertTo-Json -Depth 10 -Compress
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($json))
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}
