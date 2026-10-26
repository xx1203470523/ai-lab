# QingLong API 核心：凭据加载 / token 缓存 / HTTP / 输出契约
# 被 ql.ps1 与其余 lib 文件点源依赖，本身不执行任何操作。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QlLibDir       = $PSScriptRoot
$script:QlBaseUrl      = $null
$script:QlClientId     = $null
$script:QlClientSecret = $null
$script:QlEnvLoaded    = $false

function Get-QlSkillRoot {
    if ([string]::IsNullOrEmpty($script:QlLibDir)) { throw '无法定位 qinglong skill 根目录' }
    return (Resolve-Path (Join-Path $script:QlLibDir '..\..')).Path
}

# StrictMode 2.0 禁止访问不存在的属性，可选字段一律经此取值
function Get-QlProp {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

# 把凭据从任意文本中抹掉，避免异常消息把 secret 带进 stdout / 日志
function Protect-QlText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $out = $Text
    foreach ($s in @($script:QlClientSecret, $script:QlClientId)) {
        if (-not [string]::IsNullOrEmpty($s) -and $s.Length -ge 8) {
            $out = $out.Replace($s, '***')
        }
    }
    return $out
}

function Import-QlEnv {
    if ($script:QlEnvLoaded) { return }
    $path = Join-Path (Get-QlSkillRoot) '.env'
    if (-not (Test-Path -LiteralPath $path)) { throw "缺少凭据文件：$path" }

    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $k = $t.Substring(0, $i).Trim()
        $v = $t.Substring($i + 1).Trim()
        if ($v.Length -ge 2) {
            $ql = $v.Substring(0, 1); $qr = $v.Substring($v.Length - 1, 1)
            if (($ql -eq '"' -and $qr -eq '"') -or ($ql -eq "'" -and $qr -eq "'")) {
                $v = $v.Substring(1, $v.Length - 2)
            }
        }
        switch ($k) {
            'QL_BASE_URL'      { $script:QlBaseUrl      = $v.TrimEnd('/') }
            'QL_CLIENT_ID'     { $script:QlClientId     = $v }
            'QL_CLIENT_SECRET' { $script:QlClientSecret = $v }
        }
    }

    if ([string]::IsNullOrEmpty($script:QlBaseUrl))      { throw '.env 缺少 QL_BASE_URL' }
    if ([string]::IsNullOrEmpty($script:QlClientId))     { throw '.env 缺少 QL_CLIENT_ID' }
    if ([string]::IsNullOrEmpty($script:QlClientSecret)) { throw '.env 缺少 QL_CLIENT_SECRET' }
    $script:QlEnvLoaded = $true
}

function Get-QlTokenPath { return (Join-Path (Get-QlSkillRoot) 'state\token.json') }

function Read-QlTokenCache {
    $p = Get-QlTokenPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $o = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { return $null }
    if ($null -eq (Get-QlProp -Object $o -Name 'token') -or $null -eq (Get-QlProp -Object $o -Name 'expiration')) { return $null }
    return $o
}

function Save-QlTokenCache {
    param([string]$Token, $Expiration)
    $obj = [ordered]@{
        token      = $Token
        expiration = [int64]$Expiration
        fetchedAt  = (Get-Date).ToString('o')
    }
    $dir = Join-Path (Get-QlSkillRoot) 'state'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Get-QlTokenPath), ($obj | ConvertTo-Json), $enc)
}

# 向 /open/auth/token 换取 token；URI 内含 secret，异常必须脱敏
function New-QlToken {
    Import-QlEnv
    $cid = [uri]::EscapeDataString($script:QlClientId)
    $sec = [uri]::EscapeDataString($script:QlClientSecret)
    $uri = "$($script:QlBaseUrl)/open/auth/token?client_id=$cid&client_secret=$sec"
    try {
        $r = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 30
    } catch {
        throw ("换取 OpenAPI token 失败：{0}" -f (Protect-QlText $_.Exception.Message))
    }
    $tk = Get-QlProp -Object $r.data -Name 'token'
    if ($r.code -ne 200 -or $null -eq $tk) {
        throw ("换取 OpenAPI token 被拒绝：{0}" -f (Protect-QlText (Get-QlProp -Object $r -Name 'message' -Default '')))
    }
    Save-QlTokenCache -Token $tk -Expiration (Get-QlProp -Object $r.data -Name 'expiration' -Default 0)
    return $r.data
}

function Get-QlToken {
    Import-QlEnv
    $c = Read-QlTokenCache
    if ($null -ne $c) {
        $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64](Get-QlProp -Object $c -Name 'expiration')).LocalDateTime
        if ($exp -gt (Get-Date).AddDays(2)) { return (Get-QlProp -Object $c -Name 'token') }
    }
    return (Get-QlProp -Object (New-QlToken) -Name 'token')
}

# 从 WebException 响应体里取 QingLong 的 {code,message}
function Get-QlErrorText {
    param($ErrorRecord)
    $msg = Protect-QlText $ErrorRecord.Exception.Message
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($null -ne $resp) {
            $stream = $resp.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Close()
                if (-not [string]::IsNullOrWhiteSpace($body)) {
                    try {
                        $j = $body | ConvertFrom-Json
                        if ($null -ne $j.message) { $msg = Protect-QlText $j.message }
                    } catch { $msg = Protect-QlText $body }
                }
            }
        }
    } catch { }
    return $msg
}

# 必须用 -InputObject：走管道会把数组展开，@(31) 会序列化成 31 而不是 [31]。
# 青龙的 crons/disable、crons/enable、crons/run、DELETE crons 都要求裸数组体，
# 传 {ids:[...]} 会被 Joi 拒绝为 'value must be an array'。
function ConvertTo-QlJson {
    param($Value)
    if ($Value -is [string]) { return $Value }   # 已是 JSON 文本，原样透传
    return (ConvertTo-Json -InputObject $Value -Depth 10 -Compress)
}

# 统一走 /open 前缀；401 时自动重换 token 并重试一次
function Invoke-QlApi {
    param(
        [string]$Method = 'GET',
        [string]$Path,
        $Body = $null,
        [switch]$Retried
    )
    $token = Get-QlToken
    $uri = "$($script:QlBaseUrl)/open/$($Path.TrimStart('/'))"
    $params = @{
        Uri        = $uri
        Method     = $Method
        Headers    = @{ Authorization = "Bearer $token" }
        TimeoutSec = 60
    }
    if ($null -ne $Body) {
        # 必须发字节而不是字符串：PS 5.1 的 Invoke-RestMethod 对 string body
        # 按 ISO-8859-1 编码，中文会逐字变成 '?'（任务名、脚本内容都会被毁）。
        $json = ConvertTo-QlJson -Value $Body
        $params['Body']        = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    try {
        return Invoke-RestMethod @params
    } catch {
        $status = 0
        if ($null -ne $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 401 -and -not $Retried) {
            New-QlToken | Out-Null
            return Invoke-QlApi -Method $Method -Path $Path -Body $Body -Retried
        }
        throw (Get-QlErrorText $_)
    }
}

# ---- 输出契约 ----------------------------------------------------------
# 成功 / 失败共用一个信封，AI 只解析这一个结构。

$script:QlEnvelope = $null

function Initialize-QlEnvelope {
    param([string]$Verb, [int]$Level)
    $script:QlEnvelope = [ordered]@{
        verb     = $Verb
        level    = $Level
        ok       = $false
        status   = 'init'
        planned  = $null
        actual   = $null
        diff     = @()
        result   = $null
        verified = $false
        warnings = @()
        errors   = @()
    }
}

function Add-QlWarning { param([string]$Message)
    $script:QlEnvelope.warnings += (Protect-QlText $Message)
}

function Add-QlError { param([string]$Message)
    $script:QlEnvelope.errors += (Protect-QlText $Message)
}

function Set-QlEnvelope { param([string]$Name, $Value)
    $script:QlEnvelope[$Name] = $Value
}

function Write-QlEnvelope {
    param([string]$Status, [bool]$Ok, [bool]$Verified = $false)
    if ($null -eq $script:QlEnvelope) { return }
    $script:QlEnvelope.status   = $Status
    $script:QlEnvelope.ok       = $Ok
    $script:QlEnvelope.verified = $Verified
    $enc = New-Object System.Text.UTF8Encoding $false
    [Console]::OutputEncoding = $enc
    Write-Output ($script:QlEnvelope | ConvertTo-Json -Depth 8)
}
