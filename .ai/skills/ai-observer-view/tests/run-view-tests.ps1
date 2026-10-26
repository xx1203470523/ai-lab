# AI Observer 查看器测试 —— 只读验证 report.ps1 的输出，不碰观察器本身
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File run-view-tests.ps1
#
# 注意：本文件必须保持 UTF-8 with BOM，否则 Windows PowerShell 5.1 按 ANSI 读取会解析失败。

$ErrorActionPreference = 'Stop'

$script:Report = (Resolve-Path (Join-Path $PSScriptRoot '..\scripts\report.ps1')).Path
$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ([string]$Expected -eq [string]$Actual) {
        $script:Pass++; Write-Output ('  PASS  ' + $Name)
    } else {
        $script:Fail++; Write-Output ('  FAIL  ' + $Name + '  expected=[' + $Expected + '] actual=[' + $Actual + ']')
    }
}

function Assert-True {
    param([string]$Name, $Condition)
    if ($Condition) { $script:Pass++; Write-Output ('  PASS  ' + $Name) }
    else { $script:Fail++; Write-Output ('  FAIL  ' + $Name) }
}

function Write-LogLine {
    param([string]$File, $Record)
    $dir = [System.IO.Path]::GetDirectoryName($File)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($File, (($Record | ConvertTo-Json -Compress -Depth 8) + "`n"), $enc)
}

function Invoke-View {
    param([string]$Root, [string[]]$Extra = @())
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File $script:Report -LogRoot $Root @Extra 2>&1 | Out-String -Width 300)
}

Write-Output '=== 1. 语法检查 ==='
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script:Report, [ref]$null, [ref]$parseErrors)
Assert-Equal 'report.ps1 可解析' 0 @($parseErrors).Count

# ---- 沙箱：一份"改造前"的旧记录 + 一份带版本和内容的"改造后"记录 ----
$sb = Join-Path $env:TEMP ('view-tests-' + (Get-Date -Format 'HHmmss'))
$root = Join-Path $sb 'logs'
$skillsDir = Join-Path $root 'skills'
[void][System.IO.Directory]::CreateDirectory($skillsDir)

# 旧记录：没有 skillHash，metrics 里也没有 FilePaths / Commands（改造前写入的真实形状）
$legacyFile = Join-Path $skillsDir 'legacy\2026-09.jsonl'
Write-LogLine -File $legacyFile -Record ([ordered]@{
    eventType = 'skill_start'; skillName = 'legacy'; skillDir = 'legacy'; toolUseId = 'tool_old1'
    invocation = 'model'; ts = '2026-09-10T01:00:00.000Z'; project = 'wms'
})
Write-LogLine -File $legacyFile -Record ([ordered]@{
    eventType = 'skill_end'; skillName = 'legacy'; skillDir = 'legacy'; toolUseId = 'tool_old1'
    ts = '2026-09-10T01:05:00.000Z'; tsLocal = '2026-09-10T09:05:00.000+08:00'
    durationMs = 300000; endReason = 'stop'
    metrics = [ordered]@{ complete = $true; filesChanged = 1; commandsExecuted = 2; assistantOutputChars = 100 }
})
# 关联不上的补正记录：不能凭空变成一次调用
Write-LogLine -File $legacyFile -Record ([ordered]@{
    eventType = 'skill_end_revised'; skillName = 'legacy'; skillDir = 'legacy'; toolUseId = 'tool_gone'
    ts = '2026-09-10T01:06:00.000Z'
    metrics = [ordered]@{ complete = $true; filesChanged = 9; commandsExecuted = 9; assistantOutputChars = 9 }
})

# 新记录：两个版本，都带内容字段
$modernFile = Join-Path $skillsDir 'modern\2026-09.jsonl'
Write-LogLine -File $modernFile -Record ([ordered]@{
    eventType = 'skill_start'; skillName = 'modern'; skillDir = 'modern'; toolUseId = 'tool_v1'
    invocation = 'model'; ts = '2026-09-17T01:00:00.000Z'; project = 'wms'; skillHash = 'aaaaaaaaaaaa'
})
Write-LogLine -File $modernFile -Record ([ordered]@{
    eventType = 'skill_end'; skillName = 'modern'; skillDir = 'modern'; toolUseId = 'tool_v1'
    ts = '2026-09-17T01:10:00.000Z'; tsLocal = '2026-09-17T09:10:00.000+08:00'
    durationMs = 10000; endReason = 'stop'; skillHash = 'aaaaaaaaaaaa'
    metrics = [ordered]@{
        complete = $true; filesChanged = 2; commandsExecuted = 2; assistantOutputChars = 500
        FilePaths = @('src/a.ps1', 'src/b.ps1'); Commands = @('git status --short', 'echo hi')
    }
})
Write-LogLine -File $modernFile -Record ([ordered]@{
    eventType = 'skill_start'; skillName = 'modern'; skillDir = 'modern'; toolUseId = 'tool_v2'
    invocation = 'model'; ts = '2026-09-17T05:00:00.000Z'; project = 'wms'; skillHash = 'bbbbbbbbbbbb'
})
Write-LogLine -File $modernFile -Record ([ordered]@{
    eventType = 'skill_end'; skillName = 'modern'; skillDir = 'modern'; toolUseId = 'tool_v2'
    ts = '2026-09-17T05:20:00.000Z'; tsLocal = '2026-09-17T13:20:00.000+08:00'
    durationMs = 20000; endReason = 'stop'; skillHash = 'bbbbbbbbbbbb'
    metrics = [ordered]@{
        complete = $true; filesChanged = 1; commandsExecuted = 1; assistantOutputChars = 700
        FilePaths = @('src/a.ps1'); Commands = @('git status --short')
    }
})

# 手敲 /skill：没有工具调用锚点，只能靠 startedUtc 关联
$slashFile = Join-Path $skillsDir 'slashy\2026-09.jsonl'
Write-LogLine -File $slashFile -Record ([ordered]@{
    eventType = 'skill_start'; skillName = 'slashy'; skillDir = 'slashy'; toolUseId = ''
    entry = 'slash-command'; invocation = 'user'; startedUtc = '2026-09-17T07:00:00.000Z'
    ts = '2026-09-17T07:00:00.000Z'; project = 'wms'; skillHash = 'cccccccccccc'
})
Write-LogLine -File $slashFile -Record ([ordered]@{
    eventType = 'skill_end'; skillName = 'slashy'; skillDir = 'slashy'; toolUseId = ''
    startedUtc = '2026-09-17T07:00:00.000Z'
    ts = '2026-09-17T07:01:00.000Z'; tsLocal = '2026-09-17T15:01:00.000+08:00'
    durationMs = 5000; endReason = 'stop'; skillHash = 'cccccccccccc'
    metrics = [ordered]@{ complete = $true; filesChanged = 0; commandsExecuted = 0; assistantOutputChars = 10 }
})

Write-Output ''
Write-Output '=== 2. 改造前的旧记录：必须显式降级，不能输出空表 ==='

$o = Invoke-View -Root $root -Extra @('-Mode', 'content', '-Skill', 'legacy')
Assert-True '旧记录的内容模式提示没有内容字段' ($o -match '这些记录里没有文件路径和命令正文')
Assert-True '旧记录不输出"出现在 N 条记录中"的空表头' (-not ($o -match '出现在 \d+ 条记录中'))
Assert-True '旧记录不输出"完整命令"空表' (-not ($o -match '完整命令'))

$o = Invoke-View -Root $root -Extra @('-Mode', 'versions', '-Skill', 'legacy')
$lines = @($o -split "`r?`n")
Assert-True '旧记录标注为未记录版本' ($o -match '\(未记录版本\)')
Assert-True '无可对比版本时给出说明' ($o -match '暂无可对比的版本')
Assert-Equal '说明行不产生游离的 + 行' 0 @($lines | Where-Object { $_.Trim() -eq '+' }).Count
Assert-Equal '说明行不产生游离的 。 行' 0 @($lines | Where-Object { $_.Trim() -eq '。' }).Count

Write-Output ''
Write-Output '=== 3. 关联与闭合（补正不得虚增调用数） ==='

$o = Invoke-View -Root $root -Extra @('-Mode', 'summary', '-Skill', 'legacy')
$legacyLine = @($o -split "`r?`n" | Where-Object { $_ -match '^legacy\s' })[0]
Assert-True '旧记录调用数与闭合数一致' ($legacyLine -match '^legacy\s+1\s+0/1\s+1\s')
# 孤立补正里被夸大的指标（9 个文件、9 条命令）绝不能渗进统计。
Assert-True '孤立补正的指标不渗入统计' ($legacyLine -match '\s1\s+2\s+0\s*$')
Assert-True '关联不上的补正被单独报出' ($o -match '另有 1 条补正记录无法关联')

$o = Invoke-View -Root $root -Extra @('-Mode', 'summary', '-Skill', 'slashy')
$slashLine = @($o -split "`r?`n" | Where-Object { $_ -match '^slashy\s' })[0]
Assert-True '手敲路径按 startedUtc 关联成功' ($slashLine -match '^slashy\s+1\s+1/0\s+1\s')

Write-Output ''
Write-Output '=== 4. 改造后的记录：版本对比与内容统计 ==='

$o = Invoke-View -Root $root -Extra @('-Mode', 'versions', '-Skill', 'modern')
Assert-True '相邻两版给出前后对比' ($o -match '旧 aaaaaaaaaaaa -> 新 bbbbbbbbbbbb')
Assert-True '样本不足时明确提示' ($o -match '样本过少')
Assert-True '版本表列出两个版本' (($o -match 'aaaaaaaaaaaa') -and ($o -match 'bbbbbbbbbbbb'))

$o = Invoke-View -Root $root -Extra @('-Mode', 'content', '-Skill', 'modern')
Assert-True '内容模式不输出"没有内容字段"提示' (-not ($o -match '这些记录里没有文件路径和命令正文'))
Assert-True '统计出改动文件路径' ($o -match 'src/a\.ps1')
Assert-True '文件按出现次数统计' ($o -match 'src/a\.ps1\s+2')
Assert-True '只出现一次的文件计为 1' ($o -match 'src/b\.ps1\s+1')
Assert-True '统计出命令正文' ($o -match 'echo hi')
Assert-True '命令按出现次数统计' ($o -match 'echo hi\s+1')
Assert-True '给出命令前缀' ($o -match 'git status')
Assert-True '提醒命令正文可能含敏感串' ($o -match '敏感字符串')

Write-Output ''
Write-Output '=== 5. 过滤与边界 ==='

$o = Invoke-View -Root $root -Extra @('-Mode', 'summary', '-Since', '2026-09-17')
Assert-True 'Since 只给日期时包含当天' ($o -match 'modern')
Assert-True 'Since 排除更早的记录' (-not ($o -match '\blegacy\b'))

$o = Invoke-View -Root $root -Extra @('-Mode', 'summary', '-Until', '2026-09-10')
Assert-True 'Until 只给日期时包含当天整日' ($o -match '\blegacy\b')
Assert-True 'Until 排除更晚的记录' (-not ($o -match 'modern'))

$missing = Join-Path $sb 'no-such-root'
$o = Invoke-View -Root $missing
Assert-Equal '日志根不存在时退出码为 0' 0 $LASTEXITCODE
Assert-True '日志根不存在时给出提示' ($o -match '日志目录不存在')

$o = Invoke-View -Root $root -Extra @('-Mode', 'summary')
Assert-Equal '正常查询退出码为 0' 0 $LASTEXITCODE
Assert-True '报告头部标明记录条数' ($o -match '记录 \d+ 条')

# ---- 收尾 ----
Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output ('检查项 ' + ($script:Pass + $script:Fail) + ' 个，失败 ' + $script:Fail + ' 个。')
if ($script:Fail -gt 0) { exit 1 }
exit 0
