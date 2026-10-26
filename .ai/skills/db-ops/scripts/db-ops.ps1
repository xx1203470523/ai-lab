<#
.SYNOPSIS
    db-ops 唯一公开入口。

.DESCRIPTION
    阶段 1 可用：Validate、ListTargets。二者都是**完全离线**的——不连数据库、不写文件、
    不创建日志目录、不碰凭据文件的 ACL。

    Check / Query / File / Exec 明确报「阶段 2 未实现」并 exit 1，绝不静默成功：
    一个「什么都没做但返回 0」的查询入口，比一个明确报错的入口危险得多。

    退出码
      0 成功
      1 硬失败（JSON 非法、schemaVersion 未知、未知字段、调用未实现功能、写 SQL 走只读模式）
      2 需要确认（本阶段由 setup-credentials.ps1 的 -Force 缺 -ConfirmReset 产生）
      3 缺少确认摘要（阶段 2）
      4 摘要不匹配（阶段 2）
      5 目标就绪度不足（unconfigured / unsupported / disabled / needs-review / blocked / permission-warning）
      6 输入非法（未知路由、未指定目标、参数组合非法、凭据文件结构非法）
      7 无法交互（只由 setup-credentials.ps1 产生）

.NOTES
    本文件必须保存为 UTF-8 with BOM：Windows PowerShell 5.1 会把无 BOM 的 .ps1 当 ANSI 读，
    中文提示会变成乱码。

    控制流约定：**所有 exit 都发生在顶层 try/catch 之外**。
    在 try 块里 exit 会让「退出码」与「异常路径」纠缠在一起（catch 是否吞掉退出信号取决于
    异常类型），而本脚本的全部价值就在于退出码可信。因此业务逻辑放在 Invoke-DbOpsMain 里
    返回结果对象，由顶层统一决定打印与退出码。
#>
param(
    [ValidateSet('Validate', 'ListTargets', 'Check', 'Query', 'File', 'Exec')]
    [string]$Mode = 'Validate',

    # -Environment 只是 -Target 的**别名**，不是第二个维度。
    # 旧技能同时存在 -Environment 与 -Target 且 -Target 静默获胜，文档还分成两派，
    # 于是「写了环境却落到另一个库」这种事无法被使用者察觉。
    # 据点与环境一律通过路由 id 表达，因此这个名字从此只作别名。
    [Alias('Environment')]
    [string]$Target,

    [string]$Sql,

    [string]$SqlPath,

    # -1 = 未指定，取 policy.output.maxRows；0 = 明确不要追加 LIMIT。
    [int]$Limit = -1,

    [ValidateSet('Table', 'Tsv', 'Json')]
    [string]$Format,

    # 库名是 routes.json 的事实。保留这个参数只是为了报出「不允许覆盖」这个明确的拒绝，
    # 而不是让旧用法静默生效。
    [string]$Database,

    [switch]$ListTargets,

    [switch]$Json,

    # 仅供测试：覆盖技能根目录。
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# 这里自己设置编码，而不是复用仓库里的 .ai/core/scripts/powershell/ps-utf8.ps1 前导脚本：
# 本技能装在 %USERPROFILE%\.claude\skills\ 下，必须能在**任意**项目里工作，因此不能依赖
# 某个仓库的相对路径。这也是本技能「不绑定 WMS」的一部分。
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # 老宿主上设置编码可能失败；失败不该让整个脚本停摆。
}

# dot-source 顺序固定：common → log → config → credentials → sql-safety → output。
# common 是最底层，不得反向依赖其余模块。
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\log.ps1')
. (Join-Path $PSScriptRoot 'lib\config.ps1')
. (Join-Path $PSScriptRoot 'lib\credentials.ps1')
. (Join-Path $PSScriptRoot 'lib\sql-safety.ps1')
. (Join-Path $PSScriptRoot 'lib\output.ps1')

$EXIT_OK = 0
$EXIT_HARD_FAILURE = 1
$EXIT_NEEDS_CONFIRMATION = 2
$EXIT_MISSING_DIGEST = 3
$EXIT_DIGEST_MISMATCH = 4
$EXIT_NOT_READY = 5
$EXIT_INVALID_INPUT = 6
$EXIT_CANNOT_PROMPT = 7

function Write-DbOpsError {
    param([string]$Message)
    [Console]::Error.WriteLine(('ERROR: {0}' -f $Message))
}

function New-DbOpsResult {
    param(
        [int]$Code,
        $Lines,
        $StderrLines,
        $Envelope
    )
    return [pscustomobject]@{
        Code        = $Code
        Lines       = @($Lines)
        StderrLines = @($StderrLines)
        Envelope    = $Envelope
    }
}

# ---------------------------------------------------------------------------
# 路由状态与目标解析
# ---------------------------------------------------------------------------

function New-RouteStateList {
    # 为每条路由算一次有效状态。所有需要「看状态」的地方都走这里，
    # 保证 -ListTargets 与 -Mode Validate 给出的结论逐字相同。
    param(
        $Routes,
        $Policy,
        [string]$FileState,
        $CredentialValues
    )

    $states = @()
    foreach ($route in @(Get-DbOpsRouteList -Routes $Routes)) {
        $routeCredential = Get-RouteCredential -Route $route -Values $CredentialValues -Policy $Policy
        $status = Get-DbOpsRouteStatus -Route $route -FileState $FileState -RouteCredential $routeCredential -Policy $Policy
        $states += [pscustomobject]@{
            Id          = [string]$route.id
            Environment = [string]$route.environment
            Tenant      = [string]$route.tenant
            Site        = Get-OptionalProperty -Object $route -Name 'site' -Default $null
            Engine      = [string]$route.engine
            Target      = (Get-RedactedRouteInfo -Route $route)
            Status      = [string]$status.EffectiveStatus
            Reason      = [string]$status.Reason
        }
    }
    return @($states)
}

function Resolve-RequestedRoute {
    # 只做两件事：拿到一条路由，或明确报「没给」/「不认识」。**没有第三种结果。**
    # 返回 {Ok, Code, Message, Route}。不打印、不退出——打印与退出决策留在调用方。
    param(
        $Routes,
        $Policy
    )

    $selector = [string]$Target
    if ([string]::IsNullOrWhiteSpace($selector)) {
        $defaultRoute = [string](Get-OptionalProperty -Object $Policy -Name 'defaultRoute' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($defaultRoute)) { $selector = $defaultRoute }
    }

    if ([string]::IsNullOrWhiteSpace($selector)) {
        $message = '没有指定目标。当前 policy.defaultRoute 为 null，因此不存在默认路由——' +
            '这是刻意的：旧技能「不指定就用开发库」会让一次忘记写目标的查询落到别的库上。' +
            '请显式传 -Target <路由 id>。可用值见 -ListTargets。'
        return [pscustomobject]@{ Ok = $false; Code = $EXIT_INVALID_INPUT; Message = $message; Route = $null }
    }

    $route = Get-DbOpsRoute -Routes $Routes -Selector $selector
    if ($null -eq $route) {
        $message = '未知路由 id：{0}。这里只做精确匹配，不做前缀或近似匹配。' +
            '请用 -ListTargets 查看全部路由 id（正式据点请同时确认据点与库名的对应关系）。'
        $message = $message -f $selector
        return [pscustomobject]@{ Ok = $false; Code = $EXIT_INVALID_INPUT; Message = $message; Route = $null }
    }

    return [pscustomobject]@{ Ok = $true; Code = $EXIT_OK; Message = ''; Route = $route }
}

# ---------------------------------------------------------------------------
# 模式实现
# ---------------------------------------------------------------------------

function Invoke-ListTargets {
    param(
        $Routes,
        $Policy,
        [string]$FileState,
        $CredentialValues
    )

    $states = @(New-RouteStateList -Routes $Routes -Policy $Policy -FileState $FileState -CredentialValues $CredentialValues)
    $lines = @(Format-RouteListText -RouteStates $states)
    $lines += ''
    $lines += ('凭据文件状态：{0}' -f $FileState)
    $lines += ('未建路由的条目：{0}' -f ((@($Routes.nonRoutes) | ForEach-Object { [string]$_.id }) -join '、'))

    $envelope = New-ResultEnvelope -Mode 'ListTargets' -Route $null -Database $null -Success $true
    $envelope.Success = $true
    $envelope['Details'] = [ordered]@{
        CredentialsFileState = $FileState
        RouteCount           = $states.Count
        Routes               = $states
        NonRoutes            = @($Routes.nonRoutes)
    }

    return New-DbOpsResult -Code $EXIT_OK -Lines $lines -StderrLines @() -Envelope $envelope
}

function Invoke-Validate {
    param(
        [string]$SkillRoot,
        $Routes,
        $Policy,
        [string]$FileState,
        $CredentialValues,
        [string]$CredentialsPath,
        $CredentialErrors
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # 显式给初值：Set-StrictMode 2.0 下「未赋值就读」会抛错，而下面的分支并非每条都赋值。
    $exitCode = $EXIT_NOT_READY
    $errorType = $null
    $errorMessage = $null
    $requestedRoute = $null
    $targetStatus = $null
    $sqlCheck = $null

    $lines.Add('db-ops Validate（离线，不连库）')
    $lines.Add(('技能根目录：{0}' -f $SkillRoot))
    $lines.Add(('凭据文件：{0}' -f $CredentialsPath))
    $lines.Add(('凭据文件状态：{0}' -f $FileState))
    $lines.Add('')

    # --- 策略摘要（不含任何秘密） ---
    $lines.Add('策略：')
    $lines.Add(('  defaultRoute          : {0}' -f (Get-OptionalProperty -Object $Policy -Name 'defaultRoute' -Default '<null>')))
    $lines.Add(('  requireExplicitTarget : {0}' -f $Policy.requireExplicitTarget))
    $lines.Add(('  环境开关              : dev={0} stag={1} prod={2}' -f $Policy.environments.dev, $Policy.environments.stag, $Policy.environments.prod))
    $lines.Add(('  输出上限              : maxRows={0} maxCellChars={1}' -f $Policy.output.maxRows, $Policy.output.maxCellChars))
    $lines.Add(('  执行闸门              : exec.allowWrite={0}（阶段 1 恒为 false，且 Exec 未实现）' -f $Policy.exec.allowWrite))
    $lines.Add('')

    # --- 凭据文件 ---
    if ($FileState -eq 'missing') {
        $setupPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'setup-credentials.ps1'
        $lines.Add('凭据：文件不存在。所有路由都会停在 unconfigured。')
        $lines.Add(('  下一步：在**交互式终端**里运行 {0} 建立凭据文件（本阶段不会自动创建）。' -f $setupPath))
    } else {
        $configuredPrefixes = @()
        foreach ($route in @(Get-DbOpsRouteList -Routes $Routes)) {
            $routeCredential = Get-RouteCredential -Route $route -Values $CredentialValues -Policy $Policy
            if ($routeCredential.Present -and $routeCredential.MissingKeys.Count -eq 0) {
                $configuredPrefixes += [string]$route.credentialPrefix
            }
        }
        $configuredPrefixes = @($configuredPrefixes | Select-Object -Unique | Sort-Object)
        $prefixText = '（无）'
        if ($configuredPrefixes.Count -gt 0) { $prefixText = $configuredPrefixes -join '、' }
        $lines.Add(('凭据：{0}' -f $FileState))
        $lines.Add(('  已完整配置的前缀：{0}' -f $prefixText))
        $lines.Add('  本阶段不验证连通性：前缀齐备只说明「配置到位」，不代表账号能连上库。')
    }
    $lines.Add('')

    # --- 路由状态 ---
    $states = @(New-RouteStateList -Routes $Routes -Policy $Policy -FileState $FileState -CredentialValues $CredentialValues)
    $lines.Add(('路由：共 {0} 条' -f $states.Count))
    foreach ($state in $states) {
        $lines.Add(('  {0,-22} {1,-18} {2}' -f $state.Id, $state.Status, $state.Target))
        $lines.Add(('    {0}' -f $state.Reason))
    }
    $lines.Add('')

    # --- 证据层交叉核对（只告警） ---
    foreach ($warning in @(Get-DbOpsRouteWarnings -Routes $Routes)) { $warnings.Add([string]$warning) }

    # 覆盖率是阶段 1 必须显式说明的事实：正式路由很可能一条都到不了 ready。
    $readyCount = @($states | Where-Object { $_.Status -eq 'ready' }).Count
    $prodReady = @($states | Where-Object { $_.Status -eq 'ready' -and $_.Environment -eq 'prod' }).Count
    $lines.Add(('就绪度：{0}/{1} 条路由 ready，其中 prod 环境 {2} 条。' -f $readyCount, $states.Count, $prodReady))
    $lines.Add('  「ready 为 0」不等于技能坏了：每条 ready 路由都需要一个具备只读权限的独立账号，')
    $lines.Add('  而仓库里 appsettings 的连接串（含被命名为 WMS_ReadOnly 的那条）目前全部使用 root。')
    $lines.Add('')

    # --- 请求的路由 ---
    $requested = Resolve-RequestedRoute -Routes $Routes -Policy $Policy
    if (-not $requested.Ok) {
        $lines.Add(('目标：{0}' -f $requested.Message))
        $exitCode = [int]$requested.Code
        $errorType = 'InvalidInput'
        $errorMessage = [string]$requested.Message
    } else {
        $requestedRoute = $requested.Route
        $targetStatus = @($states | Where-Object { $_.Id -eq [string]$requestedRoute.id })[0]
        $lines.Add(('目标：{0}（{1}）' -f $requestedRoute.id, $requestedRoute.tenant))
        $lines.Add(('  环境/据点 ：{0} / {1}' -f $requestedRoute.environment, (Get-OptionalProperty -Object $requestedRoute -Name 'site' -Default '-')))
        $lines.Add(('  连接目标  ：{0}' -f $targetStatus.Target))
        $lines.Add(('  有效状态  ：{0}' -f $targetStatus.Status))
        $lines.Add(('  依据      ：{0}' -f $targetStatus.Reason))
        if ($targetStatus.Status -eq 'ready') {
            $exitCode = $EXIT_OK
        } else {
            $exitCode = $EXIT_NOT_READY
            $errorType = 'TargetNotReady'
            $errorMessage = [string]$targetStatus.Reason
        }
    }
    $lines.Add('')

    # --- SQL 静态校验（只读守卫） ---
    # 只做**静态**判定：本阶段没有执行器，因此既不 EXPLAIN，也不回显执行计划。
    $sqlText = $null
    $sqlSource = $null
    if (-not [string]::IsNullOrWhiteSpace($SqlPath)) {
        if (Test-Path -LiteralPath $SqlPath -PathType Leaf) {
            $sqlText = [IO.File]::ReadAllText($SqlPath)
            $sqlSource = $SqlPath
        } else {
            $lines.Add(('SQL 文件不存在：{0}' -f $SqlPath))
            $exitCode = $EXIT_INVALID_INPUT
            $errorType = 'InvalidInput'
            $errorMessage = ('SQL 文件不存在：{0}' -f $SqlPath)
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($Sql)) {
        $sqlText = $Sql
        $sqlSource = '<-Sql>'
    }

    if (-not [string]::IsNullOrWhiteSpace($sqlText)) {
        $sqlCheck = Test-ReadOnlySql -Text $sqlText
        $lines.Add(('SQL 静态校验（来源：{0}，哈希：{1}）' -f $sqlSource, $sqlCheck.TextHash))
        $lines.Add(('  结论    ：{0}' -f $sqlCheck.Reason))
        $lines.Add(('  语句种类：{0}，语句条数：{1}' -f $sqlCheck.Kind, $sqlCheck.StatementCount))
        $lines.Add('  只校验静态安全性；本阶段不生成执行计划（ExplainPlan 恒为 null）。')
        $lines.Add('  注意：关键字拦截是第二道防线，不等于数据库授权。真正兜底的是只读账号的权限。')
        if (-not $sqlCheck.Ok) {
            # 与「目标没配好」（5）分开：这是 SQL 本身被拒绝，改的是 SQL 而不是配置。
            $exitCode = $EXIT_HARD_FAILURE
            $errorType = 'SqlRejected'
            $errorMessage = [string]$sqlCheck.Reason
        }
        $lines.Add('')
    }

    # --- 未建路由的条目 ---
    $lines.Add('未建路由的条目（存在但不作为可连接目标）：')
    foreach ($nonRoute in @($Routes.nonRoutes)) {
        $lines.Add(('  {0}  [{1}/{2}]' -f $nonRoute.id, $nonRoute.kind, $nonRoute.status))
        $lines.Add(('    {0}' -f $nonRoute.reason))
    }

    if ($warnings.Count -gt 0) {
        $lines.Add('')
        $lines.Add('告警：')
        foreach ($warning in $warnings) { $lines.Add(('  - {0}' -f $warning)) }
    }

    $routeId = $null
    $database = $null
    if ($null -ne $requestedRoute) {
        $routeId = [string]$requestedRoute.id
        $database = Get-OptionalProperty -Object $requestedRoute -Name 'database' -Default $null
    }

    $envelope = New-ResultEnvelope -Mode 'Validate' -Route $routeId -Database $database -Success ($exitCode -eq $EXIT_OK)
    $envelope.Success = ($exitCode -eq $EXIT_OK)
    $envelope.ErrorType = $errorType
    $envelope.ErrorMessage = $errorMessage
    $envelope.Warnings = @($warnings)
    $envelope['ExplainPlan'] = $null
    $envelope['Details'] = [ordered]@{
        SkillRoot            = $SkillRoot
        CredentialsPath      = $CredentialsPath
        CredentialsFileState = $FileState
        CredentialsErrors    = @($CredentialErrors)
        TargetStatus         = $(if ($null -eq $targetStatus) { $null } else { [string]$targetStatus.Status })
        TargetStatusReason   = $(if ($null -eq $targetStatus) { $null } else { [string]$targetStatus.Reason })
        RouteCount           = $states.Count
        ReadyCount           = $readyCount
        ProdReadyCount       = $prodReady
        Routes               = $states
        SqlCheck             = $sqlCheck
        NonRoutes            = @($Routes.nonRoutes)
    }

    return New-DbOpsResult -Code $exitCode -Lines $lines.ToArray() -StderrLines @() -Envelope $envelope
}

# ---------------------------------------------------------------------------
# 主流程（返回结果对象，不打印、不退出）
# ---------------------------------------------------------------------------

function Invoke-DbOpsMain {
    param([string]$Mode, [string]$Root)

    if ($ListTargets) { $Mode = 'ListTargets' }

    if ($Limit -lt -1) {
        $message = '-Limit 只能是 -1（未指定）、0（明确不追加 LIMIT）或正整数，收到：{0}。' -f $Limit
        return New-DbOpsResult -Code $EXIT_INVALID_INPUT -Lines @() -StderrLines @($message) -Envelope $null
    }

    # -Database 一律拒绝。库名是 routes.json 的事实；允许命令行覆盖等于允许一次
    # 「看起来查的是 A 库、实际连的是 B 库」的操作。
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $message = '不允许用 -Database 覆盖库名（收到：{0}）。库名由 routes.json 的路由决定；' +
            '需要另一个库请新增一条路由。'
        $message = $message -f $Database
        return New-DbOpsResult -Code $EXIT_INVALID_INPUT -Lines @() -StderrLines @($message) -Envelope $null
    }

    $skillRoot = Get-DbOpsRoot -Hint $Root
    $policy = Get-DbOpsPolicy -Root $skillRoot
    $routes = Get-DbOpsRoutes -Root $skillRoot
    $credentialsPath = Resolve-CredentialsPath -Policy $policy

    if ([string]::IsNullOrWhiteSpace($Format)) { $Format = [string]$policy.output.defaultFormat }

    # 阶段 1 的执行闸门：Check/Query/File 需要执行器，Exec 需要写权限与确认链，都还没实现。
    # 这里必须硬失败而不是「返回 0 行」：一个静默成功的查询入口会被当成「查到了，就是没有数据」。
    if ($Mode -eq 'Check' -or $Mode -eq 'Query' -or $Mode -eq 'File') {
        $message = '-Mode {0} 属于阶段 2，本阶段未实现。' +
            '阶段 1 只交付离线能力：-Mode Validate 与 -ListTargets。'
        $message = $message -f $Mode
        return New-DbOpsResult -Code $EXIT_HARD_FAILURE -Lines @() -StderrLines @($message) -Envelope $null
    }
    if ($Mode -eq 'Exec') {
        $message = '-Mode Exec 属于阶段 2，本阶段未实现（policy.exec.allowWrite={0}）。' +
            '写操作走 workflows/exec-flow.md 描述的受控执行流程。'
        $message = $message -f $policy.exec.allowWrite
        return New-DbOpsResult -Code $EXIT_HARD_FAILURE -Lines @() -StderrLines @($message) -Envelope $null
    }
    if ($Mode -ne 'Validate' -and $Mode -ne 'ListTargets') {
        return New-DbOpsResult -Code $EXIT_HARD_FAILURE -Lines @() -StderrLines @(('未处理的模式：{0}' -f $Mode)) -Envelope $null
    }

    # 阶段 1 的 RunId 只为信封存在。日志开关即使打开也不在这里落盘：
    # Validate / ListTargets 必须是彻底只读的，连日志目录都不该被创建。
    Initialize-RunLog -RunId ([guid]::NewGuid().ToString('N')) -LogPath $null -StatusPath $null -Json:$Json

    $fileStateInfo = Get-CredentialsFileState -Path $credentialsPath -Policy $policy
    $fileState = [string]$fileStateInfo.State
    $credentialValues = Get-OptionalProperty -Object $fileStateInfo -Name 'Values' -Default @{}
    $credentialErrors = @(Get-OptionalProperty -Object $fileStateInfo -Name 'Errors' -Default @())

    # 凭据文件结构非法：这是**用户输入**的问题，与「还没配置」不是一回事，
    # 因此用 6 而不是 5。混成一个码会让人分不清该去修文件还是去配账号。
    if ($fileState -eq 'invalid') {
        $stderrLines = @()
        $stderrLines += ('凭据文件结构非法：{0}' -f ($credentialErrors -join '；'))
        $stderrLines += ('文件：{0}（内容不予回显：坏行里可能带明文口令）' -f $credentialsPath)
        return New-DbOpsResult -Code $EXIT_INVALID_INPUT -Lines @() -StderrLines $stderrLines -Envelope $null
    }

    if ($Mode -eq 'ListTargets') {
        $result = Invoke-ListTargets -Routes $routes -Policy $policy -FileState $fileState -CredentialValues $credentialValues
    } else {
        $result = Invoke-Validate -SkillRoot $skillRoot -Routes $routes -Policy $policy -FileState $fileState `
            -CredentialValues $credentialValues -CredentialsPath $credentialsPath -CredentialErrors $credentialErrors
    }

    # 「输出里没有凭据值」是一条可执行检查，不是文档里的承诺，而且必须在**拿得到凭据值的
    # 那一层**做：把值往上传递一遍只为了在上面断言，等于多开一条泄漏通道。
    # 这里覆盖所有会出去的东西：stdout 行、stderr 行、以及 JSON 信封（用与顶层相同的
    # 渲染方式），因此在顶层再算一次秘密集合是多余的。
    # 凭据值为空时 Get-OutputSecrets 返回 @()，断言随即短路。
    Assert-NoSecretInOutput -Text (Get-DbOpsRenderableText -Result $result) -Secrets (Get-OutputSecrets -CredentialValues $credentialValues)

    return $result
}

function Get-DbOpsRenderableText {
    # 顶层将要打印出来的文本的等价形式。集中在这里，避免「断言看的是 A、打印的是 B」。
    param($Result)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add((@($Result.Lines) -join "`r`n"))
    $parts.Add((@($Result.StderrLines) -join "`r`n"))
    if ($Json -and $null -ne $Result.Envelope) {
        # 与顶层同参：-InputObject 阻止 ConvertTo-Json 把单元素数组展开成裸对象。
        $parts.Add((ConvertTo-Json -InputObject $Result.Envelope -Depth 12))
    }
    return ($parts -join "`n")
}

# ---------------------------------------------------------------------------
# 顶层：打印 + 退出码
# ---------------------------------------------------------------------------

$exitCode = $EXIT_HARD_FAILURE
$result = $null
$jsonRendered = ''

try {
    $result = Invoke-DbOpsMain -Mode $Mode -Root $Root
    $exitCode = [int]$result.Code
    if ($Json -and $null -ne $result.Envelope) {
        $jsonRendered = ConvertTo-Json -InputObject $result.Envelope -Depth 12
    }
} catch {
    Write-DbOpsError ('{0}' -f $_.Exception.Message)
    Write-DbOpsError (Get-DbOpsErrorLocation -ErrorRecord $_ -FallbackScriptName 'db-ops.ps1')
    exit $EXIT_HARD_FAILURE
}

foreach ($line in @($result.StderrLines)) { Write-DbOpsError $line }

if ($Json -and $null -ne $result.Envelope) {
    Write-Output $jsonRendered
} else {
    foreach ($line in @($result.Lines)) { Write-Output $line }
}

exit $exitCode
