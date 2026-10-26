# invoke-publish.ps1 —— 把「预检」与「执行」串成一次调用，并负责安全捕获输出。
#
# 为什么需要它，两件事各占一半：
#
# 1) digest 一致性。publish.ps1 的 PlanDigest 里含「工作区是否干净」与「提交号」，
#    而这些会被后台的文件轮换或别人的提交翻转。预检与执行若分成两次手工调用，
#    中间那段时间里 digest 可能漂移；这里在同一个进程内先预检再执行，窗口消失。
#    批次时间戳则从预检结果里透传给执行阶段，让「报出来的包名」与「落盘的包名」用同一个戳。
#
# 2) 安全捕获。调用方若写成 `& powershell -File publish.ps1 ... 2>&1 | Out-String` 之类
#    用**管道**读输出，会在 PDA 构建留下常驻后代时永久挂死。成因与修复见
#    Invoke-PublishCaptured 的注释——修复点在派生方式，不在句柄标志。
#
# 它只做编排：不复制 publish.ps1 的任何版本、门禁、归档逻辑，参数原样透传。
[CmdletBinding()]
param(
    [ValidateSet('Preflight', 'Publish')]
    [string]$Mode = 'Preflight',
    [ValidateSet('test', 'production')]
    [string]$Target = 'production',
    # 逗号分隔（-Only admin,report,pda）。**必须保持标量字符串**：powershell -File 不解析
    # 逗号，写成本脚本的数组参数只会让整串变成一个元素，再往下传时被当成一个 id。
    # 拆分由 publish.ps1 的 Split-List 负责，这里不做。
    [string]$Only = '',
    # 同上：逗号分隔的类别列表（-Kind dotnet,web）。
    [string]$Kind = '',
    # 留空在体内解析，原因同 publish.ps1：有 [CmdletBinding()] 时 param 块里的
    # $PSScriptRoot 是空的，写成 "$PSScriptRoot\..\config\release.json" 会得到
    # "\..\config\release.json"。这里不解析也可以（本脚本只是把它透传下去），
    # 但留着空串就会把空串传下去，所以统一在下面补全。
    [string]$Config = '',
    [string]$Version = '',
    [switch]$BumpVersion,
    [ValidatePattern('^(_[A-Za-z0-9-]+)?$')]
    [string]$VersionSuffix = '',
    [switch]$ConfirmPublish,
    [switch]$ConfirmBranch,
    [switch]$AllowDirty,
    [switch]$AllowStale,
    # 可选：把上一次 Preflight 展示给用户、用户据此确认过的 digest 传进来。传了就校验漂移
    # （预检后被提交了新代码、改了选择或后缀都会被抓到）；不传则只要求本次内部预检无阻塞。
    [string]$ExpectedDigest = '',
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\exec.ps1')

# -Config 的默认值在这里补（不能在 param 块里用 $PSScriptRoot，见参数声明处的说明）。
if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path $PSScriptRoot '..\config\release.json' }

$PublishScript = Join-Path $PSScriptRoot 'publish.ps1'
if (-not (Test-Path -LiteralPath $PublishScript -PathType Leaf)) { throw "未找到发布脚本：$PublishScript" }
if ($Mode -eq 'Publish' -and -not $ConfirmPublish) {
    # 单独一个退出码：调用方要能区分「忘了确认」与「脚本坏了」，前者是用法问题、可重试。
    [Console]::Error.WriteLine('ERROR: 真实发布必须显式传 -ConfirmPublish。')
    exit 3
}

# 退出码：0 成功；2 预检被阻塞；3 缺少 -ConfirmPublish；4 digest 漂移；
# 1 硬失败（含 publish.ps1 内部错误）；其余一律透传 publish.ps1 的退出码。
$ExitBlocked = 2
$ExitDrift = 4
# 非 JSON 输出原样透出时的截断长度，避免把巨量 stderr 塞进 JSON 信封。
$RawTextLimit = 20000
$TempPrefix = 'wms-publish-run'

function Get-ReportProperty($Object, [string]$Name) {
    # Set-StrictMode 2.0 下访问不存在的属性会抛 PropertyNotFoundException，而报告的字段集合
    # 随模式变化（Artifacts 只在成功路径上才有）。这个函数是本脚本与报告的**唯一**接触面，
    # 所有取值都走它，避免某天多读一个字段就让整条路径崩掉。
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function New-InvocationBatch([string[]]$Arguments, [string]$BatchFile, [string]$OutFile, [string]$CodeFile) {
    # 把这次调用写进一个临时 .cmd，再让 cmd 去跑它。两个理由：
    # 1) %ERRORLEVEL% 必须**在执行时**求值。写成 `cmd /c "... & echo %ERRORLEVEL%"` 时，
    #    cmd 会在解析期就把它展开成调用前的旧值，拿到的退出码是错的（实测）。
    #    批处理文件里每行在执行时才展开，结果正确。
    # 2) ShellExecute 只接受一个不含参数的命令行，把参数拼装关进批处理省掉一整层转义风险。
    $parts = @(ConvertTo-CmdQuoted 'powershell.exe')
    foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PublishScript) + @($Arguments)) {
        $parts += (ConvertTo-CmdQuoted $argument)
    }
    $lines = @(
        '@echo off'
        ('{0} > {1} 2>&1' -f ($parts -join ' '), (ConvertTo-CmdQuoted $OutFile))
        ('echo %ERRORLEVEL% > {0}' -f (ConvertTo-CmdQuoted $CodeFile))
    )
    # 批处理按 ANSI 读文件，而这里只写 ASCII，因此有没有 BOM 都不影响；用 UTF-8 无 BOM 保持字节最小。
    [IO.File]::WriteAllLines($BatchFile, $lines, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-PublishCaptured([string[]]$Arguments) {
    # 关键约束：**整棵子进程树必须从一次不继承句柄的派生开始。**
    #
    # 实测 2026-09-23：调用方写成 `& powershell -File publish.ps1 ... 2>&1 | Out-String`，
    # 发布 11:53:43 已 succeeded 并落盘，外层读端到 12:17（24 分钟）仍未返回，只能手工终止。
    # 成因是 Windows 的句柄继承按句柄传播：PDA 构建派生的 Gradle 守护进程默认存活约 3 小时，
    # 它继承了调用方那条管道的**写端**，于是调用方的读端永远等不到 EOF。
    #
    # 当天的 2x2 实验（本机 PowerShell 5.1）：
    #   常驻后代用 CreateProcess（继承句柄）+ 调用方用管道 -> 挂死
    #   常驻后代用 ShellExecute（不继承）    + 调用方用管道 -> 2.7s 返回
    #   常驻后代用 CreateProcess             + 调用方写文件 -> 2.1s 返回
    # 并且**清掉自己标准句柄上的 HANDLE_FLAG_INHERIT 无效**：读回确认标志已由 1 变 0，
    # 管道用例照样挂死（PowerShell 内部另持一份可继承引用，清 GetStdHandle 的那一份拦不住）。
    # 所以修复点不在句柄标志，而在派生方式。
    #
    # UseShellExecute=$true 走 ShellExecuteEx，bInheritHandles=FALSE：这棵树的根拿不到任何
    # 调用方句柄，下面无论再派生多少层、谁常驻多久，都无从继承那条管道。代价是拿不到 ExitCode
    # （ShellExecute 不返回进程句柄），因此让临时 .cmd 把 %ERRORLEVEL% 写进文件再读回来。
    #
    # 注意：lib/exec.ps1 的 Invoke-CapturedProcess 用的是 UseShellExecute=$false，**不能**拿它
    # 替代本函数——它自己也要靠 cmd 的文件重定向，但它派生出的进程会继承调用方的管道句柄，
    # 正好是这里要避免的那件事。
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter "$TempPrefix-*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $token = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('{0}-{1}.out' -f $TempPrefix, $token)
    $codeFile = Join-Path ([IO.Path]::GetTempPath()) ('{0}-{1}.code' -f $TempPrefix, $token)
    $batchFile = Join-Path ([IO.Path]::GetTempPath()) ('{0}-{1}.cmd' -f $TempPrefix, $token)
    $exitCode = $null
    $bytes = [byte[]]@()
    try {
        New-InvocationBatch $Arguments $batchFile $outFile $codeFile
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = 'cmd.exe'
        $startInfo.Arguments = '/c ' + (ConvertTo-CmdQuoted $batchFile)
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        $process.Dispose()
        $bytes = Read-FileSharedBytes $outFile
        $codeText = (Get-SafeText (Read-FileSharedBytes $codeFile)).Trim()
        # 拿不到退出码一律判失败，不得默认成功。
        if ($codeText -match '^-?\d+$') { $exitCode = [int]$codeText } else { $exitCode = 1 }
    } finally {
        # 常驻后代仍持有句柄时删不掉，留几个临时文件即可，不影响发布结果。
        foreach ($path in @($outFile, $codeFile, $batchFile)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Bytes = $bytes }
}

function ConvertFrom-Report([byte[]]$Bytes) {
    $text = Get-SafeText $Bytes
    try { return [pscustomobject]@{ Text = $text; Json = ($text | ConvertFrom-Json) } }
    catch { return $null }
}

function Write-Stage([string]$Stage, $Report) {
    if ($Json) { return }
    if ($Stage -eq 'Preflight') {
        # 预检报告本身就是给人看的格式（publish.ps1 已按缩进 JSON 输出），原样透出。
        Write-Output '--- 预检 ---'
        Write-Output $Report.Text.Trim()
        # 破坏性动作在 JSON 里位于 Plan 之下，容易被淹没。用户的确认摘要必须包含它们，
        # 因此单独再列一次：确认的是「会删掉/覆盖什么」，不是「大概那个计划」。
        $destructive = @(Get-ReportProperty (Get-ReportProperty $Report.Json 'Plan') 'DestructiveActions')
        if ($destructive.Count -gt 0) {
            Write-Output ''
            Write-Output '--- 将被删除/覆盖的原产物（确认摘要必须包含这些）---'
            $destructive | ForEach-Object { Write-Output ('  - {0}' -f $_) }
        }
        return
    }
    # 执行阶段的完整报告里有 Plan 与 config.js 全文，重复打印只是噪音；这里只摘要点，
    # 完整内容仍然留在 -Json 输出与日志文件里。
    $json = $Report.Json
    Write-Output '--- 发布 ---'
    Write-Output ('状态：{0}' -f [string](Get-ReportProperty $json 'Status'))
    Write-Output ('版本：{0}' -f [string](Get-ReportProperty $json 'Version'))
    Write-Output ('目录：{0}' -f [string](Get-ReportProperty $json 'OutputDirectory'))
    $artifacts = @(Get-ReportProperty $json 'Artifacts')
    if ($artifacts.Count -gt 0) {
        Write-Output '产物：'
        $artifacts | ForEach-Object { Write-Output ('  - {0}' -f $_) }
    }
    $logPath = [string](Get-ReportProperty $json 'LogPath')
    if (-not [string]::IsNullOrWhiteSpace($logPath)) { Write-Output ('日志：{0}' -f $logPath) }
}

function Write-RawFallback([string]$Stage, [byte[]]$Bytes) {
    # publish.ps1 硬失败时只往 stderr 写 ERROR 并 exit 1，不产出 JSON 报告。
    # 此时必须原样透出并透传退出码，不能把自己的解析失败当成新错误——发布可能已经发生过。
    $text = (Get-SafeText $Bytes).Trim()
    if ($text.Length -gt $RawTextLimit) { $text = $text.Substring(0, $RawTextLimit) + "`n…（已截断）" }
    if (-not $Json -and -not [string]::IsNullOrWhiteSpace($text)) {
        Write-Output ('--- {0}（非 JSON 输出，原样透出）---' -f $Stage)
        Write-Output $text
    }
    return $text
}

# 透传参数。只列本脚本声明过的项，其余一律不代传，避免改变 publish.ps1 的默认行为。
# -Json 恒传：本脚本要解析报告，被调用方必须输出 JSON。
# 写开来而不是用循环拼：四个开关的名字与取值方式各不相同，循环只会让这里变得需要二次解读。
# 留空即不传，让 publish.ps1 用自己的默认值（尤其 -VersionSuffix：传空串与不传等价，
# 但少传一个参数就少一处可能写错的地方）。
$forward = @('-Target', $Target, '-Config', $Config, '-Json')
if (-not [string]::IsNullOrWhiteSpace($Only)) { $forward += @('-Only', $Only) }
if (-not [string]::IsNullOrWhiteSpace($Kind)) { $forward += @('-Kind', $Kind) }
if (-not [string]::IsNullOrWhiteSpace($Version)) { $forward += @('-Version', $Version) }
if (-not [string]::IsNullOrWhiteSpace($VersionSuffix)) { $forward += @('-VersionSuffix', $VersionSuffix) }
if ($BumpVersion) { $forward += '-BumpVersion' }
if ($AllowDirty) { $forward += '-AllowDirty' }
if ($AllowStale) { $forward += '-AllowStale' }
if ($ConfirmBranch) { $forward += '-ConfirmBranch' }

$result = [ordered]@{
    Mode       = $Mode
    Target     = $Target
    Only       = $Only
    Kind       = $Kind
    PlanDigest = $null
    BatchStamp = $null
    Preflight  = $null
    Publish    = $null
}

# 两种模式都先跑预检：Publish 模式靠它取得 digest 与批次时间戳，Preflight 模式靠它输出计划。
$preRaw = Invoke-PublishCaptured $forward
$pre = ConvertFrom-Report $preRaw.Bytes
if ($null -eq $pre) {
    $result.PreflightRawText = Write-RawFallback 'Preflight' $preRaw.Bytes
    $result.ExitCode = $preRaw.ExitCode
    if ($Json) { $result | ConvertTo-Json -Depth 12 }
    exit $preRaw.ExitCode
}

$result.Preflight = $pre.Json
$result.PlanDigest = [string](Get-ReportProperty $pre.Json 'PlanDigest')
$result.BatchStamp = [string](Get-ReportProperty $pre.Json 'BatchStamp')
Write-Stage 'Preflight' $pre

$blocking = @(Get-ReportProperty $pre.Json 'BlockingReasons')
if ($blocking.Count -gt 0) {
    if (-not $Json) {
        Write-Output ''
        Write-Output '--- 阻塞原因 ---'
        $blocking | ForEach-Object { Write-Output ('  - {0}' -f $_) }
    }
    $result.ExitCode = $ExitBlocked
    if ($Json) { $result | ConvertTo-Json -Depth 12 }
    exit $ExitBlocked
}
if ($preRaw.ExitCode -ne 0) {
    if (-not $Json) { Write-Output ('预检以退出码 {0} 结束。' -f $preRaw.ExitCode) }
    $result.ExitCode = $preRaw.ExitCode
    if ($Json) { $result | ConvertTo-Json -Depth 12 }
    exit $preRaw.ExitCode
}
if ([string]::IsNullOrWhiteSpace($result.PlanDigest)) {
    if (-not $Json) { Write-Output '预检未返回 PlanDigest，已中止。' }
    $result.ExitCode = $ExitBlocked
    if ($Json) { $result | ConvertTo-Json -Depth 12 }
    exit $ExitBlocked
}

if ($Mode -eq 'Preflight') {
    if (-not $Json) { Write-Output ('PlanDigest: {0}' -f $result.PlanDigest) }
    $result.ExitCode = 0
    if ($Json) { $result | ConvertTo-Json -Depth 12 }
    exit 0
}

# 漂移校验：只在本脚本进程内完成，因此「预检 -> 执行」之间不再有可被外部文件轮换翻转的窗口。
if (-not [string]::IsNullOrWhiteSpace($ExpectedDigest) -and $ExpectedDigest -ne $result.PlanDigest) {
    if (-not $Json) { Write-Output ('digest 漂移：期望 {0}，本次预检 {1}。已中止。' -f $ExpectedDigest, $result.PlanDigest) }
    $result.ExitCode = $ExitDrift
    if ($Json) { $result | ConvertTo-Json -Depth 12 }
    exit $ExitDrift
}

$publishArgs = $forward + @('-Mode', 'Publish', '-ConfirmPublish', '-PlanDigest', $result.PlanDigest)
# 把预检算出的批次时间戳透传给执行阶段：否则跨过整点时，报出来的包名会与实际落盘的包名
# 差一个小时。它不进 digest（那是墙上时钟，进去只会让预检无端漂移），所以这里必须显式带上。
if (-not [string]::IsNullOrWhiteSpace($result.BatchStamp)) { $publishArgs += @('-BatchStamp', $result.BatchStamp) }
$pubRaw = Invoke-PublishCaptured $publishArgs
$pub = ConvertFrom-Report $pubRaw.Bytes
if ($null -eq $pub) {
    $result.PublishRawText = Write-RawFallback 'Publish' $pubRaw.Bytes
} else {
    $result.Publish = $pub.Json
    Write-Stage 'Publish' $pub
}

$result.ExitCode = $pubRaw.ExitCode
if ($Json) { $result | ConvertTo-Json -Depth 12 }
exit $pubRaw.ExitCode
