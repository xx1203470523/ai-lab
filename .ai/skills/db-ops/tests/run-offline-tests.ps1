<#
.SYNOPSIS
    db-ops 阶段 1 离线测试（T1–T30）。**不连接任何数据库，不触碰真实凭据文件。**

.DESCRIPTION
    三个不容妥协的测试纪律：

    1) 每个用例都在自己的「技能根副本」里跑：临时目录下放一份 config/policy.json，
       其 credentialsPath 指向该临时目录内的凭据文件。真实凭据路径来自
       %LOCALAPPDATA%\db-ops\credentials.env，本测试**从不读写它**。
    2) 每个用例都在**子进程**里跑。db-ops.ps1 用 exit 交付退出码，而在同一进程里
       调用它会让 exit 终止测试进程本身，于是所有用例只能测到一个退出码。
       子进程也是唯一能忠实测出「调用方实际看到的退出码」的方式。
    3) 断言的对象是**真实字节**：子进程的 stdout/stderr 被按 UTF-8 解码后参与断言，
       因此中文乱码（U+FFFD）会直接让用例失败，而不是被静默忽略。

    结果同时打印到 stdout 并写入 -ReportPath（JSON + 可读日志）。全套用例只在
    最后输出一张汇总表；FAIL 用例会额外打印证据行。

.NOTES
    必须保存为 UTF-8 with BOM。

    另有一条 Windows PowerShell 5.1 陷阱值得记在这里：数组子表达式 @() **不能**作用于
    System.Collections.Generic.List[object]（会抛 ArgumentException「Argument types do
    not match」）。详见报告写入处的注释——那条报错曾经把整条测试的收尾打死。
#>
param(
    # 被测试的技能根目录。默认取本文件上一级。
    [string]$SkillRoot,

    # 临时工作根。默认 %TEMP%\db-ops-tests-<随机>。
    [string]$WorkRoot,

    # 保留临时目录以便事后排查（默认删除）。
    [switch]$KeepWork,

    # 结果报告路径（JSON）。默认写到临时工作根下。
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'

# 兜底 trap：一个用例里未捕获的终止性错误，曾让**整条测试**在无声中结束——
# 没有汇总、没有报告、临时目录也没清，看起来像测试根本没跑过。有了它，
# 这种错误变成一行显眼输出，后面的用例继续执行；被跳过的用例会在汇总处的
# 「期望条数」上立刻显形，不会被当成全绿。
trap {
    Write-Host ''
    Write-Host ('!!! 未捕获异常（后续用例继续执行）：{0}' -f $_.Exception.Message)
    Write-Host ('    {0}' -f $_.InvocationInfo.PositionMessage)
    continue
}

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

# $PSScriptRoot 在 param 块默认值里是空的（Windows PowerShell 5.1），因此只在脚本体里解析。
if ([string]::IsNullOrWhiteSpace($SkillRoot)) { $SkillRoot = Split-Path -Parent $PSScriptRoot }
$SkillRoot = [IO.Path]::GetFullPath($SkillRoot)
if (-not (Test-Path -LiteralPath $SkillRoot -PathType Container)) { throw "技能根目录不存在：$SkillRoot" }

if ([string]::IsNullOrWhiteSpace($WorkRoot)) {
    $WorkRoot = Join-Path $env:TEMP ('db-ops-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$null = New-Item -ItemType Directory -Force -Path $WorkRoot
# 默认写到 %TEMP% 而不是工作根：工作根在收尾时会被删除，报告写在里面等于写完就丢。
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath = Join-Path $env:TEMP 'db-ops-test-report.json' }

$script:BaseDir = $WorkRoot
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DbOpsScript = Join-Path $SkillRoot 'scripts\db-ops.ps1'
$script:SetupScript = Join-Path $SkillRoot 'scripts\setup-credentials.ps1'
$script:RealPolicyPath = Join-Path $SkillRoot 'config\policy.json'
$script:RealRoutesPath = Join-Path $SkillRoot 'config\routes.json'
$script:PowerShellExe = Join-Path $PSHOME 'powershell.exe'

foreach ($required in @($script:DbOpsScript, $script:SetupScript, $script:RealPolicyPath, $script:RealRoutesPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少被测试文件：$required" }
}

# 测试用的假口令。长度 > 8，因此一定会进入脱敏判定的范围。
$script:FakePassDev = 'Fake-Pass-Alpha-0001'
$script:FakePassProd = 'Fake-Pass-Bravo-0002'
$script:FakeUser = 'wms_rd'

Set-StrictMode -Version 2.0

# 先把被测库 dot-source 进本测试进程，原因有两个：
#   1) 夹具需要调用技能自己的 Set-CredentialsFileAcl——新建文件会继承父目录的 ACL
#      （含 Users/Everyone 之类），不收紧的话每个夹具用例都会先撞上 permission-warning，
#      于是「目标究竟 ready 不 ready」这件事根本没被测到；
#   2) 掩码 / LIMIT 追加 / 加引号往返这些用例直接调用库函数做单元级验证。
. (Join-Path $SkillRoot 'scripts\lib\common.ps1')
. (Join-Path $SkillRoot 'scripts\lib\log.ps1')
. (Join-Path $SkillRoot 'scripts\lib\config.ps1')
. (Join-Path $SkillRoot 'scripts\lib\credentials.ps1')
. (Join-Path $SkillRoot 'scripts\lib\sql-safety.ps1')
. (Join-Path $SkillRoot 'scripts\lib\output.ps1')

# ---------------------------------------------------------------------------
# 子进程执行
# ---------------------------------------------------------------------------

function ConvertTo-CommandLineArgument {
    # 按 Windows 命令行规则给单个参数加引号：内部 " 转义为 \"，紧邻引号的反斜杠翻倍。
    # 必须自己做：Start-Process -ArgumentList 传数组时是把元素用空格拼起来的，
    # 含空格或中文的路径会被拆成两个参数。本测试要跑含中文与空格的路径（T22），
    # 所以不能省这一步。
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            $null = $builder.Append(('\' * ($backslashes * 2 + 1)))
            $null = $builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { $null = $builder.Append(('\' * $backslashes)); $backslashes = 0 }
        $null = $builder.Append($ch)
    }
    if ($backslashes -gt 0) { $null = $builder.Append(('\' * ($backslashes * 2))) }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Invoke-ChildProcess {
    # stdin 一律重定向并立即关闭：这既保证不会有任何用例挂住，也使
    # [Console]::IsInputRedirected 在子进程里为 true（T19 正是要测这个）。
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:PowerShellExe
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($Arguments)
    $quoted = @($all | ForEach-Object { ConvertTo-CommandLineArgument -Value $_ })
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stopwatch.Stop()

    return [pscustomobject]@{
        ExitCode  = $proc.ExitCode
        StdOut    = $outTask.Result
        StdErr    = $errTask.Result
        ElapsedMs = [int]$stopwatch.ElapsedMilliseconds
        Combined  = ($outTask.Result + "`n" + $errTask.Result)
    }
}

function Invoke-DbOps {
    param($Work, [string[]]$Arguments)
    return (Invoke-ChildProcess -ScriptPath $script:DbOpsScript -Arguments (@($Arguments) + @('-Root', $Work.Dir)))
}

# ---------------------------------------------------------------------------
# 临时技能根 / 凭据构造
# ---------------------------------------------------------------------------

function New-TestWork {
    param(
        [string]$Name,
        # $null = 不创建凭据文件
        [string]$CredentialsBody,
        [string]$CredentialsFileName = 'credentials.env',
        # $null = 用真实 policy，只把 credentialsPath 指到临时目录
        [string]$PolicyText,
        # $null = 用真实 routes.json
        [string]$RoutesText,
        # $null = 凭据文件放在临时技能根内
        [string]$CredentialsPathOverride
    )

    $dir = Join-Path $script:BaseDir $Name
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'config')

    $credPath = $CredentialsPathOverride
    if ([string]::IsNullOrWhiteSpace($credPath)) { $credPath = Join-Path $dir $CredentialsFileName }

    if ([string]::IsNullOrWhiteSpace($PolicyText)) {
        $policy = ConvertFrom-Json ([IO.File]::ReadAllText($script:RealPolicyPath))
        $policy.credentialsPath = $credPath
        $PolicyText = ConvertTo-Json -InputObject $policy -Depth 10
    }
    [IO.File]::WriteAllText((Join-Path $dir 'config\policy.json'), $PolicyText, $script:Utf8NoBom)

    if ([string]::IsNullOrWhiteSpace($RoutesText)) { $RoutesText = [IO.File]::ReadAllText($script:RealRoutesPath) }
    [IO.File]::WriteAllText((Join-Path $dir 'config\routes.json'), $RoutesText, $script:Utf8NoBom)

    # 空字符串与 $null 必须分开判：未传 [string] 参数时它是 ''，用 `$null -ne` 判会
    # 走「要写凭据文件」的分支，于是所有「文件不存在」的用例都被写成一个空文件。
    if (-not [string]::IsNullOrWhiteSpace($CredentialsBody)) {
        $parent = Split-Path -Parent $credPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            $null = New-Item -ItemType Directory -Force -Path $parent
        }
        [IO.File]::WriteAllText($credPath, $CredentialsBody, $script:Utf8NoBom)
        # 把夹具做成 setup-credentials.ps1 的产物形状（仅当前用户可访问）。不收紧的话，
        # 新建文件继承来的 ACL 会让每条「应当 ready」的用例都停在 permission-warning。
        Set-CredentialsFileAcl -Path $credPath
    }

    return [pscustomobject]@{ Dir = $dir; CredentialsPath = $credPath }
}

function Get-PatchedRoutesText {
    # 需要改 routes.json 的用例走这里：先解析、再改、再序列化，避免对 JSON 文本
    # 做字符串替换（缩进或字段顺序一变，替换就会静默失效）。
    param([scriptblock]$Patch)
    $obj = ConvertFrom-Json ([IO.File]::ReadAllText($script:RealRoutesPath))
    $obj = & $Patch $obj
    return (ConvertTo-Json -InputObject $obj -Depth 20)
}

function New-CredentialsBody {
    # 生成一份结构合法的凭据文件内容。
    param([hashtable]$Entries)
    $lines = @('# db-ops test fixture')
    foreach ($key in @($Entries.Keys | Sort-Object)) { $lines += ('{0}={1}' -f $key, $Entries[$key]) }
    return (($lines -join "`r`n") + "`r`n")
}

function Get-DevCredentialEntries {
    param([string]$UserName = $script:FakeUser, [string]$HostName = '10.10.80.211', [string]$Pass = $script:FakePassDev)
    return @{
        DEV_LEBGJM_DB_HOST = $HostName
        DEV_LEBGJM_DB_PORT = '3306'
        DEV_LEBGJM_DB_USER = $UserName
        DEV_LEBGJM_DB_PASS = $Pass
    }
}

function Get-ProdSharedCredentialEntries {
    return @{
        PROD_SHARED_DB_HOST = '10.10.76.167'
        PROD_SHARED_DB_PORT = '3306'
        PROD_SHARED_DB_USER = $script:FakeUser
        PROD_SHARED_DB_PASS = $script:FakePassProd
    }
}

function New-SqlFile {
    param($Work, [string]$Name, [string]$Sql)
    $path = Join-Path $Work.Dir $Name
    [IO.File]::WriteAllText($path, $Sql, $script:Utf8NoBom)
    return $path
}

# ---------------------------------------------------------------------------
# 结果记录
# ---------------------------------------------------------------------------

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Id,
        [string]$Title,
        $Expect,
        $Actual,
        [bool]$Ok,
        [string]$Detail
    )
    $script:Results.Add([pscustomobject]@{
        Id     = $Id
        Title  = $Title
        Expect = [string]$Expect
        Actual = [string]$Actual
        Ok     = $Ok
        Detail = $Detail
    })
    $mark = 'FAIL'
    if ($Ok) { $mark = 'PASS' }
    Write-Host ('{0}  {1}  {2}  [期望 {3} / 实际 {4}]  {5}' -f $mark, $Id, $Title, $Expect, $Actual, $Detail)
}

function Get-EvidenceLine {
    # 从输出里挑一行作为证据，便于在汇总里看出「实际发生了什么」。
    param([string]$Text, [string]$Pattern)
    foreach ($line in @($Text -split "\r?\n")) {
        if ($line -match $Pattern) { return $line.Trim() }
    }
    return ''
}

# ---------------------------------------------------------------------------
# 用例
# ---------------------------------------------------------------------------

Write-Host '=== db-ops 阶段 1 离线测试 ==='
Write-Host ('技能根 ：{0}' -f $SkillRoot)
Write-Host ('工作根 ：{0}' -f $WorkRoot)
Write-Host ('子进程 ：{0}' -f $script:PowerShellExe)
Write-Host ''

$readyWork = New-TestWork -Name 'ready-dev' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries))
$noCredWork = New-TestWork -Name 'no-credentials'

# --- T01 未知路由 ---------------------------------------------------------
$r = Invoke-DbOps -Work $noCredWork -Arguments @('-Mode', 'Validate', '-Target', 'nope')
Add-Result -Id 'T01' -Title '未知路由被拒绝（不近似匹配）' -Expect 6 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 6 -and $r.Combined.Contains('未知路由')) `
    -Detail (Get-EvidenceLine -Text $r.Combined -Pattern '未知路由|未知目标')

# --- T04 未指定目标 -------------------------------------------------------
$r = Invoke-DbOps -Work $noCredWork -Arguments @('-Mode', 'Validate')
Add-Result -Id 'T04' -Title '未指定目标不静默取默认' -Expect 6 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 6 -and $r.Combined.Contains('没有指定目标')) `
    -Detail (Get-EvidenceLine -Text $r.Combined -Pattern '没有指定目标')

# --- T05 凭据文件不存在 ---------------------------------------------------
$r = Invoke-DbOps -Work $noCredWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T05' -Title '凭据缺失 → missing + 不自动创建' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('凭据文件状态：missing') -and -not (Test-Path -LiteralPath $noCredWork.CredentialsPath)) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '凭据文件状态|凭据文件不存在')

# --- T02 前缀缺失（ready 路由） -------------------------------------------
$partialWork = New-TestWork -Name 'partial-prod-shared' -CredentialsBody (New-CredentialsBody -Entries (Get-ProdSharedCredentialEntries))
$r = Invoke-DbOps -Work $partialWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T02' -Title '目标前缀未配置 → 列缺失键，其余路由不受影响' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('DEV_LEBGJM_DB_HOST') -and $r.StdOut.Contains('需要 4 个键')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '需要 4 个键')

# --- T02b 正向：一条路由真的能到 ready ------------------------------------
$prodReadyWork = New-TestWork -Name 'ready-prod-shared' -CredentialsBody (New-CredentialsBody -Entries (Get-ProdSharedCredentialEntries))
$r = Invoke-DbOps -Work $prodReadyWork -Arguments @('-Mode', 'Validate', '-Target', 'prod.shared')
Add-Result -Id 'T02b' -Title '配齐非 root 只读账号 → ready 且 exit 0' -Expect 0 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 0 -and $r.StdOut.Contains('有效状态  ：ready')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '有效状态')

# --- T02c 计划里 T2 的字面用例：prod.lebgty -------------------------------
# 计划的期望是「unconfigured 并列出缺失键」，但计划自己的优先级表把
# needs-review 排在 unconfigured 之前，因此这里必然先报 needs-review。
# 按优先级表实现，并把这一处不一致记录下来。
$r = Invoke-DbOps -Work $noCredWork -Arguments @('-Mode', 'Validate', '-Target', 'prod.lebgty')
Add-Result -Id 'T02c' -Title 'prod.lebgty 先命中 needs-review（优先级表如此）' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('有效状态  ：needs-review')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '有效状态')

# --- T03 高权限账号被拦 ---------------------------------------------------
$rootEntries = Get-DevCredentialEntries -UserName 'root'
$rootWork = New-TestWork -Name 'root-user' -CredentialsBody (New-CredentialsBody -Entries $rootEntries)
$r = Invoke-DbOps -Work $rootWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T03' -Title 'USER=root → blocked，且黑名单来自 policy' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('有效状态  ：blocked') -and $r.StdOut.Contains('highPrivilegeUserPattern')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '有效状态|highPrivilegeUserPattern')

# --- T06 setup 已存在且无 -Force ------------------------------------------
$beforeBytes = [IO.File]::ReadAllBytes($readyWork.CredentialsPath)
$beforeHash = (Get-FileHash -LiteralPath $readyWork.CredentialsPath -Algorithm SHA256).Hash
$beforeTime = (Get-Item -LiteralPath $readyWork.CredentialsPath).LastWriteTimeUtc
$r = Invoke-ChildProcess -ScriptPath $script:SetupScript -Arguments @('-Root', $readyWork.Dir)
$afterHash = (Get-FileHash -LiteralPath $readyWork.CredentialsPath -Algorithm SHA256).Hash
$afterTime = (Get-Item -LiteralPath $readyWork.CredentialsPath).LastWriteTimeUtc
Add-Result -Id 'T06' -Title 'setup 已存在无 -Force → 报告后拒绝改动' -Expect 0 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 0 -and $r.StdOut.Contains('未指定 -Force') -and $beforeHash -eq $afterHash -and $beforeTime -eq $afterTime) `
    -Detail ('哈希不变={0} 时间不变={1}' -f ($beforeHash -eq $afterHash), ($beforeTime -eq $afterTime))

# --- T07 结构非法的凭据文件 -----------------------------------------------
$badLine = 'THIS LINE HAS NO EQUALS SIGN'
$badBody = "# fixture`r`n$badLine`r`nDEV_LEBGJM_DB_HOST=10.10.80.211`r`nNOTAPREFIX_FOO=bar`r`n"
$badWork = New-TestWork -Name 'invalid-credentials' -CredentialsBody $badBody
$r = Invoke-DbOps -Work $badWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
$mentionsLineNumbers = ($r.Combined.Contains('第 2 行') -and $r.Combined.Contains('第 4 行'))
$noEcho = -not $r.Combined.Contains($badLine)
Add-Result -Id 'T07' -Title '非法凭据 → 指认行号/键名且不回显内容' -Expect 6 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 6 -and $mentionsLineNumbers -and $noEcho) `
    -Detail ('行号={0} 未回显坏行={1} | {2}' -f $mentionsLineNumbers, $noEcho, (Get-EvidenceLine -Text $r.Combined -Pattern '第 4 行'))

# --- T08 只配了一部分键 ---------------------------------------------------
$halfEntries = @{ DEV_LEBGJM_DB_HOST = '10.10.80.211'; DEV_LEBGJM_DB_PORT = '3306' }
$halfWork = New-TestWork -Name 'half-keys' -CredentialsBody (New-CredentialsBody -Entries $halfEntries)
$r = Invoke-DbOps -Work $halfWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T08' -Title '缺键 → 列出缺失的键名（不含值）' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('DEV_LEBGJM_DB_USER') -and $r.StdOut.Contains('DEV_LEBGJM_DB_PASS') -and $r.StdOut.Contains('缺少键')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '缺少键')

# --- T08b 一个键都没有 ---------------------------------------------------
$foreignWork = New-TestWork -Name 'other-prefix-only' -CredentialsBody (New-CredentialsBody -Entries (Get-ProdSharedCredentialEntries))
$r = Invoke-DbOps -Work $foreignWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T08b' -Title '前缀完全未配置 → 列出期望的 4 个键名' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('需要 4 个键')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '需要 4 个键')

# --- T09 ACL 放宽 ---------------------------------------------------------
$aclWork = New-TestWork -Name 'loose-acl' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries))
$icaclsOut = & icacls $aclWork.CredentialsPath /grant 'Everyone:(R)' 2>&1
$r = Invoke-DbOps -Work $aclWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T09' -Title 'ACL 放宽到 Everyone → permission-warning' -Expect 5 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 5 -and $r.StdOut.Contains('有效状态  ：permission-warning')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern 'permission-warning')

# --- T09b ACL 函数失败闭合（单元级） --------------------------------------
$aclUnitOk = $false
$aclUnitDetail = ''
try {
    $threwOnMissing = $false
    try { Set-CredentialsFileAcl -Path (Join-Path $WorkRoot 'does-not-exist.env') } catch { $threwOnMissing = $true }

    $threwOnLoose = $false
    try { $null = Assert-CredentialsFileAcl -Path $aclWork.CredentialsPath -Context '单元测试' } catch { $threwOnLoose = $true }

    $check = Test-CredentialsFileAcl -Path $aclWork.CredentialsPath
    $aclUnitOk = ($threwOnMissing -and $threwOnLoose -and -not $check.Ok)
    $aclUnitDetail = ('对不存在文件报错={0} 对放宽 ACL 报错={1} Ok={2}' -f $threwOnMissing, $threwOnLoose, $check.Ok)
} catch {
    $aclUnitDetail = ('单元准备失败：{0}' -f $_.Exception.Message)
}
Add-Result -Id 'T09b' -Title 'ACL 函数失败闭合（单元级，端到端见说明）' -Expect '抛错' -Actual '见说明' -Ok $aclUnitOk -Detail $aclUnitDetail

# --- T09c 重复收紧（实测缺陷的回归用例） ----------------------------------
# 修复前：对**已经收紧过**的凭据文件再次收紧会失败。PowerShell 的 Set-Acl 会把描述符里
# 的 SACL 一起写回，而写 SACL 需要 SeSecurityPrivilege（非提升进程没有）；更糟的是
# PrivilegeNotHeld 是**非终止**错误，在 $ErrorActionPreference='Continue' 的调用方那里
# 会被 try/catch 漏掉，于是函数返回「成功」——一个声称已保护、实际没保护的文件。
# 修复后改用只含 DACL 的 FileSecurity + [IO.File]::SetAccessControl。
# 本用例把三种状态都钉住：新文件、已收紧文件、被 icacls 放松过的文件。
$retightenOk = $false
$retightenDetail = New-Object System.Collections.Generic.List[string]
try {
    $retightenPath = Join-Path $WorkRoot 'retighten\credentials.env'
    $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $retightenPath)
    [IO.File]::WriteAllText($retightenPath, (New-CredentialsBody -Entries (Get-DevCredentialEntries)), $script:Utf8NoBom)

    Set-CredentialsFileAcl -Path $retightenPath
    $first = Test-CredentialsFileAcl -Path $retightenPath
    $retightenDetail.Add(('首次收紧 Ok={0}' -f $first.Ok))

    Set-CredentialsFileAcl -Path $retightenPath
    $second = Test-CredentialsFileAcl -Path $retightenPath
    $retightenDetail.Add(('重复收紧 Ok={0}' -f $second.Ok))

    $null = & icacls $retightenPath /grant 'Everyone:(R)' 2>&1
    $loose = Test-CredentialsFileAcl -Path $retightenPath
    Set-CredentialsFileAcl -Path $retightenPath
    $retighten = Test-CredentialsFileAcl -Path $retightenPath
    $retightenDetail.Add(('放松后 Ok={0} → 再收紧后 Ok={1}' -f $loose.Ok, $retighten.Ok))

    $retightenOk = ($first.Ok -and $second.Ok -and (-not $loose.Ok) -and $retighten.Ok)
} catch {
    $retightenDetail.Add(('抛异常：{0}' -f $_.Exception.Message))
}
Add-Result -Id 'T09c' -Title '已收紧文件可重复收紧（回归：Set-Acl 写 SACL 需特权）' -Expect '四步全通过' `
    -Actual $(if ($retightenOk) { '通过' } else { '失败' }) -Ok $retightenOk -Detail (($retightenDetail) -join '；')

# --- T10 -Environment 是 -Target 的别名 ----------------------------------
$rTarget = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
$rEnv = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Environment', 'dev.lebgjm')
Add-Result -Id 'T10' -Title '-Environment 与 -Target 输出逐字节相同' -Expect 0 -Actual ('target={0} env={1}' -f $rTarget.ExitCode, $rEnv.ExitCode) `
    -Ok ($rTarget.ExitCode -eq $rEnv.ExitCode -and $rTarget.StdOut -ceq $rEnv.StdOut) `
    -Detail ('stdout 相同={0}' -f ($rTarget.StdOut -ceq $rEnv.StdOut))

# --- T11..T14 / T24 / T25 SQL 只读守卫 ------------------------------------
$deleteWork = $readyWork
$sqlFile = New-SqlFile -Work $readyWork -Name 'q_delete.sql' -Sql 'DELETE FROM instock_order WHERE Id = 1;'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T11' -Title '写 SQL 走只读模式 → 拒绝并指向 exec-flow' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('只读模式只接受')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_like_set.sql' -Sql "SELECT * FROM t WHERE name LIKE '%SET%';"
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T12' -Title "字面量里的 SET 不再误报（旧版缺陷）" -Expect 0 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 0 -and $r.StdOut.Contains('只读语句通过静态校验')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_update_literal.sql' -Sql "SELECT * FROM t WHERE note = 'please update the record';"
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T25' -Title "字面量里的 update 不再误报" -Expect 0 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 0 -and $r.StdOut.Contains('只读语句通过静态校验')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_multi.sql' -Sql 'SELECT 1; DROP TABLE x;'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T13' -Title '多语句被拒绝' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('检测到 2 条')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_semicolon_literal.sql' -Sql "SELECT 'a;b' AS v;"
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T13b' -Title "字面量里的分号不计数" -Expect 0 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 0 -and $r.StdOut.Contains('语句条数：1')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '语句条数')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_for_update.sql' -Sql 'SELECT id FROM t FOR UPDATE;'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T14' -Title 'FOR UPDATE 被拒绝（写锁语义）' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('被拒绝的写法')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_for_share.sql' -Sql 'SELECT id FROM t FOR SHARE;'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T14b' -Title 'FOR SHARE 被拒绝（旧守卫的漏报）' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('FOR SHARE')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_sleep.sql' -Sql 'SELECT SLEEP(10);'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T14c' -Title 'SLEEP 被拒绝（旧守卫的漏报）' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('SLEEP')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_into.sql' -Sql 'SELECT COUNT(*) INTO @total FROM t;'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T14d' -Title 'INTO @var 被拒绝（会话副作用）' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('INTO')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

$sqlFile = New-SqlFile -Work $readyWork -Name 'q_comment_only.sql' -Sql '-- 只有注释，没有语句'
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-SqlPath', $sqlFile)
Add-Result -Id 'T24' -Title '只有注释的 SQL 被拒绝' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.StdOut.Contains('只有注释')) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '结论')

# --- T15 不连库：不可达主机也必须立刻成功 ---------------------------------
# 把 routes.json 声明的 host 与凭据里的 host 同时改成 TEST-NET-1（192.0.2.1，
# RFC 5737 保留地址，必然不可达）。如果实现里存在任何连接尝试，这里会超时或失败；
# 它必须既返回 ready 又秒回。
$unreachableRoutes = Get-PatchedRoutesText -Patch {
    param($obj)
    foreach ($route in $obj.routes) { if ($route.id -eq 'dev.lebgjm') { $route.host = '192.0.2.1' } }
    return $obj
}
$unreachableEntries = Get-DevCredentialEntries -HostName '192.0.2.1'
$unreachableWork = New-TestWork -Name 'unreachable-host' -CredentialsBody (New-CredentialsBody -Entries $unreachableEntries) -RoutesText $unreachableRoutes
$r = Invoke-DbOps -Work $unreachableWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T15' -Title '不可达主机仍立刻 ready → 证明未连库' -Expect '0 且 < 5s' -Actual ('{0} / {1}ms' -f $r.ExitCode, $r.ElapsedMs) `
    -Ok ($r.ExitCode -eq 0 -and $r.ElapsedMs -lt 5000) `
    -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '有效状态')

# --- T15b ExplainPlan 恒为 null -------------------------------------------
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-Json')
$planNull = $false
$jsonOk = $false
try {
    $obj = ConvertFrom-Json -InputObject $r.StdOut
    $planNull = ($null -eq $obj.ExplainPlan)
    $jsonOk = ($obj.Mode -eq 'Validate' -and $obj.Details.CredentialsFileState -eq 'present')
} catch { }
Add-Result -Id 'T15b' -Title 'JSON 信封 ExplainPlan 为 null' -Expect 'null' -Actual ('planNull={0}' -f $planNull) -Ok ($planNull -and $jsonOk) `
    -Detail ('信封可解析={0}' -f $jsonOk)

# --- T16 未知字段（拼错的 allowWrites） -----------------------------------
$typoPolicy = [IO.File]::ReadAllText($script:RealPolicyPath).Replace('"allowWrite"', '"allowWrites"')
$typoWork = New-TestWork -Name 'policy-typo' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries)) -PolicyText $typoPolicy
$r = Invoke-DbOps -Work $typoWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T16' -Title 'allowWrite 拼错 → 未知字段报错' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.Combined.Contains('未知字段')) `
    -Detail (Get-EvidenceLine -Text $r.Combined -Pattern '未知字段')

$badVersionPolicy = [IO.File]::ReadAllText($script:RealPolicyPath).Replace('"schemaVersion": 1', '"schemaVersion": 2')
$badVersionWork = New-TestWork -Name 'policy-bad-version' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries)) -PolicyText $badVersionPolicy
$r = Invoke-DbOps -Work $badVersionWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T16b' -Title 'schemaVersion 未知 → 硬失败' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $r.Combined.Contains('schemaVersion')) `
    -Detail (Get-EvidenceLine -Text $r.Combined -Pattern 'schemaVersion')

# --- T17 -ListTargets ----------------------------------------------------
$r = Invoke-DbOps -Work $noCredWork -Arguments @('-ListTargets')
$reasonLines = @($r.StdOut -split "\r?\n" | Where-Object { $_.Contains('←') })
$prodLebgLine = Get-EvidenceLine -Text $r.StdOut -Pattern '^  prod\.lebg '
$lebgWarned = ($r.StdOut -match 'prod\.lebg ←.*LEBG.*wms_lebgty')
Add-Result -Id 'T17' -Title '-ListTargets 每行带状态与依据' -Expect '0 且 19 行依据' -Actual ('{0} / {1} 行' -f $r.ExitCode, $reasonLines.Count) `
    -Ok ($r.ExitCode -eq 0 -and $reasonLines.Count -eq 19 -and $lebgWarned) `
    -Detail ('prod.lebg 告警={0}' -f $lebgWarned)

# --- T18 阶段 2 未实现 ---------------------------------------------------
foreach ($mode in @('Query', 'File', 'Check', 'Exec')) {
    $r = Invoke-DbOps -Work $noCredWork -Arguments @('-Mode', $mode, '-Target', 'dev.lebgjm')
    Add-Result -Id ('T18-' + $mode) -Title ('-Mode {0} 明确报未实现' -f $mode) -Expect 1 -Actual $r.ExitCode `
        -Ok ($r.ExitCode -eq 1 -and $r.Combined.Contains('阶段 2')) `
        -Detail (Get-EvidenceLine -Text $r.Combined -Pattern '阶段 2')
}

# --- T19 setup 在非交互环境 ----------------------------------------------
$freshWork = New-TestWork -Name 'setup-noninteractive'
$r = Invoke-ChildProcess -ScriptPath $script:SetupScript -Arguments @('-Root', $freshWork.Dir)
Add-Result -Id 'T19' -Title 'setup 非交互 → 7 且不写文件、不挂起' -Expect 7 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 7 -and -not (Test-Path -LiteralPath $freshWork.CredentialsPath) -and $r.Combined.Contains('无法交互')) `
    -Detail ('未创建文件={0} | {1}' -f (-not (Test-Path -LiteralPath $freshWork.CredentialsPath)), (Get-EvidenceLine -Text $r.Combined -Pattern '无法交互'))

# --- T19b setup -Force 缺 -ConfirmReset 的次序 ----------------------------
# 非交互判定排在 -Force/-ConfirmReset 之前，因此这里仍然是 7。
# 该用例记录的是「两个拒绝的先后」，不涉及写文件。
$r = Invoke-ChildProcess -ScriptPath $script:SetupScript -Arguments @('-Root', $freshWork.Dir, '-Force')
Add-Result -Id 'T19b' -Title 'setup -Force 在非交互下仍先拦交互性' -Expect 7 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 7) -Detail (Get-EvidenceLine -Text $r.Combined -Pattern '无法交互')

# --- T20 单元素数组不被 ConvertTo-Json 展开 --------------------------------
$warnRoutes = Get-PatchedRoutesText -Patch {
    param($obj)
    foreach ($route in $obj.routes) { if ($route.id -eq 'dev.lebgjm') { $route.database = 'wms_wrong' } }
    return $obj
}
$warnWork = New-TestWork -Name 'one-warning' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries)) -RoutesText $warnRoutes
$r = Invoke-DbOps -Work $warnWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-Json')
$arrayOk = $false
$oneWarning = $false
try {
    $obj = ConvertFrom-Json -InputObject $r.StdOut
    $arrayOk = ($obj.Warnings -is [System.Array])
    $oneWarning = (@($obj.Warnings).Count -eq 1)
} catch { }
Add-Result -Id 'T20' -Title '单个警告仍序列化为数组' -Expect 'array(1)' -Actual ('array={0} count={1}' -f $arrayOk, $oneWarning) `
    -Ok ($arrayOk -and $oneWarning) -Detail (Get-EvidenceLine -Text $r.StdOut -Pattern '据点映射冲突')

# --- T21 假口令不出现在任何输出 -------------------------------------------
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
$fileHasSecret = ([IO.File]::ReadAllText($readyWork.CredentialsPath)).Contains($script:FakePassDev)
$leakedInValidate = ($r.Combined.Contains($script:FakePassDev))
$rSetup = Invoke-ChildProcess -ScriptPath $script:SetupScript -Arguments @('-Root', $readyWork.Dir)
$leakedInSetup = ($rSetup.Combined.Contains($script:FakePassDev))
Add-Result -Id 'T21' -Title '假口令不出现在 stdout/stderr（且确实写进了文件）' -Expect '不出现' -Actual ('validate={0} setup={1}' -f $leakedInValidate, $leakedInSetup) `
    -Ok ((-not $leakedInValidate) -and (-not $leakedInSetup) -and $fileHasSecret) `
    -Detail ('文件里确实有该值={0}' -f $fileHasSecret)

# --- T21b 脱敏断言本身是活的（单元） --------------------------------------
$guardFired = $false
try { Assert-NoSecretInOutput -Text ('x' + $script:FakePassDev + 'y') -Secrets @($script:FakePassDev) } catch { $guardFired = $true }
$guardSilent = $true
try { Assert-NoSecretInOutput -Text 'clean text' -Secrets @($script:FakePassDev) } catch { $guardSilent = $false }
$shortIgnored = $true
try { Assert-NoSecretInOutput -Text 'value=abc' -Secrets @('abc') } catch { $shortIgnored = $false }
Add-Result -Id 'T21b' -Title '脱敏断言会被触发，且短值不参与判定' -Expect 'true/true/true' -Actual ('{0}/{1}/{2}' -f $guardFired, $guardSilent, $shortIgnored) `
    -Ok ($guardFired -and $guardSilent -and $shortIgnored) -Detail ''

# --- T22 中文与空格路径 ---------------------------------------------------
$cnDir = Join-Path $WorkRoot '中文 目录\技能 副本'
$cnWork = New-TestWork -Name '中文 目录\技能 副本' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries))
$r = Invoke-DbOps -Work $cnWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
$noMojibake = -not ($r.StdOut.Contains([char]0xFFFD) -or $r.StdErr.Contains([char]0xFFFD))
$cnPrinted = $r.StdOut.Contains('依据') -and $r.StdOut.Contains('有效状态')
Add-Result -Id 'T22' -Title '中文/空格路径可读写且中文不乱码' -Expect 0 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 0 -and $noMojibake -and $cnPrinted) `
    -Detail ('无 U+FFFD={0} 中文正常={1}' -f $noMojibake, $cnPrinted)

# --- T22b %VAR% 路径 token 展开 -------------------------------------------
$tokenWork = New-TestWork -Name 'token-path' -CredentialsPathOverride '%TEMP%\db-ops-token-test\credentials.env'
# 凭据文件写在**展开后**的真实位置；policy 里保留未展开的 %TEMP% 写法。
# 这里刻意不给 New-TestWork 传 -CredentialsBody：传了它会按字面量去建一个名为
# "%TEMP%" 的目录（相对当前目录），反而会污染工作目录。
# 先清掉上一轮的残留：本用例的目录名是固定的，残留会带着上一轮收紧过的 ACL 进来。
# 修复前正是这个残留把整条测试打死在这里（对一个 DACL 已保护的文件再次收紧会抛
# SeSecurityPrivilege）；库已改，但用例自己也不该吃跨轮状态。
$tokenDir = Join-Path $env:TEMP 'db-ops-token-test'
if (Test-Path -LiteralPath $tokenDir) { Remove-Item -LiteralPath $tokenDir -Recurse -Force }
$tokenRealPath = Join-Path $env:TEMP 'db-ops-token-test\credentials.env'
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tokenRealPath)
[IO.File]::WriteAllText($tokenRealPath, (New-CredentialsBody -Entries (Get-DevCredentialEntries)), $script:Utf8NoBom)
Set-CredentialsFileAcl -Path $tokenRealPath
$r = Invoke-DbOps -Work $tokenWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
# 判定「token 确实展开到了真实文件」：展开失败会被 Test-ContainsUnresolvedToken 判成硬失败
# （exit 1/6），展开到一个不存在的路径则会报 missing。所以状态是 present 就证明 %TEMP%
# 被换成了真实目录。不比对完整路径字符串：$env:TEMP 可能是 8.3 短名，而脚本内部可能
# 拿到长名，同一目录两种写法——比字符串会把一个正常的实现判成失败。
$tokenState = Get-EvidenceLine -Text $r.StdOut -Pattern '凭据文件状态'
$tokenFound = ($tokenState -match 'present')
Add-Result -Id 'T22b' -Title '%TEMP% token 展开到真实文件' -Expect '0 且状态 present' -Actual ('{0} / {1}' -f $r.ExitCode, $tokenState) `
    -Ok ($r.ExitCode -eq 0 -and $tokenFound) `
    -Detail ('真实路径：{0}' -f $tokenRealPath)

# --- T23 -Database 覆盖被拒绝 --------------------------------------------
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm', '-Database', 'wms_lebg')
Add-Result -Id 'T23' -Title '-Database 覆盖被拒绝' -Expect 6 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 6 -and $r.Combined.Contains('不允许用 -Database')) `
    -Detail (Get-EvidenceLine -Text $r.Combined -Pattern '不允许用 -Database')

# --- T26 routes.json 非法 → 不打印半张表 ----------------------------------
$brokenRoutesWork = New-TestWork -Name 'broken-routes' -CredentialsBody (New-CredentialsBody -Entries (Get-DevCredentialEntries)) -RoutesText '{"schemaVersion": 1, "routes": ['
$r = Invoke-DbOps -Work $brokenRoutesWork -Arguments @('-ListTargets')
$noPartialTable = -not ($r.StdOut.Contains('依据：') -or $r.StdOut.Contains('Route '))
Add-Result -Id 'T26' -Title 'routes.json 非法 → 不打印半张表' -Expect 1 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 1 -and $noPartialTable) -Detail ('未打印半张表={0}' -f $noPartialTable)

# --- T27 只读守卫的单元覆盖（掩码 / LIMIT 追加 / 大小写） ------------------
$unitDetail = New-Object System.Collections.Generic.List[string]
$unitOk = $true

$masked = Get-MaskedSql -Text "SELECT 1 -- c`r`nFROM t"
if ($masked.Length -ne "SELECT 1 -- c`r`nFROM t".Length) { $unitOk = $false; $unitDetail.Add('掩码长度不等于原文长度') }
if (-not $masked.Contains("`r`n")) { $unitOk = $false; $unitDetail.Add('掩码没有保留换行') }
if ($masked.Contains('c')) { $unitOk = $false; $unitDetail.Add('注释内容未被掩掉') }

$withLimit = Add-SqlLimitIfMissing -Text 'SELECT id FROM t LIMIT 10 OFFSET 5' -Limit 100
if ($withLimit -ne 'SELECT id FROM t LIMIT 10 OFFSET 5') { $unitOk = $false; $unitDetail.Add('已有 LIMIT/OFFSET 仍被追加') }
$appended = Add-SqlLimitIfMissing -Text 'SELECT id FROM t;' -Limit 100
if ($appended -ne "SELECT id FROM t`nLIMIT 100;") { $unitOk = $false; $unitDetail.Add(('追加结果不符：{0}' -f $appended)) }
$trailingComment = Add-SqlLimitIfMissing -Text "SELECT id FROM t -- note" -Limit 5
if (-not $trailingComment.Contains('LIMIT 5')) { $unitOk = $false; $unitDetail.Add('结尾注释时未追加 LIMIT') }

$lower = Test-ReadOnlySql -Text 'select id from t'
if (-not $lower.Ok) { $unitOk = $false; $unitDetail.Add('小写 select 被拒绝') }

Add-Result -Id 'T27' -Title '掩码/LIMIT 追加/大小写（单元）' -Expect '全部通过' -Actual $(if ($unitOk) { '通过' } else { '失败' }) `
    -Ok $unitOk -Detail (($unitDetail) -join '；')

# --- T28 凭据值加引号与解析的对称性（单元） -------------------------------
$trickyValues = @(
    'p#ss=word',
    'has space inside',
    ' trailing-space ',
    'quote"inside',
    'back\slash',
    "single'quote",
    'plain-value',
    '#leading-hash',
    '=leading-equals'
)
$roundTripOk = $true
$roundTripDetail = New-Object System.Collections.Generic.List[string]
foreach ($value in $trickyValues) {
    $table = @{ 'UNIT_DB_PASS' = $value }
    $content = New-CredentialsFileContent -CredentialTable $table -Header '# unit'
    $tmp = Join-Path $WorkRoot ('roundtrip-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.env')
    [IO.File]::WriteAllText($tmp, $content, $script:Utf8NoBom)
    $parsed = Read-CredentialsEnv -Path $tmp -AllowedKeyPattern '^[A-Z][A-Z0-9_]*_DB_(HOST|PORT|USER|PASS)$'
    if ($parsed.Errors.Count -gt 0) {
        $roundTripOk = $false
        $roundTripDetail.Add(('值被写坏：{0}' -f ($parsed.Errors -join '；')))
    } elseif ([string]$parsed.Values['UNIT_DB_PASS'] -ne $value) {
        $roundTripOk = $false
        $roundTripDetail.Add('往返后值不一致')
    }
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
Add-Result -Id 'T28' -Title '凭据值加引号/解析往返一致（单元）' -Expect '全部一致' -Actual $(if ($roundTripOk) { '通过' } else { '失败' }) `
    -Ok $roundTripOk -Detail (($roundTripDetail) -join '；')

# --- T29 未知键名被判定非法 ----------------------------------------------
$unknownKeyWork = New-TestWork -Name 'unknown-key' -CredentialsBody "DEV_LEBGJM_DB_HOST=10.10.80.211`r`nDEV_LEBGJM_DB_NAME=wms_lebg`r`n"
$r = Invoke-DbOps -Work $unknownKeyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
Add-Result -Id 'T29' -Title 'DB_NAME 不在允许键集合内 → invalid' -Expect 6 -Actual $r.ExitCode `
    -Ok ($r.ExitCode -eq 6 -and $r.Combined.Contains('DEV_LEBGJM_DB_NAME')) `
    -Detail (Get-EvidenceLine -Text $r.Combined -Pattern 'DEV_LEBGJM_DB_NAME')

# --- T30 只读查询不会创建日志目录 ----------------------------------------
$r = Invoke-DbOps -Work $readyWork -Arguments @('-Mode', 'Validate', '-Target', 'dev.lebgjm')
$noLogs = -not (Test-Path -LiteralPath (Join-Path $readyWork.Dir '_logs'))
$localLogDir = Join-Path $env:LOCALAPPDATA 'db-ops\logs'
Add-Result -Id 'T30' -Title 'Validate 不写日志、不建 _logs/' -Expect '无日志目录' -Actual $(if ($noLogs) { '无' } else { '有' }) `
    -Ok $noLogs -Detail ('工作根内无 _logs；真实日志目录 {0} 由本测试不触碰' -f $localLogDir)

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------

$passed = @($script:Results | Where-Object { $_.Ok }).Count
$failed = @($script:Results | Where-Object { -not $_.Ok }).Count

# 期望条数写死在这里。任何一条用例因为未捕获异常被跳过时，「PASS 45 / FAIL 0」
# 看上去仍然像一次全绿——只有和期望条数比对才能看出跑少了一条。
$expectedCases = 47
$aborted = ($script:Results.Count -ne $expectedCases)

Write-Host ''
Write-Host '=== 汇总 ==='
Write-Host ('用例总数 {0}：PASS {1} / FAIL {2}' -f $script:Results.Count, $passed, $failed)
if ($aborted) {
    Write-Host ('!! 用例条数不符：期望 {0}，实际 {1} —— 有用例被跳过或被中断，本次结果不完整。' -f $expectedCases, $script:Results.Count)
}

if ($failed -gt 0) {
    Write-Host ''
    Write-Host '失败用例：'
    foreach ($item in @($script:Results | Where-Object { -not $_.Ok })) {
        Write-Host ('  {0} {1}  期望={2} 实际={3}  {4}' -f $item.Id, $item.Title, $item.Expect, $item.Actual, $item.Detail)
    }
}

$report = [ordered]@{
    SkillRoot     = $SkillRoot
    WorkRoot      = $WorkRoot
    Timestamp     = (Get-Date).ToString('o')
    ExpectedCases = $expectedCases
    Total         = $script:Results.Count
    Passed        = $passed
    Failed        = $failed
    Aborted       = $aborted
    # 必须是 .ToArray()，**不能**写 @($script:Results)。
    # 实测（Windows PowerShell 5.1）：数组子表达式运算符 @() 作用在
    # System.Collections.Generic.List[object] 上会直接抛
    # ArgumentException「Argument types do not match」——List[string] / List[int] /
    # List[pscustomobject] / ArrayList 都没问题，只有元素类型恰好是 object 的泛型 List 中招。
    # 这正是「整条测试跑完汇总后无声退出、报告不写、临时目录不删」的元凶：
    # 报错点就在这一行，而它是 Test 的收尾代码，不是任何一条用例。
    Results       = $script:Results.ToArray()
}
# 报告与清理都**不得**影响用例结论：一段收尾代码抛出异常，会让一次全绿的运行
# 变成一个「跑完了但什么都没说清」的结果，甚至跳过临时目录清理。
try {
    [IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $report -Depth 8), $script:Utf8NoBom)
    Write-Host ('报告：{0}' -f $ReportPath)
} catch {
    Write-Host ('报告写入失败（不影响上面的用例结论）：{0}' -f $_.Exception.Message)
}

if (-not $KeepWork) {
    Write-Host ('清理临时目录：{0}' -f $WorkRoot)
    Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:TEMP 'db-ops-token-test') -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0 -or $aborted) { exit 1 }
exit 0
