# lib/credentials.ps1 —— 外置凭据文件的定位、解析、状态判定、ACL 收紧与 SecureString 输入。
#
# 职责边界
#   文件级：missing / invalid / permission-warning / present 四态判定；
#   路由级：把某个凭据前缀折算成 {Present, Config, MissingKeys, HighPrivilege, HostMismatch, PortMismatch}。
#
# 明确不做
#   不决定凭据文件放在哪里（那是 config.ps1 的 Resolve-CredentialsPath）；
#   不打印任何凭据**值**；不连数据库；不读 routes.json。
#
# 依赖：common.ps1 必须先 dot-source。
#
# 本文件最要紧的一条纪律
#   任何错误、告警、异常消息里都只能出现**键名**和**行号**，绝不出现值。
#   一旦把值塞进异常消息，它会顺着 stderr 进到会话记录里——这正是本轮要在结构上
#   杜绝的事情，而不是靠调用方记得别打印。

# 值里出现这些字符就必须加引号落盘：'#' 在行首是注释；'=' 会让按第一个 '=' 切分的
# 解析歧义；首尾空格会被 Trim 吃掉；引号会破坏成对剥除。宁可贵一点也要保证
# 「写进去什么，读出来就是什么」。
$script:DbOpsCredentialValuePattern = '^[^\s#=''""][^\r\n]*$'

function Test-CredentialValueNeedsQuote {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $true }
    if ($Value -notmatch $script:DbOpsCredentialValuePattern) { return $true }
    # 结尾空格同样会被 Trim 吃掉，必须加引号。
    if ($Value -ne $Value.TrimEnd()) { return $true }
    return $false
}

function Format-CredentialValue {
    # 写入端的唯一实现。'=' 与 '#' 在**值内部**出现时并不可怕，可怕的是它们出现在
    # 不该出现的位置；统一加引号后由解析端成对剥除，结构上就不会再出现
    # 旧 .env.tmp 那种「一行被切成两半、后半截变成裸行」的损坏。
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -match '[\r\n]') { throw '凭据值不能包含换行：换行会把一行切成两行，解析时必然产生伪键。' }
    if (-not (Test-CredentialValueNeedsQuote -Value $Value)) { return $Value }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return ('"{0}"' -f $escaped)
}

function ConvertFrom-CredentialValue {
    # 解析端：只有**两端是同一个引号字符且长度 ≥ 2** 时才剥除，
    # 因此 'a"b' 这种中间带引号的裸值不会被动过。
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -lt 2) { return $Value }
    $first = $Value.Substring(0, 1)
    $last = $Value.Substring($Value.Length - 1, 1)
    if ($first -ne $last) { return $Value }
    if ($first -ne '"' -and $first -ne "'") { return $Value }
    $inner = $Value.Substring(1, $Value.Length - 2)
    if ($first -eq "'") { return $inner }
    # 双引号形式按写入端约定反转义：先反转义 \\ 再反转义 \"。
    # 用 [char]0 当中间占位符：Windows PowerShell 5.1 不支持 "`u{0000}" 这种转义写法，
    # 而占位符必须是值里不可能出现的字符——NUL 正好满足。
    $sentinel = [string][char]0
    $inner = $inner.Replace('\\', $sentinel)
    $inner = $inner.Replace('\"', '"')
    $inner = $inner.Replace($sentinel, '\')
    return $inner
}

# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------

function Read-CredentialsEnv {
    # 按行解析键值。规则（与写入端严格对称）：
    #   1) 只看**行首**（允许前导空白）的 '#' 作为注释；值内部的 '#' 是普通字符；
    #   2) 按**第一个** '=' 切分，值里可以再出现 '='；
    #   3) 键名必须匹配 allowedKeyPattern，否则是伪键（旧 .env.tmp 的坏行正是这一类）；
    #   4) 不允许重复键。
    #
    # 返回对象而不是抛异常：结构损坏是一种**结果**，要能连同行号一起报给用户，
    # 而不是把整次运行崩掉。返回对象的 Errors 里只有行号与键名，没有值。
    param(
        [string]$Path,
        [string]$AllowedKeyPattern
    )

    $result = [pscustomobject]@{
        Values    = @{}
        Errors    = @()
        LineCount = 0
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Errors += '凭据文件不存在。'
        return $result
    }

    $text = $null
    try {
        $text = [IO.File]::ReadAllText($Path)
    } catch {
        $result.Errors += ('凭据文件无法读取：{0}' -f $_.Exception.Message)
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        $result.Errors += '凭据文件为空。'
        return $result
    }

    $lines = @($text -split "\r?\n")
    $result.LineCount = $lines.Count

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $line = $lines[$index]
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0) { continue }
        if ($trimmed.StartsWith('#')) { continue }

        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            # 不把该行内容回显出来：坏行里可能带明文口令（旧 .env.tmp 就有）。
            $result.Errors += ('第 {0} 行不是 key=value 形式（该行内容不予回显）。' -f $lineNumber)
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        $rawValue = $line.Substring($separator + 1).Trim()

        if ($key.Length -eq 0) {
            $result.Errors += ('第 {0} 行缺少键名。' -f $lineNumber)
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($AllowedKeyPattern) -and $key -notmatch $AllowedKeyPattern) {
            $result.Errors += ("第 {0} 行键名不符合允许模式：'{1}'（值不予回显）。" -f $lineNumber, $key)
            continue
        }
        if ($result.Values.ContainsKey($key)) {
            $result.Errors += ("第 {0} 行键名重复：'{1}'。" -f $lineNumber, $key)
            continue
        }

        $value = ConvertFrom-CredentialValue -Value $rawValue
        if ([string]::IsNullOrEmpty($value)) {
            $result.Errors += ("第 {0} 行 '{1}' 的值为空。" -f $lineNumber, $key)
            continue
        }

        $result.Values[$key] = $value
    }

    if ($result.Values.Count -eq 0 -and $result.Errors.Count -eq 0) {
        $result.Errors += '凭据文件里没有一个有效键。'
    }

    return $result
}

# ---------------------------------------------------------------------------
# ACL
# ---------------------------------------------------------------------------

function Get-CurrentUserIdentity {
    return ([System.Security.Principal.WindowsIdentity]::GetCurrent()).Name
}

function Test-CredentialsFileAcl {
    # 返回 {Ok, Reason, Ace, Protected}。
    #
    # 判据是「所有 Allow 规则的身份都等于当前用户」，**不要求** AreAccessRulesProtected 为真。
    # 理由：%LOCALAPPDATA% 本身通常已经是仅当前用户可访问，从那里继承来的规则虽然
    # IsInherited=true，但并不构成额外暴露；把它判成失败会产生大量假警报，
    # 而假警报会训练人忽略这个检查。
    # AreAccessRulesProtected 只作为诊断信息一并返回，并记录在 setup 的摘要里。
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = '凭据文件不存在，无法检查权限。'; Ace = @(); Protected = $false }
    }

    try {
        $acl = Get-Acl -LiteralPath $Path
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = ('读取 ACL 失败：{0}' -f $_.Exception.Message); Ace = @(); Protected = $false }
    }

    $current = Get-CurrentUserIdentity
    $allowRules = @($acl.Access | Where-Object { $_.AccessControlType -eq 'Allow' })
    $summaries = @()
    $foreign = @()

    foreach ($rule in $allowRules) {
        $identity = [string]$rule.IdentityReference
        $inherited = if ($rule.IsInherited) { '(继承)' } else { '(显式)' }
        $summaries += ('{0} {1} {2}' -f $identity, $rule.FileSystemRights, $inherited)
        if ($identity -ne $current) { $foreign += $identity }
    }

    if ($allowRules.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = '凭据文件没有任何 Allow 访问规则，权限状态不明。'; Ace = @(); Protected = [bool]$acl.AreAccessRulesProtected }
    }

    if ($foreign.Count -gt 0) {
        $unique = @($foreign | Select-Object -Unique)
        return [pscustomobject]@{
            Ok        = $false
            Reason    = ('凭据文件对当前用户以外的主体可访问：{0}。当前用户：{1}。' -f ($unique -join '、'), $current)
            Ace       = $summaries
            Protected = [bool]$acl.AreAccessRulesProtected
        }
    }

    return [pscustomobject]@{
        Ok        = $true
        Reason    = ('仅当前用户 {0} 可访问。' -f $current)
        Ace       = $summaries
        Protected = [bool]$acl.AreAccessRulesProtected
    }
}

function Set-CredentialsFileAcl {
    # 断继承 + 只留一条「当前用户 FullControl」。
    #
    # **失败必须抛异常，绝不静默。** 一个「设不上权限但报告成功」的凭据文件，
    # 比一个明确失败的更危险：使用者会以为它已经受保护。
    #
    # 不用 Set-Acl，改自己构造一个**只含 DACL** 的 FileSecurity 交给
    # [IO.File]::SetAccessControl。原因是离线测试实测到的两个叠加缺陷：
    #
    #   1) PowerShell 的 Set-Acl 会把描述符里的 SACL 一并写回，而写 SACL 需要
    #      SeSecurityPrivilege（非提升进程没有这个特权）。于是**对一个已经收紧过的
    #      文件再次收紧必定失败**：Get-Acl 读回的 DACL 带 SE_DACL_PROTECTED，
    #      Set-Acl 随即抛 PrivilegeNotHeldException。setup-credentials.ps1 的步骤 6
    #      恰好就是「对刚写入的最终文件再收紧一次」，因此重复运行必然停在步骤 6——
    #      一个看起来只是「权限再确认」的步骤，实际会让整条凭据初始化路径不可重复执行。
    #   2) PrivilegeNotHeld 是**非终止**错误：Set-Acl 在调用方
    #      $ErrorActionPreference='Continue' 时只写一条错误流就返回，try/catch 抓不到，
    #      本函数会返回「成功」——一个声称已保护、实际没保护的文件。
    #
    # .NET 只写描述符里实际存在的段：新建的 FileSecurity 没有所有者/组/审计段，
    # 落地时就只改 DACL。既不需要特权，失败也一定是终止性异常，两个问题一起消失。
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "设置 ACL 失败：文件不存在：$Path" }

    $current = Get-CurrentUserIdentity
    # 必须自己绝对化：.NET 的相对路径按**进程**当前目录解析，而 PowerShell 的
    # -LiteralPath 按 PS 当前位置解析，两者在写入位置被改过时不是一回事。
    $full = [IO.Path]::GetFullPath($Path)
    try {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        # $true = 置 SE_DACL_PROTECTED（断继承），$false = 不保留继承来的规则。
        $acl.SetAccessRuleProtection($true, $false)
        $newRule = New-Object System.Security.AccessControl.FileSystemAccessRule($current, 'FullControl', 'Allow')
        $acl.AddAccessRule($newRule)
        [System.IO.File]::SetAccessControl($full, $acl)
    } catch {
        throw ('设置凭据文件 ACL 失败：{0}' -f $_.Exception.Message)
    }
}

function Assert-CredentialsFileAcl {
    # 设置之后必须**复验**：写入调用返回成功不等于目标 ACL 真的变了
    # （只读文件系统、被策略托管的目录、被组策略改写等都可能让它静默无效）。
    # 这条检查在改用 [IO.File]::SetAccessControl 之后**同样保留**——它验的是结果，
    # 不是某次调用的返回值，因此是唯一能证明「现在这个文件确实只对当前用户开放」的东西。
    param([string]$Path, [string]$Context)

    $check = Test-CredentialsFileAcl -Path $Path
    if (-not $check.Ok) {
        throw ('{0}：ACL 复验未通过 —— {1}' -f $Context, $check.Reason)
    }
    return $check
}

# ---------------------------------------------------------------------------
# 文件级状态
# ---------------------------------------------------------------------------

function Get-CredentialsFileState {
    # 严格按序短路：先结构、后权限。
    #
    # 顺序不能反：文件坏了（半行、伪键、乱码）的时候，「权限行不行」根本不是当前的
    # 问题，先报权限会把人引向错误的修复方向。invalid 必须先于 permission-warning 出现。
    param(
        [string]$Path,
        $Policy
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ State = 'invalid'; Reason = '凭据路径为空。'; Values = @{}; Errors = @('凭据路径为空。'); LineCount = 0 }
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return [pscustomobject]@{ State = 'invalid'; Reason = '凭据路径是一个目录，不是文件。'; Values = @{}; Errors = @('凭据路径是一个目录。'); LineCount = 0 }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'missing'; Reason = '凭据文件不存在。'; Values = @{}; Errors = @(); LineCount = 0 }
    }

    $allowedKeyPattern = ''
    if ($null -ne $Policy) {
        $credentials = Get-OptionalProperty -Object $Policy -Name 'credentials' -Default $null
        if ($null -ne $credentials) {
            $allowedKeyPattern = [string](Get-OptionalProperty -Object $credentials -Name 'allowedKeyPattern' -Default '')
        }
    }

    $parsed = Read-CredentialsEnv -Path $Path -AllowedKeyPattern $allowedKeyPattern
    if ($parsed.Errors.Count -gt 0) {
        return [pscustomobject]@{
            State     = 'invalid'
            Reason    = ('凭据文件结构非法：{0}' -f ($parsed.Errors -join '；'))
            Values    = @{}
            Errors    = $parsed.Errors
            LineCount = $parsed.LineCount
        }
    }

    $requireUserOnlyAcl = $true
    if ($null -ne $Policy) {
        $credentials = Get-OptionalProperty -Object $Policy -Name 'credentials' -Default $null
        if ($null -ne $credentials) {
            $requireUserOnlyAcl = [bool](Get-OptionalProperty -Object $credentials -Name 'requireUserOnlyAcl' -Default $true)
        }
    }

    if ($requireUserOnlyAcl) {
        $acl = Test-CredentialsFileAcl -Path $Path
        if (-not $acl.Ok) {
            return [pscustomobject]@{
                State     = 'permission-warning'
                Reason    = $acl.Reason
                Values    = $parsed.Values
                Errors    = @()
                LineCount = $parsed.LineCount
                Acl       = $acl
            }
        }
        return [pscustomobject]@{
            State     = 'present'
            Reason    = $acl.Reason
            Values    = $parsed.Values
            Errors    = @()
            LineCount = $parsed.LineCount
            Acl       = $acl
        }
    }

    return [pscustomobject]@{ State = 'present'; Reason = '已跳过 ACL 检查（policy.credentials.requireUserOnlyAcl=false）。'; Values = $parsed.Values; Errors = @(); LineCount = $parsed.LineCount }
}

# ---------------------------------------------------------------------------
# 路由级凭据
# ---------------------------------------------------------------------------

function Get-RouteCredential {
    # 把一个凭据前缀折算成路由级的凭据状态。
    #
    # HostMismatch / PortMismatch 在这里算而不是在状态机里算，原因很实际：
    # 只有这里同时握着「凭据里的值」和「routes.json 里的声明」。
    # 声明与配置不一致时一律 blocked —— 静默按其中一边连过去，正是库选错的成因。
    param(
        $Route,
        $Values,
        $Policy
    )

    $prefix = [string]$Route.credentialPrefix
    $suffixes = @('DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASS')

    $result = [pscustomobject]@{
        Present       = $false
        Config        = $null
        MissingKeys   = @()
        HighPrivilege = $false
        Host          = $null
        Port          = $null
        HostMismatch  = $false
        PortMismatch  = $false
    }

    if ($null -eq $Values -or $Values.Count -eq 0) { return $result }

    $config = @{}
    $missing = @()
    foreach ($suffix in $suffixes) {
        $key = $prefix + $suffix
        if (-not $Values.ContainsKey($key) -or [string]::IsNullOrEmpty([string]$Values[$key])) {
            $missing += $key
        } else {
            $config[$suffix] = [string]$Values[$key]
        }
    }

    if ($missing.Count -eq $suffixes.Count) {
        # 一个键都没有：这条路由压根没被配置过，不是「配置不全」。
        return $result
    }

    $result.Present = $true
    $result.Config = $config
    $result.MissingKeys = @($missing)

    if ($missing.Count -gt 0) { return $result }

    $result.Host = [string]$config['DB_HOST']
    $result.Port = [string]$config['DB_PORT']

    $highPrivilegePattern = ''
    if ($null -ne $Policy) {
        $credentials = Get-OptionalProperty -Object $Policy -Name 'credentials' -Default $null
        if ($null -ne $credentials) {
            $highPrivilegePattern = [string](Get-OptionalProperty -Object $credentials -Name 'highPrivilegeUserPattern' -Default '')
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($highPrivilegePattern) -and [string]$config['DB_USER'] -match $highPrivilegePattern) {
        $result.HighPrivilege = $true
    }

    $declaredHost = Get-OptionalProperty -Object $Route -Name 'host' -Default $null
    if ($null -ne $declaredHost -and ([string]$declaredHost) -ne $result.Host) { $result.HostMismatch = $true }

    $declaredPort = Get-OptionalProperty -Object $Route -Name 'port' -Default $null
    if ($null -ne $declaredPort) {
        $declaredPortText = [string]$declaredPort
        if ($declaredPortText -ne $result.Port) { $result.PortMismatch = $true }
    }

    return $result
}

# ---------------------------------------------------------------------------
# SecureString
# ---------------------------------------------------------------------------

function ConvertTo-PlainText {
    # SecureString 只保护**输入回显**，不提供落盘加密：转成普通字符串的那一刻它就和
    # 任何字符串一样了。这里做的是把 BSTR 及时释放，仅此而已。
    param([System.Security.SecureString]$Secure)

    if ($null -eq $Secure) { return '' }
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
}

function Clear-SecurePlainText {
    # 老实说：.NET 字符串不可变，**无法真正擦除**内存里的明文。
    # 这个函数能做的只是让调用方在 finally 里有地方写一句 $var = Clear-SecurePlainText $var，
    # 从而明确放弃最后一个引用。不要把它当成「已经安全了」的依据。
    param([string]$Text)
    return $null
}

# ---------------------------------------------------------------------------
# 交互式建立凭据文件
# ---------------------------------------------------------------------------

function Read-CredentialsSecretValue {
    # 密码一律走 Read-Host -AsSecureString：它不是强保护，但它保证口令不会出现在
    # 终端回显、命令历史和任何被记录的输出里。
    param([string]$Prompt)
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    try {
        return (ConvertTo-PlainText -Secure $secure)
    } finally {
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function New-CredentialsFileContent {
    # 由凭据表生成文件内容。**这是写入端唯一的实现**，setup-credentials.ps1 不得自己拼字符串。
    param($CredentialTable, [string]$Header)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($Header -split "\r?\n")) { $lines.Add($line) }

    $keys = @($CredentialTable.Keys | Sort-Object)
    foreach ($key in $keys) {
        $lines.Add(('{0}={1}' -f $key, (Format-CredentialValue -Value ([string]$CredentialTable[$key]))))
    }
    return (($lines -join "`r`n") + "`r`n")
}

function New-CredentialsFileInteractive {
    # 逐路由前缀收集凭据。返回结构与失败项，**不写文件**——落盘由 setup-credentials.ps1
    # 负责（它要先在临时文件上收紧 ACL，通过复验后才原子替换）。
    #
    # 逐前缀中途跳过是允许的：完全配置不了的据点不该阻塞其余据点。被跳过的前缀会
    # 出现在 Skipped 里，对应的路由继续保持 unconfigured。
    param(
        $Routes,
        $Policy,
        [string[]]$Only
    )

    $suffixes = @('DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASS')
    $highPrivilegePattern = [string](Get-OptionalProperty -Object $Policy.credentials -Name 'highPrivilegeUserPattern' -Default '')
    $onlyList = @($Only | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $prefixes = @(@($Routes.routes) | ForEach-Object { [string]$_.credentialPrefix } | Select-Object -Unique | Sort-Object)
    if ($onlyList.Count -gt 0) {
        $prefixes = @($prefixes | Where-Object { $onlyList -contains $_ })
        if ($prefixes.Count -eq 0) { throw ('-Only 指定的前缀没有任何一条路由使用：{0}' -f ($onlyList -join '、')) }
    }

    $collected = @{}
    $skipped = @()
    $rejected = @()

    foreach ($prefix in $prefixes) {
        $routeIds = @(@($Routes.routes) | Where-Object { [string]$_.credentialPrefix -eq $prefix } | ForEach-Object { [string]$_.id })
        Write-Host ''
        Write-Host ('--- {0}  用于路由：{1}' -f $prefix, ($routeIds -join ', ')) -ForegroundColor Cyan
        Write-Host '    （任一项留空表示跳过这个前缀；跳过的路由会保持 unconfigured）'

        $entry = @{}
        $abort = $false
        foreach ($suffix in $suffixes) {
            $prompt = '  ' + $prefix + $suffix
            if ($suffix -eq 'DB_PASS') {
                $value = Read-CredentialsSecretValue -Prompt $prompt
            } else {
                $value = [string](Read-Host -Prompt $prompt)
            }
            $value = $value.Trim()
            if ([string]::IsNullOrEmpty($value)) { $abort = $true; break }
            $entry[$suffix] = $value
        }

        if ($abort) {
            $skipped += $prefix
            Write-Host ('    已跳过 {0}。' -f $prefix) -ForegroundColor Yellow
            continue
        }

        $portNumber = 0
        if (-not [int]::TryParse([string]$entry['DB_PORT'], [ref]$portNumber) -or $portNumber -lt 1 -or $portNumber -gt 65535) {
            $rejected += ('{0}：DB_PORT 不是 1..65535 的整数' -f $prefix)
            continue
        }

        # 高权限账号**默认拒绝，且不提供绕过开关**。理由不是「开发库可以随便用 root」，
        # 而是这个技能会把连接信息写到一个固定的外置文件里，一旦养成用 root 的习惯，
        # 那份文件迟早会被指向生产。宁可让使用者现在就去申请只读账号。
        if (-not [string]::IsNullOrWhiteSpace($highPrivilegePattern) -and ([string]$entry['DB_USER']) -match $highPrivilegePattern) {
            $rejected += ('{0}：DB_USER 命中高权限模式（{1}），拒绝写入' -f $prefix, $highPrivilegePattern)
            continue
        }

        foreach ($suffix in $suffixes) {
            $collected[$prefix + $suffix] = [string]$entry[$suffix]
        }
        Write-Host ('    已收集 {0}（值不回显）。' -f $prefix) -ForegroundColor Green
    }

    return [pscustomobject]@{
        Table    = $collected
        Prefixes = @($prefixes)
        Skipped  = @($skipped)
        Rejected = @($rejected)
    }
}
