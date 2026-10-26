# lib/log.ps1 —— 运行事件日志（JSONL + .status.json）与结果文件回传。
#
# 进这个文件的门槛：**至少两个脚本要用**。当前调用方是全部 6 个脚本
# （publish.ps1 与 4 个生产者、package.ps1），编排层通过 -LogPath / -RunId
# 让子进程把事件写进**同一次运行**的同一份 JSONL。
#
# 依赖：common.ps1 必须先 dot-source。

$script:WmsRun = [ordered]@{
    RunId      = 'unknown'
    LogPath    = $null
    StatusPath = $null
    Json       = $false
}

function Initialize-RunLog {
    # StatusPath 刻意允许为空：生产者在编排下运行时**不写** .status.json。
    # 否则每个子进程都会用自己的最后一条事件覆盖掉编排层写的状态，
    # 让「这次发布整体进行到哪一步」永远只剩最后那个生产者的一句话。
    param(
        [string]$RunId,
        [string]$LogPath,
        [string]$StatusPath,
        [switch]$Json
    )
    $script:WmsRun.RunId = if ([string]::IsNullOrWhiteSpace($RunId)) { [guid]::NewGuid().ToString('N') } else { $RunId }
    $script:WmsRun.LogPath = $LogPath
    $script:WmsRun.StatusPath = $StatusPath
    $script:WmsRun.Json = [bool]$Json
}

function Get-RunId {
    return [string]$script:WmsRun.RunId
}

function Get-RunLogPath {
    return [string]$script:WmsRun.LogPath
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
        runId     = $script:WmsRun.RunId
        event     = $Event
        status    = $Status
        item      = $Item
        message   = $Message
    }
    $line = $record | ConvertTo-Json -Compress

    if (-not [string]::IsNullOrWhiteSpace($script:WmsRun.LogPath)) {
        $parent = Split-Path -Parent $script:WmsRun.LogPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        # 编排层在派生子进程之前先写过一条事件，因此文件已存在，
        # 后续追加不会再插入 BOM。子进程共用同一个 LogPath 是安全的：发布按项目串行。
        Add-Content -LiteralPath $script:WmsRun.LogPath -Value $line -Encoding UTF8
    }

    if (-not [string]::IsNullOrWhiteSpace($script:WmsRun.StatusPath)) {
        $parent = Split-Path -Parent $script:WmsRun.StatusPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:WmsRun.StatusPath -Encoding UTF8
    }

    if (-not $script:WmsRun.Json) {
        Write-Output ("[{0}] {1} {2} {3}" -f $record.timestamp, $Status, $Item, $Message)
    }
}

function Write-CommandOutput {
    # 子进程输出：-Json 时逐行进 JSONL（失败文本必须留在日志里），否则原样写到 stdout。
    param(
        [string]$Item,
        [string[]]$Lines
    )
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($script:WmsRun.Json) { Write-Event 'command-output' 'info' $Item $line }
        else { Write-Output $line }
    }
}
