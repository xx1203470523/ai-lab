# QingLong 日志层：按任务取日志，不做全量遍历
# 依赖 ql-api.ps1
#
# 端点陷阱（源码确认）：
#   GET /logs       完全忽略 path 参数，无条件全量递归 + 串行 fs.lstat，必然超时。禁止使用。
#   改用 /crons/:id/logs（单目录文件列表）与 /crons/:id/log（最新内容）。
#
# 安全：任务日志由业务脚本产出，可能含连接串、口令、客户数据。
# 一律截断后再进上下文，默认只取尾部。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QlLogTailDefault = 4000
$script:QlLogIdleMark    = '执行结束'

function Get-QlTaskLogFiles {
    param([int]$Id)
    $r = Invoke-QlApi -Path "crons/$Id/logs"
    if ($r.code -ne 200) { throw "读取任务日志列表失败：id=$Id -> $($r.message)" }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($r.data)) {
        $out.Add([ordered]@{
            filename  = [string]$f.filename
            directory = [string]$f.directory
            time      = $f.time
        })
    }
    return $out.ToArray()
}

function Get-QlTaskLatestLog {
    param([int]$Id)
    $r = Invoke-QlApi -Path "crons/$Id/log"
    if ($r.code -ne 200) { throw "读取任务最新日志失败：id=$Id -> $($r.message)" }
    if ($r.data -is [string]) { return [string]$r.data }
    $c = Get-QlProp -Object $r.data -Name 'content'
    if ($null -ne $c) { return [string]$c }
    return ''
}

function Get-QlLogContent {
    param([string]$Directory, [string]$FileName)
    $path = "logs/detail?path=" + [uri]::EscapeDataString($Directory) + "&file=" + [uri]::EscapeDataString($FileName)
    $r = Invoke-QlApi -Path $path
    if ($r.code -ne 200) { throw "读取日志内容失败：$Directory/$FileName -> $($r.message)" }
    if ($r.data -is [string]) { return [string]$r.data }
    $c = Get-QlProp -Object $r.data -Name 'content'
    if ($null -ne $c) { return [string]$c }
    return ''
}

# 日志进了上下文就不可能收回，统一在这里截断
function Limit-QlLogText {
    param([string]$Text, [int]$Tail = 0)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Tail -le 0) { $Tail = $script:QlLogTailDefault }
    if ($Text.Length -le $Tail) { return $Text }
    return ("...[已截断 {0} 字符]...`n" -f ($Text.Length - $Tail)) + $Text.Substring($Text.Length - $Tail)
}

# 日志尾部含“执行结束”或独立的全角空格行 == 已结束；否则视为仍在执行。
# status 字段对定时触发不更新，不能用来判断是否在跑。
function Test-QlTaskRunning {
    param([string]$LogText)
    if ([string]::IsNullOrEmpty($LogText)) { return $false }
    if ($LogText -match [regex]::Escape($script:QlLogIdleMark)) { return $false }
    return $true
}

# 从日志尾部提取耗时与结束状态，只报事实，不做因果推断
function Get-QlLogFacts {
    param([string]$LogText)
    $facts = [ordered]@{
        length         = 0
        running        = $false
        hasEndMark     = $false
        lastErrorLines = @()
        durationText   = $null
    }
    if ([string]::IsNullOrEmpty($LogText)) { return $facts }
    $facts.length     = $LogText.Length
    $facts.hasEndMark = ($LogText -match [regex]::Escape($script:QlLogIdleMark))
    $facts.running    = -not $facts.hasEndMark

    $lines = $LogText -split "`r?`n"
    $err = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l -match 'Error|Exception|Traceback|失败|超时|timeout|ECONNREFUSED|ETIMEDOUT') {
            $err.Add($l.Trim())
        }
    }
    if ($err.Count -gt 0) {
        $take = [Math]::Min(5, $err.Count)
        $facts.lastErrorLines = @($err.GetRange($err.Count - $take, $take))
    }

    $m = [regex]::Match($LogText, '耗时[：:\s]*([0-9.]+)\s*(秒|s|分钟|min)')
    if ($m.Success) { $facts.durationText = $m.Value }

    return $facts
}
