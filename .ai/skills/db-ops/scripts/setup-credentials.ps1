<#
.SYNOPSIS
    建立或重建 db-ops 的外置凭据文件。

.DESCRIPTION
    这是**唯一**允许写凭据文件的脚本。它只做一件事：向用户要 4 个值 × N 个前缀，
    收紧权限，然后原子落到 policy.credentialsPath。

    它不做的三件事，都是刻意的：
      - 不从旧 dbsql/.env 迁移、不读取旧凭据、不提供搬运脚本。
        迁移 = 把生产凭据重新归属到另一条路由，必须由人明确决定。
      - 不验证连通性。写好文件不等于账号能用；真实连接属于阶段 2。
      - 不提供高权限账号的绕过开关。命中 highPrivilegeUserPattern 一律拒绝写入。

    退出码
      0 成功；或文件已存在且未指定 -Force（此时原样保留，不做任何修改）
      1 硬失败（配置非法）
      2 需要确认（-Force 未同时给 -ConfirmReset）
      5 没有收集到任何凭据（文件未改动）
      6 输入非法（权限收紧失败、回读校验失败）
      7 无法交互（当前进程不能提问）

    执行顺序上的一个刻意调整
      「文件已存在且未指定 -Force」的检查**排在**交互性检查之前。
      理由：那条路径既不提问也不写文件；排在后面会让一个在非交互环境里运行、
      但其实无事可做的调用得到「需要终端」这个误导性结论。
      真正的写操作全部发生在交互性检查与 -ConfirmReset 检查之后。

.NOTES
    本文件必须保存为 UTF-8 with BOM（Windows PowerShell 5.1 会按 ANSI 读取无 BOM 的 .ps1，
    中文提示会变成乱码）。
    所有 exit 都在顶层 try/catch 之外，理由同 db-ops.ps1。
#>
param(
    # 覆盖已存在的凭据文件。**整份重置**，不是合并。
    [switch]$Force,

    # -Force 的第二步确认。少了它退出码是 2，不是 5——「等你点头」与「你还没配」不是一回事。
    [switch]$ConfirmReset,

    # 只收集指定前缀（routes.json 里的 credentialPrefix 值）。不传则逐个前缀交互。
    [string[]]$Only,

    # 显式声明当前不可交互。与 [Console]::IsInputRedirected 二者任一成立即拒绝提问。
    [switch]$NonInteractive,

    # 仅供测试：覆盖技能根目录。
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 见 db-ops.ps1：编码设置失败不该让脚本停摆。
}

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\config.ps1')
. (Join-Path $PSScriptRoot 'lib\credentials.ps1')
. (Join-Path $PSScriptRoot 'lib\output.ps1')

$EXIT_OK = 0
$EXIT_HARD_FAILURE = 1
$EXIT_NEEDS_CONFIRMATION = 2
$EXIT_NOT_READY = 5
$EXIT_INVALID_INPUT = 6
$EXIT_CANNOT_PROMPT = 7

function Write-SetupError {
    param([string]$Message)
    [Console]::Error.WriteLine(('ERROR: {0}' -f $Message))
}

function Get-CredentialsFileHeader {
    # 文件头写给人看。写进来的每一句都必须是真的——一段过度承诺的注释会让后来者
    # 以为这份文件是加密的。
    return @(
        '# db-ops 凭据文件',
        '#',
        '# 由 scripts/setup-credentials.ps1 生成，请勿手工编辑（手工编辑请同时保证只含',
        '# PREFIX_DB_HOST / PREFIX_DB_PORT / PREFIX_DB_USER / PREFIX_DB_PASS 四类键）。',
        '#',
        '# 存储形态：明文键值。口令在落盘时是明文，文件的唯一保护是 NTFS 权限',
        '# （仅当前用户可访问）。不要把它放进 Git、网盘同步目录或备份。',
        '#',
        '# 文件位置由 config/policy.json 的 credentialsPath 决定，不在这里写死。',
        '#',
        '# 本文件只声明「怎么连」。库名不在这里——库名是 config/routes.json 的事实，',
        '# 不允许被凭据文件覆盖（那正是「看起来查 A 库、实际连 B 库」的成因）。',
        '#',
        '# 阶段 1 不验证连通性：文件写好不等于账号能连上库、更不等于账号只有只读权限。'
    ) -join "`r`n"
}

function Get-PrefixesFromKeys {
    param($Keys)
    $prefixes = @()
    foreach ($key in @($Keys)) {
        $separator = ([string]$key).LastIndexOf('_DB_')
        if ($separator -gt 0) { $prefixes += ([string]$key).Substring(0, $separator + 1) }
    }
    # 前置逗号不是笔误：函数 return 一个单元素数组时，管道会把它解包成裸字符串，
    # 于是调用方的 `.Count` 在 Set-StrictMode 2.0 下抛「找不到 Count 属性」。
    # 实测踩到：文件里只配了 1 个前缀时（最常见的形态）第 150 行直接崩。
    # 用 `,` 把数组再包一层，出栈的仍然是一个数组，0 个前缀时也稳定是空数组而不是 $null。
    return , @($prefixes | Select-Object -Unique | Sort-Object)
}

function Invoke-SetupCredentials {
    param(
        [string]$Root,
        [switch]$Force,
        [switch]$ConfirmReset,
        [string[]]$Only,
        [switch]$NonInteractive
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $stderrLines = New-Object System.Collections.Generic.List[string]
    $code = $EXIT_HARD_FAILURE
    $collected = $null
    # $collectedInfo 必须在这里就有初值：finally 会读它，而步骤 1–4 的提前返回
    # 都发生在赋值之前。Set-StrictMode 2.0 下「未赋值就读」是错误，不是 $null。
    $collectedInfo = $null
    $tempPath = $null

    try {
        $skillRoot = Get-DbOpsRoot -Hint $Root
        $policy = Get-DbOpsPolicy -Root $skillRoot
        $routes = Get-DbOpsRoutes -Root $skillRoot
        $credentialsPath = Resolve-CredentialsPath -Policy $policy
        $allowedKeyPattern = [string](Get-OptionalProperty -Object $policy.credentials -Name 'allowedKeyPattern' -Default '')

        $lines.Add('db-ops 凭据文件设置')
        $lines.Add(('目标文件：{0}' -f $credentialsPath))
        $lines.Add('')

        # --- 1) 已存在且未指定 -Force：报告后原样返回 -------------------------
        # 不覆盖、不合并、不重置。旧文件里可能有本次不打算重新输入的前缀，
        # 「顺手重建」会把它们静默丢掉。
        $fileExists = Test-Path -LiteralPath $credentialsPath -PathType Leaf
        if ($fileExists -and -not $Force) {
            $state = Get-CredentialsFileState -Path $credentialsPath -Policy $policy
            $lines.Add(('文件状态：{0}' -f $state.State))
            if ($state.State -eq 'present' -or $state.State -eq 'permission-warning') {
                $presentPrefixes = Get-PrefixesFromKeys -Keys $state.Values.Keys
                $prefixText = '（无）'
                if ($presentPrefixes.Count -gt 0) { $prefixText = $presentPrefixes -join '、' }
                $lines.Add(('已配置前缀：{0}' -f $prefixText))
            } else {
                $lines.Add(('原因：{0}' -f $state.Reason))
            }
            $lines.Add('')
            $lines.Add('未指定 -Force，因此**没有修改任何内容**。')
            $lines.Add('要重建整份文件（会丢弃上面未重新输入的前缀），请显式运行：')
            $lines.Add('  setup-credentials.ps1 -Force -ConfirmReset')
            return [pscustomobject]@{ Code = $EXIT_OK; Lines = $lines.ToArray(); StderrLines = @() }
        }

        # --- 2) 交互性检查：必须在任何写操作之前 ------------------------------
        # 唯一可靠判据是 [Console]::IsInputRedirected；$Host.Name 在 agent 派生进程里
        # 仍然是 ConsoleHost，用它判断会得出「可以交互」，然后 Read-Host 读到 EOF 或挂死。
        if ($NonInteractive -or -not (Test-CanPrompt)) {
            $stderrLines.Add('当前进程无法交互式提问（stdin 被重定向，或显式指定了 -NonInteractive）。')
            $stderrLines.Add('凭据文件需要在真实终端里手工建立：本脚本不会在无人值守的环境里猜测口令，')
            $stderrLines.Add('也不会把口令写进任何命令行参数或环境变量。')
            $stderrLines.Add('请在交互式终端中运行本脚本（Claude Code 会话里可用 `! ` 前缀直接执行）。')
            $stderrLines.Add(('未改动任何文件。目标路径：{0}' -f $credentialsPath))
            return [pscustomobject]@{ Code = $EXIT_CANNOT_PROMPT; Lines = @(); StderrLines = $stderrLines.ToArray() }
        }

        # --- 3) -Force 的第二步确认 -------------------------------------------
        if ($Force -and -not $ConfirmReset) {
            $stderrLines.Add('指定了 -Force 但没有 -ConfirmReset。')
            $stderrLines.Add(('这会**整份重置** {0}：文件中现有的所有前缀都会被替换，' -f $credentialsPath))
            $stderrLines.Add('本次没有重新输入的前缀将不复存在（不是合并）。确认请在命令里补上 -ConfirmReset。')
            $stderrLines.Add('未改动任何文件。')
            return [pscustomobject]@{ Code = $EXIT_NEEDS_CONFIRMATION; Lines = @(); StderrLines = $stderrLines.ToArray() }
        }

        # --- 4) -Only 预校验 --------------------------------------------------
        $knownPrefixes = @(@($routes.routes) | ForEach-Object { [string]$_.credentialPrefix } | Select-Object -Unique | Sort-Object)
        $onlyList = @($Only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($onlyList.Count -gt 0) {
            $unknown = @($onlyList | Where-Object { $knownPrefixes -notcontains $_ })
            if ($unknown.Count -gt 0) {
                $message = '未知的凭据前缀：{0}。routes.json 中声明的前缀：{1}'
                $message = $message -f ($unknown -join '、'), ($knownPrefixes -join '、')
                $stderrLines.Add($message)
                $stderrLines.Add('未改动任何文件。')
                return [pscustomobject]@{ Code = $EXIT_INVALID_INPUT; Lines = @(); StderrLines = $stderrLines.ToArray() }
            }
        }

        # 重置前先记下「这次会丢什么」。只记前缀名，不记值。
        $existingPrefixes = @()
        if ($fileExists) {
            $existingState = Get-CredentialsFileState -Path $credentialsPath -Policy $policy
            if ($existingState.State -eq 'present' -or $existingState.State -eq 'permission-warning') {
                $existingPrefixes = Get-PrefixesFromKeys -Keys $existingState.Values.Keys
            }
            $lines.Add('注意：本次是**重置**。以下前缀若不在本次输入范围内，将被丢弃：')
            $prefixText = '（现有文件里没有可解析的前缀）'
            if ($existingPrefixes.Count -gt 0) { $prefixText = $existingPrefixes -join '、' }
            $lines.Add(('  现有前缀：{0}' -f $prefixText))
            $lines.Add('')
        }
        $lines.Add('逐前缀输入。任一项留空表示跳过该前缀；跳过的路由会保持 unconfigured。')
        $lines.Add('口令输入不回显，且不会进入命令行参数、历史记录或本技能的输出。')
        $lines.Add('')

        # 交互过程直接写宿主（Read-Host 需要真实的提问顺序），因此这里的 $lines 只是
        # 事前说明；prompt 本身由 New-CredentialsFileInteractive 负责。
        foreach ($line in $lines) { Write-Host $line }
        $lines.Clear()

        $collectedInfo = New-CredentialsFileInteractive -Routes $routes -Policy $policy -Only $onlyList
        $collected = $collectedInfo.Table

        if ($collectedInfo.Rejected.Count -gt 0) {
            foreach ($rejected in $collectedInfo.Rejected) { $stderrLines.Add(('已拒绝：{0}' -f $rejected)) }
        }

        if ($null -eq $collected -or $collected.Count -eq 0) {
            $stderrLines.Add('没有收集到任何可写入的凭据。文件未改动。')
            if ($collectedInfo.Skipped.Count -gt 0) {
                $stderrLines.Add(('被跳过的前缀：{0}' -f ($collectedInfo.Skipped -join '、')))
            }
            return [pscustomobject]@{ Code = $EXIT_NOT_READY; Lines = @(); StderrLines = $stderrLines.ToArray() }
        }

        # --- 5) 写入：临时文件 → 收紧权限 → 复验 → 原子替换 → 再次复验 ---------
        # 顺序不能省：临时文件在替换之前就已经只有当前用户可读，因此即使替换那一刻
        # 崩溃，也不存在一个「内容齐全但人尽可读」的窗口。
        $full = [IO.Path]::GetFullPath($credentialsPath)
        $parent = Split-Path -Parent $full
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        $tempPath = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($full), [guid]::NewGuid().ToString('N').Substring(0, 8))

        $content = New-CredentialsFileContent -CredentialTable $collected -Header (Get-CredentialsFileHeader)
        Write-Utf8Atomic -Path $tempPath -Content $content

        try {
            Set-CredentialsFileAcl -Path $tempPath
            $tempAcl = Assert-CredentialsFileAcl -Path $tempPath -Context '步骤 5（临时文件权限收紧）'
        } catch {
            # 明确报「第几步失败」，并且绝不声称已保护。
            $stderrLines.Add(('步骤 5（临时文件权限收紧）失败：{0}' -f $_.Exception.Message))
            $stderrLines.Add('凭据未写入。临时文件会被删除，目标文件保持原样。')
            return [pscustomobject]@{ Code = $EXIT_INVALID_INPUT; Lines = @(); StderrLines = $stderrLines.ToArray() }
        }

        if (Test-Path -LiteralPath $full) {
            # 目标存在时必须用 File.Replace（原子的替换）；Move 在目标已存在时会失败。
            [IO.File]::Replace($tempPath, $full, $null)
        } else {
            [IO.File]::Move($tempPath, $full)
        }
        $tempPath = $null

        # 替换之后必须对**最终路径**再收紧并复验：Replace 对 ACL 的处置不是本脚本能假定的，
        # 而且这是唯一能证明「现在这个文件确实只对当前用户开放」的检查。
        try {
            Set-CredentialsFileAcl -Path $full
            $finalAcl = Assert-CredentialsFileAcl -Path $full -Context '步骤 6（最终文件权限复验）'
        } catch {
            $stderrLines.Add(('步骤 6（最终文件权限复验）失败：{0}' -f $_.Exception.Message))
            $stderrLines.Add(('文件已写入 {0}，但**权限状态未经验证**。请立即手工检查该文件的 ACL，' -f $full))
            $stderrLines.Add('或删除它并重试。本脚本不会在这种情况下报告成功。')
            return [pscustomobject]@{ Code = $EXIT_INVALID_INPUT; Lines = @(); StderrLines = $stderrLines.ToArray() }
        }

        # --- 6) 回读校验：证明「写进去什么，读出来就是什么」 -------------------
        # 这一步同时验证了写入端加引号与解析端剥引号这对实现是对称的——它们是两个
        # 独立函数，任何一侧改动都可能让带 # / = / 引号的口令静默损坏。
        $readBack = Read-CredentialsEnv -Path $full -AllowedKeyPattern $allowedKeyPattern
        $mismatch = @()
        if ($readBack.Errors.Count -gt 0) {
            $mismatch += @($readBack.Errors)
        } else {
            foreach ($key in @($collected.Keys)) {
                if (-not $readBack.Values.ContainsKey($key)) { $mismatch += ('缺键：{0}' -f $key); continue }
                if ([string]$readBack.Values[$key] -ne [string]$collected[$key]) { $mismatch += ('值不一致：{0}' -f $key) }
            }
        }
        if ($mismatch.Count -gt 0) {
            $stderrLines.Add(('步骤 7（回读校验）失败：{0}' -f ($mismatch -join '；')))
            $stderrLines.Add('值不予回显。文件已写入但内容不可信，请删除后重试。')
            return [pscustomobject]@{ Code = $EXIT_INVALID_INPUT; Lines = @(); StderrLines = $stderrLines.ToArray() }
        }

        # --- 7) 报告：只有路径、权限摘要、前缀名，没有任何值 --------------------
        $writtenPrefixes = Get-PrefixesFromKeys -Keys $collected.Keys
        $dropped = @($existingPrefixes | Where-Object { $writtenPrefixes -notcontains $_ })

        $lines.Add('已写入凭据文件。')
        $lines.Add(('  路径        ：{0}' -f $full))
        $lines.Add(('  写入前缀    ：{0}' -f ($writtenPrefixes -join '、')))
        $lines.Add(('  键数量      ：{0}（每前缀 4 个）' -f $collected.Count))
        $lines.Add(('  继承已断开  ：{0}' -f $finalAcl.Protected))
        $lines.Add('  访问规则    ：')
        foreach ($ace in @($finalAcl.Ace)) { $lines.Add(('    {0}' -f $ace)) }
        $lines.Add(('  临时文件权限：{0}' -f $tempAcl.Reason))
        if ($dropped.Count -gt 0) {
            $lines.Add(('  被丢弃的前缀：{0}' -f ($dropped -join '、')))
        }
        if ($collectedInfo.Skipped.Count -gt 0) {
            $lines.Add(('  被跳过的前缀：{0}（对应路由保持 unconfigured）' -f ($collectedInfo.Skipped -join '、')))
        }
        $lines.Add('')
        $lines.Add('未验证连通性：本阶段不连接任何数据库。要确认账号可用，需要阶段 2 的执行器。')
        $lines.Add('下一步：运行 `db-ops.ps1 -Mode Validate -Target <路由 id>` 查看各路由状态。')

        return [pscustomobject]@{ Code = $EXIT_OK; Lines = $lines.ToArray(); StderrLines = $stderrLines.ToArray() }
    } finally {
        # SecureString 与明文都只是「尽早放弃引用」：.NET 字符串不可变，无法真正擦除。
        # 这里不假装已经安全，只保证本脚本不再持有它们，并清掉可能残留的临时文件。
        $collected = $null
        $collectedInfo = $null
        if (-not [string]::IsNullOrWhiteSpace($tempPath) -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 顶层：打印 + 退出码
# ---------------------------------------------------------------------------

$exitCode = $EXIT_HARD_FAILURE
$result = $null

try {
    $result = Invoke-SetupCredentials -Root $Root -Force:$Force -ConfirmReset:$ConfirmReset -Only $Only -NonInteractive:$NonInteractive
    $exitCode = [int]$result.Code
} catch {
    Write-SetupError ('{0}' -f $_.Exception.Message)
    Write-SetupError (Get-DbOpsErrorLocation -ErrorRecord $_ -FallbackScriptName 'setup-credentials.ps1')
    exit $EXIT_HARD_FAILURE
}

foreach ($line in @($result.StderrLines)) { Write-SetupError $line }
foreach ($line in @($result.Lines)) { Write-Host $line }

exit $exitCode
