# lib/output.ps1 —— 统一结果契约、表格/TSV 渲染、脱敏断言。
#
# 职责边界
#   把脚本内部的结构化结果变成「给人和给机器看的东西」，并保证出去的东西里没有秘密。
#
# 明确不做
#   不查库、不读配置、不算状态、不写文件。
#
# 依赖：common.ps1 与 log.ps1 必须先 dot-source。

# ---------------------------------------------------------------------------
# 结果信封
# ---------------------------------------------------------------------------

function New-ResultEnvelope {
    # 契约字段固定，缺的字段也要存在（值为 $null / @()），这样消费者不必区分
    # 「没有这个字段」和「这个字段是空的」——后者是配置演化时最容易踩的坑。
    #
    # 路由、库名、用户名、行数、耗时、截断状态**必须来自脚本实际返回**：
    # 调用方（AI）可以补 EntityEvidence 与 QueryScope，但不得自行填这些字段。
    param(
        [string]$Mode,
        [string]$Route,
        [string]$Database,
        [bool]$Success
    )

    return [ordered]@{
        Success           = $Success
        Mode              = $Mode
        Route             = $Route
        Database          = $Database
        ReadOnlyUser      = $null
        RowsReturned      = 0
        Limit             = $null
        LimitReached      = $false
        PossiblyTruncated = $false
        ElapsedMs         = $null
        Columns           = @()
        Rows              = @()
        ResultFile        = $null
        Warnings          = @()
        ErrorType         = $null
        ErrorMessage      = $null
        Remediation       = $null
        RunId             = (Get-RunId)
        Timestamp         = (Get-Date).ToString('o')
    }
}

function ConvertTo-Tsv {
    param(
        [string[]]$Columns,
        $Rows
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add((@($Columns) | ForEach-Object { ConvertTo-TsvCell $_ }) -join "`t")
    foreach ($row in @($Rows)) {
        $cells = @($row) | ForEach-Object { ConvertTo-TsvCell $_ }
        $lines.Add(($cells -join "`t"))
    }
    return ($lines -join "`r`n")
}

function ConvertTo-TsvCell {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ')
}

function Format-TableText {
    # 定宽表格。$Rows 是「字符串数组的数组」，不做对象属性反射——
    # 反射会把 PSCustomObject 的 provider 属性也带出来，正是我们要避免的那类膨胀。
    param(
        [string[]]$Columns,
        $Rows,
        [int]$MaxCellChars = 200
    )

    $columns = @($Columns)
    $rows = @($Rows)
    $widths = @()
    for ($i = 0; $i -lt $columns.Count; $i++) { $widths += $columns[$i].Length }

    $cleanRows = @()
    foreach ($row in $rows) {
        $cells = @()
        for ($i = 0; $i -lt $columns.Count; $i++) {
            $raw = ''
            if ($i -lt @($row).Count) {
                if ($null -ne @($row)[$i]) { $raw = [string]@($row)[$i] }
            }
            $raw = $raw.Replace("`r", ' ').Replace("`n", ' ')
            if ($MaxCellChars -gt 0 -and $raw.Length -gt $MaxCellChars) {
                $raw = $raw.Substring(0, $MaxCellChars - 1) + '…'
            }
            $cells += $raw
            if ($raw.Length -gt $widths[$i]) { $widths[$i] = $raw.Length }
        }
        $cleanRows += , $cells
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $headerCells = @()
    for ($i = 0; $i -lt $columns.Count; $i++) { $headerCells += $columns[$i].PadRight($widths[$i]) }
    $lines.Add((($headerCells -join '  ').TrimEnd()))
    $separator = @()
    for ($i = 0; $i -lt $columns.Count; $i++) { $separator += ('-' * $widths[$i]) }
    $lines.Add((($separator -join '  ').TrimEnd()))

    foreach ($cells in $cleanRows) {
        $padded = @()
        for ($i = 0; $i -lt $columns.Count; $i++) { $padded += $cells[$i].PadRight($widths[$i]) }
        $lines.Add((($padded -join '  ').TrimEnd()))
    }

    return @($lines)
}

function Format-RouteListText {
    # -ListTargets 的**首要目标是回答「这条路由为什么不可用」**，不是列出名字。
    # 因此每行必须带状态与依据；理由单独缩进一行，避免把表格撑到读不了。
    param($RouteStates)

    $columns = @('Route', 'Env', 'Tenant', 'Site', 'Engine', 'Target', 'Status')
    $rows = @()
    $reasons = @()

    foreach ($item in @($RouteStates)) {
        $rows += , @(
            [string]$item.Id,
            [string]$item.Environment,
            [string]$item.Tenant,
            $(if ($null -eq $item.Site) { '-' } else { [string]$item.Site }),
            [string]$item.Engine,
            [string]$item.Target,
            [string]$item.Status
        )
        $reasons += ('{0} ← {1}' -f (('{0,-14}' -f $item.Id).TrimEnd()), [string]$item.Reason)
    }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Format-TableText -Columns $columns -Rows $rows)) { $lines.Add($line) }
    $lines.Add('')
    $lines.Add('依据：')
    foreach ($reason in $reasons) { $lines.Add('  ' + $reason) }
    return @($lines)
}

function Get-RedactedRouteInfo {
    # 展示用的连接信息：库名与 host:port 是诊断信息，可以显示；账号只显示首字母。
    # 完整连接串与口令永不出现。
    param($Route)

    # 见 config.ps1 的同名注释：$host 与自动变量 $Host 冲突（AllScope + ReadOnly），必须换名。
    $hostName = Get-OptionalProperty -Object $Route -Name 'host' -Default $null
    $port = Get-OptionalProperty -Object $Route -Name 'port' -Default $null
    $database = Get-OptionalProperty -Object $Route -Name 'database' -Default $null

    $databaseText = if ($null -eq $database) { '?' } else { [string]$database }
    $hostText = if ($null -eq $hostName) { '?' } else { [string]$hostName }
    $portText = if ($null -eq $port) { '?' } else { [string]$port }
    return ('{0}@{1}:{2}' -f $databaseText, $hostText, $portText)
}

function Format-DbOpsResult {
    param(
        $Envelope,
        [string]$Format
    )

    if ($Format -eq 'Json') {
        # -InputObject 阻止 ConvertTo-Json 把单元素数组展开成裸对象。
        # 少了它，只有一条 Columns 的结果和只有一行的结果形状会不一样。
        return (ConvertTo-Json -InputObject $Envelope -Depth 12)
    }

    $columns = @(Get-OptionalProperty -Object $Envelope -Name 'Columns' -Default @())
    $rows = @(Get-OptionalProperty -Object $Envelope -Name 'Rows' -Default @())
    if ($columns.Count -eq 0) { return '' }
    if ($Format -eq 'Tsv') { return (ConvertTo-Tsv -Columns $columns -Rows $rows) }
    return ((Format-TableText -Columns $columns -Rows $rows) -join "`r`n")
}

# ---------------------------------------------------------------------------
# 脱敏断言
# ---------------------------------------------------------------------------

function Assert-NoSecretInOutput {
    # 「输出里没有凭据值」必须是一条**可执行的检查**，而不是一句写在文档里的承诺。
    # 所有拿得到凭据值的路径（Validate 的凭据展开、setup 的写入回读）都要过这一关。
    #
    # 长度 < 8 的值不参与判定：短串会在正常文本里随处误命中（见 Protect-SecretText 的同一理由）。
    param(
        [string]$Text,
        [string[]]$Secrets
    )

    if ([string]::IsNullOrEmpty($Text)) { return }
    foreach ($secret in @($Secrets)) {
        if ([string]::IsNullOrEmpty($secret)) { continue }
        if ($secret.Length -lt 8) { continue }
        if ($Text.Contains($secret)) {
            # **异常消息里也不能带上那个值**：否则断言自己变成了泄漏点。
            $message = ('输出内容里出现了凭据值（长度 {0}，值不予回显）。这属于必须修的缺陷，不是可以忽略的告警。' -f $secret.Length)
            throw $message
        }
    }
}

function Get-OutputSecrets {
    # 从凭据状态对象里取出所有需要参与脱敏判定的值。
    param($CredentialValues)

    if ($null -eq $CredentialValues) { return @() }
    $secrets = @()
    if ($CredentialValues -is [hashtable]) {
        foreach ($key in @($CredentialValues.Keys)) {
            if ($key -match '(?i)_(PASS|PASSWORD)$') { $secrets += [string]$CredentialValues[$key] }
        }
    }
    return @($secrets)
}
