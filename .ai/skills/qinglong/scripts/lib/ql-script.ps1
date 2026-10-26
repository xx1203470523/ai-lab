# QingLong 脚本层：目录树 / 读取 / 新建 / 覆盖
# 依赖 ql-api.ps1
#
# 端点陷阱（源码确认）：
#   GET /scripts/:file  不跨 '/' 匹配，多段路径直接 404
#   GET /scripts?path=  对文件调用 fs.readdir 抛 ENOTDIR -> 500；必须传目录
#   GET /scripts?path=  只返回单层，children 恒为 []
#   GET /scripts/detail 是正确的读内容端点；路径越界返回 {code:200,data:''}
# 越界不报错但返回空串，所以读取必须判空，不能把空串当成功。

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Split-QlScriptKey {
    param([string]$Key)
    $dir = ''; $file = $Key
    $i = $Key.LastIndexOf('/')
    if ($i -ge 0) { $dir = $Key.Substring(0, $i); $file = $Key.Substring($i + 1) }
    return [ordered]@{ dir = $dir; file = $file }
}

# 递归展开完整脚本树（平台只给单层，自己走）
function Get-QlScriptTree {
    param([string]$Path = '')
    $out = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    while ($stack.Count -gt 0) {
        $p = [string]$stack.Pop()
        if (-not $seen.Add($p)) { continue }
        $r = Invoke-QlApi -Path ("scripts?path=" + [uri]::EscapeDataString($p))
        if ($r.code -ne 200) { throw "读取脚本目录失败：$p -> $($r.message)" }
        foreach ($e in @($r.data)) {
            # 目录节点没有 size 字段，StrictMode 2.0 下裸访问属性会抛错
            $eType = [string](Get-QlProp -Object $e -Name 'type' -Default '')
            $eKey  = [string](Get-QlProp -Object $e -Name 'key'  -Default '')
            $out.Add([ordered]@{
                key    = $eKey
                title  = [string](Get-QlProp -Object $e -Name 'title' -Default '')
                type   = $eType
                size   = (Get-QlProp -Object $e -Name 'size' -Default 0)
                parent = [string](Get-QlProp -Object $e -Name 'parent' -Default '')
            })
            if ($eType -eq 'directory') { $stack.Push($eKey) }
        }
    }
    return $out.ToArray()
}

function Get-QlScriptContent {
    param([string]$Key)
    Import-QlEnv
    $s = Split-QlScriptKey -Key $Key
    $path = "scripts/detail?file=" + [uri]::EscapeDataString($s.file) + "&path=" + [uri]::EscapeDataString($s.dir)
    $r = Invoke-QlApi -Path $path
    if ($r.code -ne 200) { throw "读取脚本失败：$Key -> $($r.message)" }
    $c = $null
    if ($r.data -is [string]) { $c = [string]$r.data }
    else { $c = [string](Get-QlProp -Object $r.data -Name 'content' -Default '') }
    if ([string]::IsNullOrEmpty($c)) {
        throw "脚本内容为空，或路径越界：$Key（平台对越界路径返回空串而不报错）"
    }
    return $c
}

# 覆盖已有脚本内容；不新建
function Set-QlScriptContent {
    param([string]$Key, [string]$Content)
    $s = Split-QlScriptKey -Key $Key
    $body = [ordered]@{ filename = $s.file; content = $Content }
    if ($s.dir -ne '') { $body['path'] = $s.dir }
    $r = Invoke-QlApi -Method Put -Path 'scripts' -Body $body
    if ($r.code -ne 200) { throw "覆盖脚本失败：$Key -> $($r.message)" }
    return $r
}

# 存在性判定必须走目录列举：GET scripts/detail 对不存在的文件返回空串而不是错误，
# 无法区分"空文件"和"不存在"。
function Test-QlScriptExists {
    param([string]$Key)
    $s = Split-QlScriptKey -Key $Key
    $r = Invoke-QlApi -Path ("scripts?path=" + [uri]::EscapeDataString($s.dir))
    if ($r.code -ne 200) { throw "读取脚本目录失败：$($s.dir) -> $($r.message)" }
    foreach ($e in @($r.data)) {
        if ([string](Get-QlProp -Object $e -Name 'type' -Default '') -ne 'file') { continue }
        if ([string](Get-QlProp -Object $e -Name 'key' -Default '') -eq $Key) { return $true }
    }
    return $false
}

# 删除脚本；平台对不存在的文件同样返回 200，调用方必须回读校验
function Remove-QlScript {
    param([string]$Key)
    $s = Split-QlScriptKey -Key $Key
    $r = Invoke-QlApi -Method Delete -Path 'scripts' -Body ([ordered]@{ filename = $s.file; path = $s.dir })
    if ($r.code -ne 200) { throw "删除脚本失败：$Key -> $($r.message)" }
    return $r
}

# 新建脚本；已存在时平台会报错，不覆盖
function New-QlScript {
    param([string]$Key, [string]$Content, [string]$Dir = $null)
    $s = Split-QlScriptKey -Key $Key
    $target = $s.dir
    if (-not [string]::IsNullOrEmpty($Dir)) { $target = $Dir }
    $body = [ordered]@{ filename = $s.file; path = $target; content = $Content }
    $r = Invoke-QlApi -Method Post -Path 'scripts' -Body $body
    if ($r.code -ne 200) { throw "新建脚本失败：$Key -> $($r.message)" }
    return $r
}
