# lib/config.ps1 —— 读、校验、解析 config/policy.json 与 config/routes.json，并计算有效路由状态。
#
# 职责边界
#   1) 定位技能根目录与两个配置文件；
#   2) 校验它们的结构（不维护 JSON Schema，用断言代替）；
#   3) 把凭据文件状态 + 路由凭据状态折算成运行期 effectiveStatus。
#
# 明确不做
#   不读凭据文件（那是 credentials.ps1）、不连数据库、不格式化输出、不写任何文件。
#   Get-DbOpsRouteStatus **不读文件系统**——文件状态由调用方传进来，
#   因此这个纯函数可以被离线单测反复调用而没有任何副作用。
#
# 依赖：common.ps1 必须先 dot-source。

$script:DbOpsConfigCache = @{}

# ---------------------------------------------------------------------------
# 定位与读取
# ---------------------------------------------------------------------------

function Get-DbOpsRoot {
    param([string]$Hint)
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        $full = [IO.Path]::GetFullPath($Hint)
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "指定的技能根目录不存在：$full" }
        return $full
    }
    return (Get-DbOpsSkillRoot)
}

function Get-DbOpsConfigPath {
    param(
        [string]$Root,
        [string]$Name
    )
    $path = Join-Path (Join-Path $Root 'config') $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "配置文件不存在：$path" }
    return $path
}

function Get-DbOpsPolicy {
    param([string]$Root)
    $path = Get-DbOpsConfigPath -Root $Root -Name 'policy.json'
    if ($script:DbOpsConfigCache.ContainsKey($path)) { return $script:DbOpsConfigCache[$path] }
    $policy = Read-JsonFile -Path $path
    if ($null -eq $policy) { throw "policy.json 为空或不是合法 JSON：$path" }
    Assert-DbOpsPolicySchema -Policy $policy
    $script:DbOpsConfigCache[$path] = $policy
    return $policy
}

function Get-DbOpsRoutes {
    param([string]$Root)
    $path = Get-DbOpsConfigPath -Root $Root -Name 'routes.json'
    if ($script:DbOpsConfigCache.ContainsKey($path)) { return $script:DbOpsConfigCache[$path] }
    $routes = Read-JsonFile -Path $path
    if ($null -eq $routes) { throw "routes.json 为空或不是合法 JSON：$path" }
    Assert-DbOpsRoutesSchema -Routes $routes
    $script:DbOpsConfigCache[$path] = $routes
    return $routes
}

function Clear-DbOpsConfigCache {
    # 只为测试路径提供：同一次运行里换了 -Root 时缓存必须失效。
    $script:DbOpsConfigCache = @{}
}

# ---------------------------------------------------------------------------
# policy.json 结构校验
# ---------------------------------------------------------------------------

function Assert-BooleanField {
    param(
        $Object,
        [string]$Name,
        [string]$Context
    )
    $property = if ($null -eq $Object) { $null } else { $Object.PSObject.Properties[$Name] }
    if ($null -eq $property -or $null -eq $property.Value) { throw "配置缺少字段：$Context.$Name" }
    if ($property.Value -isnot [bool]) { throw "$Context.$Name 必须是布尔值（true/false）。" }
}

function Assert-IntegerField {
    param(
        $Object,
        [string]$Name,
        [string]$Context,
        [int]$Minimum = 0,
        [int]$Maximum = [int]::MaxValue
    )
    $property = if ($null -eq $Object) { $null } else { $Object.PSObject.Properties[$Name] }
    if ($null -eq $property -or $null -eq $property.Value) { throw "配置缺少字段：$Context.$Name" }
    $value = $property.Value
    if ($value -isnot [int] -and $value -isnot [long]) { throw "$Context.$Name 必须是整数。" }
    if ([long]$value -lt $Minimum -or [long]$value -gt $Maximum) {
        throw ("{0}.{1} 取值超出范围 {2}..{3}：{4}" -f $Context, $Name, $Minimum, $Maximum, $value)
    }
}

function Assert-RegularExpression {
    param(
        [string]$Pattern,
        [string]$Context
    )
    if ([string]::IsNullOrWhiteSpace($Pattern)) { throw "$Context 不能为空。" }
    try {
        $null = New-Object System.Text.RegularExpressions.Regex($Pattern)
    } catch {
        throw ("{0} 不是合法正则表达式：{1}（{2}）" -f $Context, $Pattern, $_.Exception.Message)
    }
}

function Assert-DbOpsPolicySchema {
    param($Policy)

    $allowed = @('schemaVersion', 'credentialsPath', 'environments', 'defaultRoute', 'requireExplicitTarget',
        'output', 'temp', 'logging', 'credentials', 'exec')
    Assert-NoUnknownFields -Object $Policy -Allowed $allowed -Context 'policy.json'
    Assert-RequiredFields -Object $Policy -Names @('schemaVersion', 'credentialsPath', 'environments', 'requireExplicitTarget') -Context 'policy.json'

    if ([int](Get-OptionalProperty -Object $Policy -Name 'schemaVersion' -Default -1) -ne 1) {
        throw ("policy.json schemaVersion 未知：{0}。本版本只认识 1。" -f (Get-OptionalProperty -Object $Policy -Name 'schemaVersion' -Default '<missing>'))
    }

    # credentialsPath 是**唯一事实源**：两个脚本都从这里读，任何脚本都不得硬编码另一条路径。
    # 这里只确认它非空；展开、绝对化、残留 token 检查都在 Resolve-CredentialsPath 里做，
    # 因为那一步需要当前进程的环境变量，而结构校验不应该依赖环境。
    Assert-RequiredFields -Object $Policy -Names @('credentialsPath') -Context 'policy.json'

    # environments：三个环境一个都不能少。路由表的 environment 必须都能在这里查到开关，
    # 少一个就等于「某类路由的开关无处可配」，那种缺失只会在运行期才被发现。
    $envs = Get-OptionalProperty -Object $Policy -Name 'environments' -Default $null
    if ($null -eq $envs) { throw '配置缺少字段：policy.json.environments' }
    Assert-NoUnknownFields -Object $envs -Allowed @('dev', 'stag', 'prod') -Context 'policy.json.environments'
    foreach ($name in @('dev', 'stag', 'prod')) { Assert-BooleanField -Object $envs -Name $name -Context 'policy.json.environments' }

    Assert-BooleanField -Object $Policy -Name 'requireExplicitTarget' -Context 'policy.json'
    $defaultRoute = Get-OptionalProperty -Object $Policy -Name 'defaultRoute' -Default $null
    if ($null -ne $defaultRoute -and $defaultRoute -isnot [string]) { throw 'policy.json.defaultRoute 必须是字符串路由 id 或 null。' }

    $output = Get-OptionalProperty -Object $Policy -Name 'output' -Default $null
    if ($null -eq $output) { throw '配置缺少字段：policy.json.output' }
    Assert-NoUnknownFields -Object $output -Allowed @('defaultFormat', 'maxRows', 'maxCellChars', 'maxResultBytes') -Context 'policy.json.output'
    Assert-RequiredFields -Object $output -Names @('defaultFormat', 'maxRows', 'maxCellChars', 'maxResultBytes') -Context 'policy.json.output'
    Assert-EnumValue -Value ([string]$output.defaultFormat) -Allowed @('Table', 'Tsv', 'Json') -Context 'policy.json.output.defaultFormat'
    Assert-IntegerField -Object $output -Name 'maxRows' -Context 'policy.json.output' -Minimum 0 -Maximum 1000000
    Assert-IntegerField -Object $output -Name 'maxCellChars' -Context 'policy.json.output' -Minimum 1 -Maximum 1000000
    Assert-IntegerField -Object $output -Name 'maxResultBytes' -Context 'policy.json.output' -Minimum 1 -Maximum 1073741824

    $temp = Get-OptionalProperty -Object $Policy -Name 'temp' -Default $null
    if ($null -eq $temp) { throw '配置缺少字段：policy.json.temp' }
    Assert-NoUnknownFields -Object $temp -Allowed @('root', 'prefix', 'deleteOnExit', 'maxAgeHours') -Context 'policy.json.temp'
    Assert-RequiredFields -Object $temp -Names @('root', 'prefix', 'deleteOnExit', 'maxAgeHours') -Context 'policy.json.temp'
    Assert-BooleanField -Object $temp -Name 'deleteOnExit' -Context 'policy.json.temp'
    Assert-IntegerField -Object $temp -Name 'maxAgeHours' -Context 'policy.json.temp' -Minimum 1 -Maximum 8760

    $logging = Get-OptionalProperty -Object $Policy -Name 'logging' -Default $null
    if ($null -eq $logging) { throw '配置缺少字段：policy.json.logging' }
    Assert-NoUnknownFields -Object $logging -Allowed @('enabled', 'root', 'format', 'storeQueryText', 'retainDays') -Context 'policy.json.logging'
    Assert-RequiredFields -Object $logging -Names @('enabled', 'root', 'format', 'storeQueryText', 'retainDays') -Context 'policy.json.logging'
    Assert-BooleanField -Object $logging -Name 'enabled' -Context 'policy.json.logging'
    Assert-BooleanField -Object $logging -Name 'storeQueryText' -Context 'policy.json.logging'
    Assert-EnumValue -Value ([string]$logging.format) -Allowed @('jsonl') -Context 'policy.json.logging.format'
    Assert-IntegerField -Object $logging -Name 'retainDays' -Context 'policy.json.logging' -Minimum 1 -Maximum 3650

    $creds = Get-OptionalProperty -Object $Policy -Name 'credentials' -Default $null
    if ($null -eq $creds) { throw '配置缺少字段：policy.json.credentials' }
    Assert-NoUnknownFields -Object $creds -Allowed @('requireUserOnlyAcl', 'aclFailureIsFatal', 'allowedKeyPattern', 'highPrivilegeUserPattern', 'storageFormat') -Context 'policy.json.credentials'
    Assert-RequiredFields -Object $creds -Names @('requireUserOnlyAcl', 'aclFailureIsFatal', 'allowedKeyPattern', 'highPrivilegeUserPattern', 'storageFormat') -Context 'policy.json.credentials'
    Assert-BooleanField -Object $creds -Name 'requireUserOnlyAcl' -Context 'policy.json.credentials'
    Assert-BooleanField -Object $creds -Name 'aclFailureIsFatal' -Context 'policy.json.credentials'
    Assert-RegularExpression -Pattern ([string]$creds.allowedKeyPattern) -Context 'policy.json.credentials.allowedKeyPattern'
    Assert-RegularExpression -Pattern ([string]$creds.highPrivilegeUserPattern) -Context 'policy.json.credentials.highPrivilegeUserPattern'
    Assert-EnumValue -Value ([string]$creds.storageFormat) -Allowed @('plain', 'dpapi') -Context 'policy.json.credentials.storageFormat'

    $exec = Get-OptionalProperty -Object $Policy -Name 'exec' -Default $null
    if ($null -eq $exec) { throw '配置缺少字段：policy.json.exec' }
    Assert-NoUnknownFields -Object $exec -Allowed @('allowWrite', 'requireDigest', 'requireTransaction', 'requireBackup', 'reserved') -Context 'policy.json.exec'
    Assert-RequiredFields -Object $exec -Names @('allowWrite', 'requireDigest', 'requireTransaction', 'requireBackup', 'reserved') -Context 'policy.json.exec'
    foreach ($name in @('allowWrite', 'requireDigest', 'requireTransaction', 'requireBackup', 'reserved')) {
        Assert-BooleanField -Object $exec -Name $name -Context 'policy.json.exec'
    }
}

# ---------------------------------------------------------------------------
# routes.json 结构校验
# ---------------------------------------------------------------------------

function Assert-DbOpsRoutesSchema {
    param($Routes)

    $allowedRoot = @('schemaVersion', 'environments', 'tenants', 'engines', 'siteDatabaseMap', 'siteDatabaseMapNote', 'routes', 'nonRoutes')
    Assert-NoUnknownFields -Object $Routes -Allowed $allowedRoot -Context 'routes.json'
    Assert-RequiredFields -Object $Routes -Names @('schemaVersion', 'environments', 'tenants', 'engines', 'routes', 'nonRoutes') -Context 'routes.json'

    if ([int](Get-OptionalProperty -Object $Routes -Name 'schemaVersion' -Default -1) -ne 1) {
        throw ("routes.json schemaVersion 未知：{0}。本版本只认识 1。" -f (Get-OptionalProperty -Object $Routes -Name 'schemaVersion' -Default '<missing>'))
    }

    $environmentIds = @($Routes.environments.PSObject.Properties | ForEach-Object { $_.Name })
    if ($environmentIds.Count -eq 0) { throw 'routes.json.environments 为空。' }
    $tenantIds = @($Routes.tenants.PSObject.Properties | ForEach-Object { $_.Name })
    if ($tenantIds.Count -eq 0) { throw 'routes.json.tenants 为空。' }
    $engineIds = @($Routes.engines.PSObject.Properties | ForEach-Object { $_.Name })
    if ($engineIds.Count -eq 0) { throw 'routes.json.engines 为空。' }

    $allowedRoute = @('id', 'environment', 'tenant', 'site', 'engine', 'database', 'host', 'port',
        'credentialPrefix', 'allowWrite', 'status', 'statusReason', 'evidence')
    $staticStatuses = @('ready', 'needs-review', 'unsupported', 'disabled')

    $routeList = @($Routes.routes)
    if ($routeList.Count -eq 0) { throw 'routes.json.routes 为空——没有任何路由可用的技能不应该被加载。' }

    $seenIds = @{}
    foreach ($route in $routeList) {
        $id = [string](Get-OptionalProperty -Object $route -Name 'id' -Default '<missing>')
        $context = "routes.json.routes[$id]"

        Assert-NoUnknownFields -Object $route -Allowed $allowedRoute -Context $context
        Assert-RequiredFields -Object $route -Names @('id', 'environment', 'tenant', 'engine', 'credentialPrefix', 'allowWrite', 'status', 'statusReason', 'evidence') -Context $context
        Assert-RegexMatch -Value $id -Pattern '^[a-z][a-z0-9]*(\.[a-z0-9]+)+$' -Context "$context.id"

        if ($seenIds.ContainsKey($id)) { throw "routes.json 路由 id 重复：$id" }
        $seenIds[$id] = $true

        $environment = [string]$route.environment
        if ($environmentIds -notcontains $environment) {
            throw ("{0}.environment 取值非法：'{1}'。必须在 routes.json.environments 中声明：{2}" -f $context, $environment, ($environmentIds -join '、'))
        }
        $tenant = [string]$route.tenant
        if ($tenantIds -notcontains $tenant) {
            throw ("{0}.tenant 取值非法：'{1}'。必须在 routes.json.tenants 中声明：{2}" -f $context, $tenant, ($tenantIds -join '、'))
        }
        $engine = [string]$route.engine
        if ($engineIds -notcontains $engine) {
            throw ("{0}.engine 取值非法：'{1}'。必须在 routes.json.engines 中声明：{2}" -f $context, $engine, ($engineIds -join '、'))
        }
        $status = [string]$route.status
        Assert-EnumValue -Value $status -Allowed $staticStatuses -Context "$context.status"

        Assert-RegexMatch -Value ([string]$route.credentialPrefix) -Pattern '^[A-Z][A-Z0-9_]*_$' -Context "$context.credentialPrefix"
        Assert-BooleanField -Object $route -Name 'allowWrite' -Context $context

        # site 允许为 null（与据点无关的库：shared / logs / bi）。
        $site = Get-OptionalProperty -Object $route -Name 'site' -Default $null
        if ($null -ne $site -and $site -isnot [string]) { throw "$context.site 必须是字符串或 null。" }

        # database 只在 unsupported 时允许为 null：一个「本来能用」的路由说不清库名，
        # 只会把问题推到真正连库的那一刻。
        $database = Get-OptionalProperty -Object $route -Name 'database' -Default $null
        if ($null -eq $database) {
            if ($status -ne 'unsupported') { throw "$context.database 为 null，但 status='$status'。只有 unsupported 的路由允许省略库名。" }
        } else {
            Assert-RegexMatch -Value ([string]$database) -Pattern '^[A-Za-z0-9_]+$' -Context "$context.database"
        }

        # 这个变量**不能**叫 $host：PowerShell 的自动变量 $Host 是 AllScope + ReadOnly，
        # 而变量名大小写不敏感，因此无论在哪个作用域写 `$host = ...` 都会抛
        # "Cannot overwrite variable Host because it is read-only or constant"。
        # 它不会在语法检查或 AST 解析里暴露，只会在运行时把整条路径打死（离线测试实测到）。
        $hostName = Get-OptionalProperty -Object $route -Name 'host' -Default $null
        if ($null -ne $hostName -and ([string]::IsNullOrWhiteSpace([string]$hostName))) { throw "$context.host 不能是空字符串，未知时请写 null。" }
        $port = Get-OptionalProperty -Object $route -Name 'port' -Default $null
        if ($null -ne $port) {
            if ($port -isnot [int] -and $port -isnot [long]) { throw "$context.port 必须是整数或 null。" }
            if ([long]$port -lt 1 -or [long]$port -gt 65535) { throw "$context.port 超出范围 1..65535：$port" }
        }

        # ready 的判据之一就是「连接四要素齐全」：库名、主机、端口都能说出来。
        if ($status -eq 'ready') {
            if ($null -eq $hostName) { throw "$context 声明 status='ready'，但没有 host。证据不足时应改为 needs-review。" }
            if ($null -eq $port) { throw "$context 声明 status='ready'，但没有 port。证据不足时应改为 needs-review。" }
            if ($null -eq $database) { throw "$context 声明 status='ready'，但没有 database。" }
        }
        # 引擎与状态必须自洽：没有执行器的引擎不允许声明 ready。
        if ($engine -ne 'mysql' -and $status -eq 'ready') {
            throw "$context 的 engine='$engine'，但声明了 status='ready'。无执行器的引擎必须是 unsupported。"
        }
    }

    $allowedNonRoute = @('id', 'kind', 'status', 'reason', 'evidence')
    foreach ($nonRoute in @($Routes.nonRoutes)) {
        $id = [string](Get-OptionalProperty -Object $nonRoute -Name 'id' -Default '<missing>')
        $context = "routes.json.nonRoutes[$id]"
        Assert-NoUnknownFields -Object $nonRoute -Allowed $allowedNonRoute -Context $context
        Assert-RequiredFields -Object $nonRoute -Names @('id', 'kind', 'status', 'reason', 'evidence') -Context $context
        if ($seenIds.ContainsKey($id)) { throw "路由 id 与 nonRoutes id 冲突：$id" }
        $seenIds[$id] = $true
    }
}

function Get-DbOpsRouteWarnings {
    # 结构性错误抛异常（上面），**证据层面的矛盾只告警**。
    #
    # 理由：siteDatabaseMap 的来源是工具侧配置（tools/库存比对/inventory_diff_config.ini），
    # 不是应用真值。把它升级成强约束会在「应用改了库名而工具 ini 没同步」时把一条本来
    # 正确的路由判死。因此这里只产出「供人复核」的告警文本。
    param($Routes)

    $warnings = @()
    $map = Get-OptionalProperty -Object $Routes -Name 'siteDatabaseMap' -Default $null
    if ($null -eq $map) { return $warnings }
    $mapProperties = @($map.PSObject.Properties)

    foreach ($route in @($Routes.routes)) {
        $site = Get-OptionalProperty -Object $route -Name 'site' -Default $null
        if ($null -eq $site) { continue }
        $database = Get-OptionalProperty -Object $route -Name 'database' -Default $null
        if ($null -eq $database) { continue }
        $mapped = $null
        foreach ($property in $mapProperties) {
            if ($property.Name -eq $site) { $mapped = [string]$property.Value }
        }
        if ($null -eq $mapped) { continue }
        if ($mapped -ne [string]$database) {
            $warnings += ("据点映射冲突：路由 {0} 声明 database={1}，而 siteDatabaseMap['{2}']={3}。该路由不得被视为 ready。" -f $route.id, $database, $site, $mapped)
        }
    }
    return $warnings
}

# ---------------------------------------------------------------------------
# 凭据路径
# ---------------------------------------------------------------------------

function Resolve-CredentialsPath {
    # policy.credentialsPath 是凭据位置的**唯一事实源**。任何脚本都不得硬编码另一条路径，
    # 否则「改一处配置」就会变成「改两处」。
    param($Policy)

    $raw = [string](Get-OptionalProperty -Object $Policy -Name 'credentialsPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'policy.json.credentialsPath 为空。' }

    $expanded = Expand-PathToken $raw
    if (Test-ContainsUnresolvedToken $expanded) {
        throw ("policy.json.credentialsPath 展开后仍含未解析 token：'{0}' → '{1}'。" +
            '常见原因是写了不存在的环境变量（例如 %LOCALAPPDATA% 在某些宿主下为空）。') -f $raw, $expanded
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        throw ("policy.json.credentialsPath 展开后不是绝对路径：'{0}' → '{1}'。" +
            '凭据文件必须是绝对路径，否则它会随当前工作目录飘走。') -f $raw, $expanded
    }
    return [IO.Path]::GetFullPath($expanded)
}

# ---------------------------------------------------------------------------
# 路由查找
# ---------------------------------------------------------------------------

function Get-DbOpsRoute {
    # 精确匹配，只有两种结果：命中该 id，或返回 $null。
    #
    # **刻意不提供**前缀匹配、模糊匹配、「最接近的一个」。旧技能把 prod.lebgjm 这个
    # 未文档化的目标名和裸 PROD_ 前缀绑在一起，使用者写 prod.lebg 会静默落到别的库上。
    # 库选错不是可以容忍的失误，所以宁可让调用方拿着 $null 去报错。
    param(
        $Routes,
        [string]$Selector
    )
    if ([string]::IsNullOrWhiteSpace($Selector)) { return $null }
    $wanted = $Selector.Trim()
    foreach ($route in @($Routes.routes)) {
        if ([string]$route.id -eq $wanted) { return $route }
    }
    return $null
}

function Get-DbOpsRouteList {
    # 调用方必须写成 `$x = @(Get-DbOpsRouteList ...)`：函数返回空数组会被解包成 $null，
    # 于是 .Count 在 Set-StrictMode 2.0 下抛「找不到 Count 属性」。
    param($Routes)
    return @($Routes.routes)
}

function Get-DbOpsRouteIds {
    param($Routes)
    return @(@($Routes.routes) | ForEach-Object { [string]$_.id })
}

# ---------------------------------------------------------------------------
# 有效状态机
# ---------------------------------------------------------------------------

function Get-DbOpsRouteStatus {
    # 运行期有效状态。**静态 status 表示证据是否充分，effectiveStatus 表示现在能不能用**——
    # 两者分离，凭据变化因此不会让配置文件显得「需要更新」。
    #
    # 取首个命中，顺序即优先级：
    #   unsupported → needs-review → disabled → unconfigured → blocked → permission-warning → ready
    # blocked 必须排在 permission-warning 之前：账号是 root 时，ACL 再紧也不构成「可用于生产」。
    #
    # 本函数不读文件系统：$FileState 与 $RouteCredential 由调用方提供，因此可离线反复调用。
    param(
        $Route,
        [string]$FileState,
        $RouteCredential,
        $Policy
    )

    $staticStatus = [string]$Route.status
    if ($staticStatus -eq 'unsupported' -or [string]$Route.engine -ne 'mysql') {
        return [pscustomobject]@{ EffectiveStatus = 'unsupported'; Reason = [string]$Route.statusReason }
    }
    if ($staticStatus -eq 'needs-review') {
        return [pscustomobject]@{ EffectiveStatus = 'needs-review'; Reason = [string]$Route.statusReason }
    }

    $environmentEnabled = $true
    if ($null -ne $Policy) {
        $environments = Get-OptionalProperty -Object $Policy -Name 'environments' -Default $null
        if ($null -ne $environments) {
            $environmentEnabled = [bool](Get-OptionalProperty -Object $environments -Name ([string]$Route.environment) -Default $true)
        }
    }
    if ($staticStatus -eq 'disabled' -or -not $environmentEnabled) {
        $reason = [string]$Route.statusReason
        if (-not $environmentEnabled) { $reason = ("环境 '{0}' 在 policy.environments 中被关闭。" -f $Route.environment) }
        return [pscustomobject]@{ EffectiveStatus = 'disabled'; Reason = $reason }
    }

    if ($FileState -eq 'missing' -or $FileState -eq 'invalid') {
        $reason = if ($FileState -eq 'missing') {
            '凭据文件不存在。运行 scripts/setup-credentials.ps1（需交互式终端）后再试。'
        } else {
            '凭据文件存在但结构非法（详见 -Mode Validate 的输出）。'
        }
        return [pscustomobject]@{ EffectiveStatus = 'unconfigured'; Reason = $reason }
    }

    if ($null -eq $RouteCredential -or -not [bool]$RouteCredential.Present) {
        # 一个键都没有时也要把**期望的 4 个键名**列出来：这行诊断的用途就是让人知道
        # 往文件里补什么。只说「没配置」会让人去猜命名规则。
        return [pscustomobject]@{
            EffectiveStatus = 'unconfigured'
            Reason = ('凭据文件中没有前缀 {0} 的配置。需要 4 个键：{0}DB_HOST、{0}DB_PORT、{0}DB_USER、{0}DB_PASS。' -f $Route.credentialPrefix)
        }
    }

    $missingKeys = @(Get-OptionalProperty -Object $RouteCredential -Name 'MissingKeys' -Default @())
    if ($missingKeys.Count -gt 0) {
        # 只列键名，**绝不列值**。
        return [pscustomobject]@{
            EffectiveStatus = 'unconfigured'
            Reason = ('凭据前缀 {0} 缺少键：{1}' -f $Route.credentialPrefix, ($missingKeys -join '、'))
        }
    }

    if ([bool](Get-OptionalProperty -Object $RouteCredential -Name 'HighPrivilege' -Default $false)) {
        return [pscustomobject]@{
            EffectiveStatus = 'blocked'
            Reason = ('账号命中 policy.credentials.highPrivilegeUserPattern，拒绝使用。' +
                '本技能不提供绕过开关：请向 DBA 申请具备只读权限的独立账号。')
        }
    }

    if ([bool](Get-OptionalProperty -Object $RouteCredential -Name 'HostMismatch' -Default $false)) {
        return [pscustomobject]@{
            EffectiveStatus = 'blocked'
            Reason = ('凭据里的主机与 routes.json 声明的 host 不一致（凭据={0}，声明={1}）。' +
                '声明与配置不一致时一律拒绝连接，避免连到没打算连的库。') -f $RouteCredential.Host, $Route.host
        }
    }
    if ([bool](Get-OptionalProperty -Object $RouteCredential -Name 'PortMismatch' -Default $false)) {
        return [pscustomobject]@{
            EffectiveStatus = 'blocked'
            Reason = ('凭据里的端口与 routes.json 声明的 port 不一致（凭据={0}，声明={1}）。' -f $RouteCredential.Port, $Route.port)
        }
    }

    if ($FileState -eq 'permission-warning') {
        return [pscustomobject]@{
            EffectiveStatus = 'permission-warning'
            Reason = '凭据文件的结构与权限都可解析，但文件的 ACL 不是「仅当前用户」。在收紧权限之前不视为可用。'
        }
    }

    return [pscustomobject]@{ EffectiveStatus = 'ready'; Reason = [string]$Route.statusReason }
}
