param(
    [switch]$StatusOnly,
    [switch]$NoStart,
    [int]$SleepSeconds = 2
)

$ErrorActionPreference = "Continue"

$Repo = "E:\My\project\trade"
$PythonDir = Join-Path $Repo "python"
$WatcherScript = Join-Path $Repo "cmd\start-watcher.ps1"
$CcScript = Join-Path $Repo "cmd\start-cc-connect.ps1"
$NpmBin = Join-Path $env:USERPROFILE "AppData\Roaming\npm"
$CcConnectCmd = Join-Path $NpmBin "cc-connect.cmd"
$NodePath = "C:\Program Files\nodejs"

$SkillRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $SkillRoot "logs"
$LogPath = Join-Path $LogDir "start-my.log"

function Ensure-LogDir {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
}

function Write-Log {
    param([string]$Message)
    Ensure-LogDir
    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    $line | Out-File -FilePath $LogPath -Encoding utf8 -Append
    Write-Host $line
}

function New-Utf8ScriptBlock {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Missing script: $Path"
    }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return [ScriptBlock]::Create($text)
}

function Get-WatcherProcess {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -match "python" -and
        $_.CommandLine -match "chaogu" -and
        $_.CommandLine -match "watch"
    }
}

function Get-CcConnectProcess {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "node.exe" -and
        ($_.CommandLine -match "cc-connect" -or $_.CommandLine -match "node_modules\\cc-connect\\run\.js")
    }
}

function Test-PythonImport {
    if (-not (Test-Path $PythonDir)) {
        Write-Log "python_dir_missing path=$PythonDir"
        return $false
    }

    Push-Location $PythonDir
    try {
        $output = & python -c "import chaogu; print('python import ok')"
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    Write-Log "python_import exit=$code output=$output"
    return ($code -eq 0)
}

function Start-WatcherDirect {
    Write-Log "watcher_direct_start begin"
    Start-Process -FilePath "python" -ArgumentList "-m chaogu watch" -WorkingDirectory $PythonDir -WindowStyle Hidden
    Write-Log "watcher_direct_start requested"
}

function Start-CcConnectDirect {
    if (-not (Test-Path $CcConnectCmd)) {
        Write-Log "cc_connect_cmd_missing path=$CcConnectCmd"
        return
    }
    $env:PATH = "$NodePath;$NpmBin;" + $env:PATH
    Write-Log "cc_connect_direct_start begin"
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$CcConnectCmd`"" -WorkingDirectory $PythonDir -WindowStyle Hidden
    Write-Log "cc_connect_direct_start requested"
}

function Write-ProcessSummary {
    param(
        [string]$Label,
        [object[]]$Processes
    )

    if (-not $Processes -or $Processes.Count -eq 0) {
        Write-Log "$Label status=missing"
        return
    }

    foreach ($p in $Processes) {
        Write-Log ("{0} status=running pid={1} cmd={2}" -f $Label, $p.ProcessId, $p.CommandLine)
    }
}

Write-Log "start_my begin status_only=$StatusOnly no_start=$NoStart"

try {
    $missing = @($WatcherScript, $CcScript) | Where-Object { -not (Test-Path $_) }
    if ($missing.Count -gt 0) {
        Write-Log "missing_required_scripts paths=$($missing -join ';')"
        exit 1
    }

    if (-not $StatusOnly -and -not $NoStart) {
        $watcher = @(Get-WatcherProcess)
        if ($watcher.Count -eq 0) {
            Write-Log "watcher_not_found starting_via_project_script"
            $watcherBlock = New-Utf8ScriptBlock $WatcherScript
            $watcherOutput = & $watcherBlock -Hidden
            foreach ($line in $watcherOutput) { Write-Log "watcher_script_output $line" }
            Start-Sleep -Seconds 1
            $watcher = @(Get-WatcherProcess)
            if ($watcher.Count -eq 0) {
                Write-Log "watcher_still_missing starting_direct"
                Start-WatcherDirect
            }
        } else {
            Write-Log "watcher_already_running count=$($watcher.Count)"
        }

        $cc = @(Get-CcConnectProcess)
        if ($cc.Count -eq 0) {
            Write-Log "cc_connect_not_found starting_via_project_script"
            $ccBlock = New-Utf8ScriptBlock $CcScript
            Push-Location $PythonDir
            try {
                $ccOutput = & $ccBlock
            } finally {
                Pop-Location
            }
            foreach ($line in $ccOutput) { Write-Log "cc_script_output $line" }
            Start-Sleep -Seconds 1
            $cc = @(Get-CcConnectProcess)
            if ($cc.Count -eq 0) {
                Write-Log "cc_connect_still_missing starting_direct"
                Start-CcConnectDirect
            }
        } else {
            Write-Log "cc_connect_already_running count=$($cc.Count)"
        }

        if ($SleepSeconds -gt 0) {
            Start-Sleep -Seconds $SleepSeconds
        }
    }

    $pythonOk = [bool](Test-PythonImport)
    $watcherFinal = @(Get-WatcherProcess)
    $ccFinal = @(Get-CcConnectProcess)

    Write-ProcessSummary "watcher" $watcherFinal
    Write-ProcessSummary "cc_connect" $ccFinal

    if ($pythonOk -and $watcherFinal.Count -gt 0 -and $ccFinal.Count -gt 0) {
        Write-Log "start_my result=ok"
        exit 0
    }

    Write-Log "start_my result=failed python_ok=$pythonOk watcher_count=$($watcherFinal.Count) cc_count=$($ccFinal.Count)"
    exit 1
} catch {
    Write-Log "start_my exception=$($_.Exception.Message)"
    exit 1
}
