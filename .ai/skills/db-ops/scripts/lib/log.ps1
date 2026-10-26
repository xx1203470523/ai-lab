# lib/log.ps1 —— 运行事件日志（JSONL）与 RunId。
#
# 职责边界
#   维护「本次运行」的 RunId，并把事件按 JSONL 追加到 LogPath。
#
# 明确不做
#   不做输出格式化（那是 output.ps1）、不读配置、不判断路由状态、不脱敏。
#   脱敏必须发生在调用本函数**之前**：一旦秘密值进了这个函数，它已经进了日志文件。
#
# 依赖：common.ps1 必须先 dot-source。
#
# 阶段 1 的实际行为
#   policy.logging.enabled=false，因此 db-ops.ps1 传进来的 LogPath 恒为 $null。
#   LogPath 为空 = 预检模式：只往 stdout 报，**不落任何文件**。
#   Validate / ListTargets 因此是彻底只读的，连日志目录都不会被创建。

$script:DbOpsRun = [ordered]@{
    RunId      = 'unknown'
    LogPath    = $null
    StatusPath = $null
    Json       = $false
}

function Initialize-RunLog {
    param(
        [string]$RunId,
        [string]$LogPath,
        [string]$StatusPath,
        [switch]$Json
    )
    if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().ToString('N') }
    $script:DbOpsRun.RunId = $RunId
    $script:DbOpsRun.LogPath = $LogPath
    $script:DbOpsRun.StatusPath = $StatusPath
    $script:DbOpsRun.Json = [bool]$Json
}

function Get-RunId {
    return [string]$script:DbOpsRun.RunId
}

function Get-RunLogPath {
    return [string]$script:DbOpsRun.LogPath
}

function Write-Event {
    # 日志路径为空 = 预检模式（只读检查，不得在产物目录留日志文件），只往 stdout 报。
    param(
        [string]$Event,
        [string]$Status,
        [string]$Item,
        [string]$Message
    )
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        runId     = $script:DbOpsRun.RunId
        event     = $Event
        status    = $Status
        item      = $Item
        message   = $Message
    }
    $line = $record | ConvertTo-Json -Compress

    if (-not [string]::IsNullOrWhiteSpace($script:DbOpsRun.LogPath)) {
        $parent = Split-Path -Parent $script:DbOpsRun.LogPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Add-Content -LiteralPath $script:DbOpsRun.LogPath -Value $line -Encoding UTF8
    }

    if (-not [string]::IsNullOrWhiteSpace($script:DbOpsRun.StatusPath)) {
        $parent = Split-Path -Parent $script:DbOpsRun.StatusPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:DbOpsRun.StatusPath -Encoding UTF8
    }

    if (-not $script:DbOpsRun.Json) {
        Write-Output ("[{0}] {1} {2} {3}" -f $record.timestamp, $Status, $Item, $Message)
    }
}
