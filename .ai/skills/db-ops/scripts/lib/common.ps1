# lib/common.ps1 —— 通用机制：路径解析、配置断言、文件原子写、脱敏、交互判定。
#
# 职责边界
#   只提供「与数据库、路由、凭据状态都无关」的通用机制。任何知道 mysql / routes.json /
#   credentials.env 是什么的函数都不属于这里。
#
# 明确不做
#   不得调用 log.ps1 / config.ps1 / credentials.ps1 / sql-safety.ps1 / output.ps1 的任何函数；
#   不得写文件（Write-Utf8Atomic / Write-JsonAtomic 除外，它们是被调用者）；
#   不得派生进程。它是依赖最少的一层，因此在每个脚本里都最先 dot-source。
#
# Windows PowerShell 5.1 约束
#   - 本文件必须保存为 UTF-8 with BOM，否则 5.1 会按 ANSI 解码中文注释与字符串。
#   - 不使用 ?? / ?. / 三元运算符。
#   - $PSScriptRoot 只在本文件顶层可用；任何 param 块默认值里都不要用它。

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

function Get-DbOpsSkillRoot {
    # 技能根 = 本文件所在 lib 的上一级。$PSScriptRoot 在脚本体与模块顶层可用，
    # 在 param 块默认值里为空——所有调用方都必须在脚本体内调用它。
    $lib = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($lib)) {
        throw 'Get-DbOpsSkillRoot：$PSScriptRoot 为空（多半是在 param 块默认值里调用了它）。'
    }
    return (Split-Path -Parent (Split-Path -Parent $lib))
}

function Expand-PathToken {
    # 配置里允许三类 token，避免把用户名或机器相关路径写进 JSON：
    #   {desktop} -> 当前用户桌面
    #   ~         -> 当前用户主目录
    #   %VAR%     -> 同名环境变量（新增分支；旧约定只认前两个）
    #
    # 环境变量名不存在时**保留原样**，不替换成空串：调用方（Resolve-CredentialsPath）
    # 会检查结果里是否还有残留的 %，从而把一个未定义变量变成一次明确失败，
    # 而不是一个看起来合法、实际指向别处的路径。
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $expanded = $Path.Replace('{desktop}', [Environment]::GetFolderPath('Desktop'))

    $evaluator = {
        param($match)
        $name = $match.Groups[1].Value
        $value = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($value)) { return $match.Value }
        return $value
    }
    $expanded = [regex]::Replace($expanded, '%([A-Za-z_][A-Za-z0-9_]*)%', $evaluator)

    if ($expanded.StartsWith('~')) {
        $rest = $expanded.Substring(1).TrimStart('\', '/')
        if ([string]::IsNullOrWhiteSpace($rest)) { $expanded = $env:USERPROFILE }
        else { $expanded = Join-Path $env:USERPROFILE $rest }
    }
    return $expanded
}

function Resolve-FullPath {
    param(
        [string]$Path,
        [string]$Base
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $expanded = Expand-PathToken $Path
    if ([IO.Path]::IsPathRooted($expanded)) { $candidate = $expanded }
    else { $candidate = Join-Path $Base $expanded }
    return [IO.Path]::GetFullPath($candidate)
}

function Test-ContainsUnresolvedToken {
    # 展开后残留的 % 或 {x} 说明配置里写了不存在的环境变量或未知占位符。
    # 必须当成硬失败：静默通过会让凭据被写到一个谁也没打算用的位置。
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path -match '%') { return $true }
    if ($Path -match '\{[A-Za-z_]+\}') { return $true }
    return $false
}

# ---------------------------------------------------------------------------
# 配置取值与断言
# ---------------------------------------------------------------------------

function Get-OptionalProperty {
    # Set-StrictMode 2.0 下解引用不存在的属性会抛裸 PropertyNotFoundException，
    # 把可读的配置报错变成一句 .NET 消息。所有可选字段都要走这里。
    param(
        $Object,
        [string]$Name,
        $Default
    )
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Test-HasProperty {
    param(
        $Object,
        [string]$Name
    )
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Assert-RequiredFields {
    param(
        $Object,
        [string[]]$Names,
        [string]$Context
    )
    foreach ($name in @($Names)) {
        $property = if ($null -eq $Object) { $null } else { $Object.PSObject.Properties[$name] }
        if ($null -eq $property -or $null -eq $property.Value) { throw "配置缺少字段：$Context.$name" }
        $value = $property.Value
        # 集合必须单独判：**空集合**才算缺失。
        #
        # 不能沿用「[string] 强转后判空白」——5.1 里 `[string]` 一个 PSCustomObject 得到的是
        # 空字符串，于是 3 个元素的数组会被误报成「缺少字段」。
        # 字符串本身也是 IEnumerable，必须显式排除，否则下面那段永远走不到。
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            if (@($value).Count -eq 0) { throw "配置缺少字段：$Context.$name" }
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "配置缺少字段：$Context.$name" }
    }
}

function Assert-NoUnknownFields {
    # 「不维护 JSON Schema」之后补回来的唯一实质能力：拼错的字段名必须报错，
    # 而不是被静默忽略。少了它，把 allowWrite 拼成 allowWrites 会让配置看起来
    # 生效其实没有——而这一条恰好是写操作的总闸门。
    param(
        $Object,
        [string[]]$Allowed,
        [string]$Context
    )
    if ($null -eq $Object) { return }
    $unknown = @($Object.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $Allowed -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw ("配置存在未知字段（多半是拼写错误）：{0} → {1}。允许的字段：{2}" -f $Context, ($unknown -join '、'), ($Allowed -join '、'))
    }
}

function Assert-EnumValue {
    param(
        [string]$Value,
        [string[]]$Allowed,
        [string]$Context
    )
    if ($Allowed -notcontains $Value) {
        throw ("{0} 取值非法：'{1}'。允许值：{2}" -f $Context, $Value, ($Allowed -join '、'))
    }
}

function Assert-RegexMatch {
    param(
        [string]$Value,
        [string]$Pattern,
        [string]$Context
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch $Pattern) {
        throw ("{0} 取值非法：'{1}'。要求匹配：{2}" -f $Context, $Value, $Pattern)
    }
}

# ---------------------------------------------------------------------------
# 文件读写
# ---------------------------------------------------------------------------

function Read-JsonFile {
    # 必须用 [IO.File]::ReadAllText：Get-Content 返回的字符串带 PSPath/PSDrive/PSProvider
    # 装饰属性，一旦进入结果对象，ConvertTo-Json 会连带遍历整个 provider 对象图并指数膨胀。
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Write-Utf8Atomic {
    # 先写同目录临时文件再原子替换：直接写目标文件时，中途失败会留下半个文件，
    # 而凭据文件被截断一次就等于凭据丢失。
    # 不带 BOM —— 数据文件带 BOM 会让别的工具解析时多出一个 U+FEFF。
    param(
        [string]$Path,
        [string]$Content
    )
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $temp = Join-Path $parent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($full), [guid]::NewGuid().ToString('N').Substring(0, 8))
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($temp, $Content, $encoding)
        if (Test-Path -LiteralPath $full) {
            # 目标已存在时 File.Replace 才是原子替换；目标不存在时它要求源与目标都存在。
            [IO.File]::Replace($temp, $full, $null)
        } else {
            [IO.File]::Move($temp, $full)
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-JsonAtomic {
    param(
        [string]$Path,
        $Value,
        [int]$Depth = 10
    )
    $text = $Value | ConvertTo-Json -Depth $Depth
    Write-Utf8Atomic -Path $Path -Content $text
}

# ---------------------------------------------------------------------------
# 交互判定
# ---------------------------------------------------------------------------

function Test-CanPrompt {
    # 判断「当前进程能不能向用户提问」的唯一可靠依据。
    #
    # **不得改用 $Host.Name**：在 agent 派生的进程里 $Host.Name 仍然是 'ConsoleHost'，
    # 用它判断会得到「可以交互」的错误结论，然后 Read-Host 读到 EOF 或直接挂住。
    # [Console]::IsInputRedirected 在 stdin 被重定向时为 true，是唯一区分得开的信号。
    #
    # 注意本函数返回的是「能不能问」，不是「该不该问」。setup-credentials.ps1 在写任何
    # 文件之前先问这一句，为 false 就 exit 7。
    try {
        return (-not [Console]::IsInputRedirected)
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# 脱敏
# ---------------------------------------------------------------------------

function Protect-SecretText {
    # 按给定的秘密集合做字面替换。长度 < 8 的值不替换：短串（'1'、'sa'）会在正常
    # 文本里到处误命中，把输出打成筛子反而看不出真正泄漏了什么。
    # 替换结果固定为 ***，不按长度补星号——补长度等于泄漏了长度。
    param(
        [string]$Text,
        [string[]]$Secrets
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $result = $Text
    foreach ($secret in @($Secrets)) {
        if ([string]::IsNullOrEmpty($secret)) { continue }
        if ($secret.Length -lt 8) { continue }
        $result = $result.Replace($secret, '***')
    }
    return $result
}

function Get-SecretLikeValues {
    # 从一份凭据键值表里挑出**值**，供 Protect-SecretText 使用。
    # 只挑 *DB_PASS* 这类键，不把 host/user 也当秘密：user 名是要展示的（脱敏后），
    # host 是诊断信息。把它们一起抹掉会让排障时看不到任何有用上下文。
    param($Values)
    $secrets = @()
    if ($null -eq $Values) { return $secrets }
    $names = @()
    if ($Values -is [hashtable]) { $names = @($Values.Keys) }
    else { $names = @($Values.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($name in $names) {
        if ($name -notmatch '(?i)_PASS$') { continue }
        $value = if ($Values -is [hashtable]) { [string]$Values[$name] } else { [string]$Values.$name }
        if (-not [string]::IsNullOrEmpty($value)) { $secrets += $value }
    }
    return @($secrets)
}

function Get-MaskedUserName {
    # 输出里要显示账号，但完整账号名也是一种信息泄漏（正好是撞库的一半）。
    # 保留首字符与长度感：root -> r***、wms_rd -> w***。
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '<empty>' }
    if ($Name.Length -le 1) { return '***' }
    return ($Name.Substring(0, 1) + '***')
}

# ---------------------------------------------------------------------------
# 摘要
# ---------------------------------------------------------------------------

function Get-Sha256Short {
    # 供阶段 2 的 PlanDigest 使用；本阶段只被 Validate 的自检路径引用。
    # 用 SHA256 前 N 个十六进制字符，避免把整段 SQL 放进日志或命令行。
    param(
        [string]$Text,
        [int]$Length = 16
    )
    if ($null -eq $Text) { $Text = '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($Length -gt $hex.Length) { $Length = $hex.Length }
        return $hex.Substring(0, $Length)
    } finally {
        $sha.Dispose()
    }
}

# ---------------------------------------------------------------------------
# 异常定位
# ---------------------------------------------------------------------------

function Get-DbOpsErrorLocation {
    # 报**真实**的出错文件与行号。
    #
    # 踩过的坑：顶层最初写死 '位置：db-ops.ps1:{0}'，而行号取自 $_.InvocationInfo，
    # 于是 config.ps1:257 的异常被报成 db-ops.ps1:257——一个恰好存在但完全无关的位置。
    # 本技能的库文件是 dot-source 进来的，出错点几乎总在 lib 里，所以必须取真实文件名。
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$FallbackScriptName
    )

    $scriptName = $FallbackScriptName
    $lineNumber = '?'
    if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.InvocationInfo) {
        $info = $ErrorRecord.InvocationInfo
        if (-not [string]::IsNullOrWhiteSpace([string]$info.ScriptName)) {
            $scriptName = Split-Path -Leaf ([string]$info.ScriptName)
        }
        if ($null -ne $info.ScriptLineNumber) { $lineNumber = [string]$info.ScriptLineNumber }
    }
    return ('位置：{0}:{1}' -f $scriptName, $lineNumber)
}
