# lib/common.ps1 —— 通用机制：路径解析与安全、配置断言、版本号解析。
#
# 进这个文件的门槛：**至少两个脚本要用**。只被一个脚本用的函数留在那个脚本里，
# 不要往上提（Phase 2 复审定的边界）。
#
# 本文件不得调用 log.ps1 / exec.ps1 的任何函数，不得写任何文件，也不得派生进程。
# 只读文件系统（读 JSON、统计目录、看时间戳）是允许的——读不会改变什么，
# 而且这些判断本来就是"同一份事实只实现一次"的对象。它是依赖最少的一层，
# 因此在任何脚本里都最先 dot-source。

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

function Get-DesktopPath {
    return [Environment]::GetFolderPath('Desktop')
}

function Expand-PathToken([string]$Path) {
    # 配置里允许两个 token，避免把用户名写进 JSON：
    #   {desktop} -> 当前用户桌面
    #   ~         -> 当前用户主目录
    # 只替换开头的 token，不做任意位置替换——路径中间出现 {desktop} 一定是写错了，
    # 让它在 Test-Path 那里失败，而不是静默拼出一个别的目录。
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $expanded = $Path.Replace('{desktop}', (Get-DesktopPath))
    if ($expanded.StartsWith('~')) {
        $rest = $expanded.Substring(1).TrimStart('\', '/')
        if ([string]::IsNullOrWhiteSpace($rest)) { $expanded = $env:USERPROFILE }
        else { $expanded = Join-Path $env:USERPROFILE $rest }
    }
    return $expanded
}

function Resolve-FullPath([string]$Path, [string]$Base) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $expanded = Expand-PathToken $Path
    $candidate = if ([IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $Base $expanded }
    return [IO.Path]::GetFullPath($candidate)
}

function Test-Within([string]$Path, [string]$Root) {
    # 相等也算「在之内」。做删除目标判定时用 Test-StrictlyWithin。
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $p = ([IO.Path]::GetFullPath($Path)).TrimEnd('\') + '\'
    $r = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
    return $p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)
}

function Test-StrictlyWithin([string]$Path, [string]$Root) {
    # 递归删除的目标必须严格在根**之下**：允许相等就等于允许把根自己删掉。
    if (-not (Test-Within $Path $Root)) { return $false }
    $p = ([IO.Path]::GetFullPath($Path)).TrimEnd('\')
    $r = ([IO.Path]::GetFullPath($Root)).TrimEnd('\')
    return (-not $p.Equals($r, [StringComparison]::OrdinalIgnoreCase))
}

function Assert-SafePathSegment([string]$Value, [string]$Context) {
    # 项目 id 会被直接拼成落盘子目录名。它必须是单个普通路径段，否则一个写错的
    # id（"../.." 或 "a/b"）就能把归档写到输出根之外。
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Context 不能为空。" }
    if ($Value -ne [IO.Path]::GetFileName($Value)) { throw "$Context 必须是单个路径段，不能含目录分隔符：$Value" }
    if ($Value -eq '.' -or $Value -eq '..') { throw "$Context 不能是 . 或 ..：$Value" }
    if ($Value -match '[<>:"/\\|?*]') { throw "$Context 含非法文件名字符：$Value" }
}

# ---------------------------------------------------------------------------
# 配置取值与断言
# ---------------------------------------------------------------------------

function Get-OptionalProperty($Object, [string]$Name, $Default) {
    # Set-StrictMode 2.0 下解引用不存在的属性会抛裸 PropertyNotFoundException，
    # 绕过可读的配置报错变成一句 .NET 消息。所有可选字段都要走这里。
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

function Split-List([string[]]$Values) {
    # `powershell -File script.ps1 -Ids admin,report` 不会解析逗号：整串会作为**一个**元素
    # 传进来。所有跨进程传递的列表参数都要过这里，否则字面量写法会静默选中零个项。
    #
    # **调用方必须写成 `$x = @(Split-List $y)`。** 无输入时本函数返回空数组，而 PowerShell
    # 从函数返回空数组会把它解包成「什么都没有」，调用方拿到的是 $null，于是 `$x.Count`
    # 在 Set-StrictMode 2.0 下抛「The property 'Count' cannot be found on this object」
    # （实测 2026-09-23，publish.ps1 第 256 行）。这不是本函数能自己修掉的：
    # 唯一能阻止解包的写法是 `return ,@()`，而那会让调用方拿到「一个空数组的数组」，
    # .Count 变成 1，错得更隐蔽。
    return @($Values | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Assert-RequiredFields($Object, [string[]]$Names, [string]$Context) {
    foreach ($name in @($Names)) {
        $property = if ($null -eq $Object) { $null } else { $Object.PSObject.Properties[$name] }
        if ($null -eq $property -or $null -eq $property.Value) { throw "配置缺少字段：$Context.$name" }
        $value = $property.Value
        # 集合必须单独判：**空集合**才算缺失。
        #
        # 不能沿用「[string] 强转后判空白」——Windows PowerShell 5.1 里 `[string]` 一个
        # PSCustomObject 得到的是**空字符串**（`@{id=admin; ...}` 是格式化输出，不是强转结果）。
        # 于是 3 个元素的数组强转出来是 `"" + " " + "" + " " + ""`，即两个空格，被判成空白，
        # 「字段存在且有 3 个元素」被误报为「缺少字段」。四个生产者的配置校验全走这条路径，
        # 结果是 dotnet/web/pdaweb/pda **没有一个能启动**（2026-09-23 实跑复现：
        # `配置缺少字段：projects/dotnet.json.projects`，而该字段实际有 3 个元素）。
        #
        # 字符串本身也是 IEnumerable，所以必须显式排除，否则 `[string]` 那段永远走不到。
        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            if (@($value).Count -eq 0) { throw "配置缺少字段：$Context.$name" }
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "配置缺少字段：$Context.$name" }
    }
}

function Assert-NoUnknownFields($Object, [string[]]$Allowed, [string]$Context) {
    # 这是「不维护 JSON Schema」之后补回来的唯一实质能力：拼错的字段名必须报错，
    # 而不是被静默忽略。少了它，`framwork` 这种错字会让配置看起来生效其实没有。
    if ($null -eq $Object) { return }
    $unknown = @($Object.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $Allowed -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw ("配置存在未知字段（多半是拼写错误）：{0} → {1}。允许的字段：{2}" -f $Context, ($unknown -join '、'), ($Allowed -join '、'))
    }
}

# ---------------------------------------------------------------------------
# 版本号
# ---------------------------------------------------------------------------

function Get-VersionTuple([string]$Text, [string]$Pattern) {
    $match = [regex]::Match($Text, $Pattern)
    if (-not $match.Success -or $match.Groups.Count -lt 5) { return $null }
    try {
        return [int64[]]@($match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value, $match.Groups[4].Value)
    } catch { return $null }
}

function Format-Version([int64[]]$Tuple, [string]$Prefix) {
    return '{0}{1}.{2}.{3}.{4}' -f $Prefix, $Tuple[0], $Tuple[1], $Tuple[2], $Tuple[3]
}

function Get-NextVersionTuple([int64[]]$Tuple) {
    # 递增规则只有这一条实现：末段 +1，某段超过 9 归零并向左进位。
    # **刻意不做成配置项**——把递增策略配置化等于把规则引擎塞进 JSON，
    # 而且真实需求只有这一种。规则文本见 rules/publish.rules.md。
    if ($null -eq $Tuple -or $Tuple.Count -lt 4) { return $null }
    if ($Tuple[3] -eq [int64]::MaxValue) { throw '版本号最后一段溢出。' }
    $parts = @([int64]$Tuple[0], [int64]$Tuple[1], [int64]$Tuple[2], [int64]($Tuple[3] + 1))
    for ($i = 3; $i -gt 0; $i--) {
        if ($parts[$i] -gt 9) { $parts[$i] = 0; $parts[$i - 1]++ }
    }
    return [int64[]]$parts
}

# ---------------------------------------------------------------------------
# 发布包命名
# ---------------------------------------------------------------------------

function Resolve-ArchiveName([string]$Pattern, [string]$Prefix, [string]$VersionLabel, [string]$Duplicate) {
    $template = $Pattern
    if ([string]::IsNullOrWhiteSpace($template)) { $template = '{prefix}_{version}{duplicate}.zip' }
    $name = $template.Replace('{prefix}', $Prefix).Replace('{version}', $VersionLabel).Replace('{duplicate}', $Duplicate)
    # 模板里剩下的 {xxx} 一定是写错或已废弃的占位符（例如早期的 {suffix}、聚合模型时期的 {family}）。
    # 不检的话它会安静地变成文件名的一部分，直到有人打开压缩包才发现。
    $leftover = [regex]::Match($name, '\{[A-Za-z]+\}')
    if ($leftover.Success) { throw "archiveNaming.pattern 存在未知占位符 $($leftover.Value)：$template" }
    # 结果必须是单个路径段：prefix 写错成 '../x' 就能把发布包写到落盘目录之外。
    Assert-SafePathSegment $name '发布包名'
    return $name
}

function Resolve-ArtifactName {
    # 「同版本重复发布」的唯一实现。预检报告与 package.ps1 落盘都调它，
    # 因此**展示给用户的包名与实际落盘的包名不可能不一致**。
    #
    #   overwrite：始终用基础名，直接覆盖同版本包。
    #   suffix   ：基础名不存在就用基础名；已存在则加批次时间戳（_yyyyMMddHH）。
    #              同一小时内再次重复发布会得到同一个戳，自然覆盖那个文件，
    #              不产生 _1、_2。
    # 任何情况下都**不会**因为"同版本已存在"而递增版本号：正常版本递增与
    # 指定同版本重发是两件事，版本号只由 publish.ps1 的版本解析决定。
    param(
        [string]$Pattern,
        [string]$Prefix,
        [string]$VersionLabel,
        [string]$ItemDir,
        [string]$DuplicateMode,
        [string]$DuplicateSuffix
    )
    $baseName = Resolve-ArchiveName $Pattern $Prefix $VersionLabel ''
    if ($DuplicateMode -ne 'suffix') {
        return [pscustomobject]@{ Name = $baseName; BaseName = $baseName; IsDuplicate = $false }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ItemDir $baseName) -PathType Leaf)) {
        return [pscustomobject]@{ Name = $baseName; BaseName = $baseName; IsDuplicate = $false }
    }
    return [pscustomobject]@{
        Name      = (Resolve-ArchiveName $Pattern $Prefix $VersionLabel $DuplicateSuffix)
        BaseName  = $baseName
        IsDuplicate = $true
    }
}

# ---------------------------------------------------------------------------
# 文件读取
# ---------------------------------------------------------------------------

function Read-JsonFile([string]$Path) {
    # 必须用 [IO.File]::ReadAllText：Get-Content 返回的字符串带 PSPath/PSDrive/PSProvider
    # 装饰属性，一旦进入报告对象，ConvertTo-Json 会连带遍历整个 provider 对象图并指数膨胀
    # （实测 depth=6 已 23MB，depth=12 吃满数 GB 并卡死）。ReadAllText 返回纯字符串。
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Write-JsonFile([string]$Path, $Object, [int]$Depth = 8) {
    # 不写 BOM：JSON 消费者（含本技能的读回路径）按 UTF-8 解码，BOM 只会变成
    # 一个前导 U+FEFF 字符，让 ConvertFrom-Json 在别的工具里失败。
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $text = $Object | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-FileHashValue([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SourceStats([string]$SourceDirectory) {
    # 递归取文件清单与总量。空目录在这里**不抛错**——单独执行 package.ps1 时
    # 某个项目还没构建过，应该报「跳过 + 原因」，不能把整轮打包崩掉。
    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        return [pscustomobject]@{ Exists = $false; Count = 0; Bytes = 0; Files = @(); Newest = $null }
    }
    $files = @(Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ Exists = $true; Count = 0; Bytes = 0; Files = @(); Newest = $null }
    }
    $newest = ($files | Measure-Object -Property LastWriteTime -Maximum).Maximum
    return [pscustomobject]@{ Exists = $true; Count = $files.Count; Bytes = ($files | Measure-Object -Property Length -Sum).Sum; Files = $files; Newest = $newest }
}

function Assert-ExportFreshness([string]$ExportDir, [datetime]$BuildStart, [string]$Label) {
    # 拦截「工具没有真正导出、却返回 0、复用上一轮资源」这个已记录故障的**唯一**手段。
    # 版本号比对拦不住它：源 manifest.json 被回退过时，陈旧复用与真导出产出的版本标记
    # 可以完全相同（2026-09-18 实测：manifest 1.4.1.9、version.txt 1.4.2.0、导出树 1.4.2.0，
    # 预测值也是 1.4.2.0）。判据只能是导出树**递归文件**的写入时间最大值。
    # $Label 是调用方给的产物名（「PDA 导出」/「H5 导出」）：两个导出树共用这一个函数，
    # 写死一个名字会让另一条链失败时报出与之无关的措辞，恰好在排障时把人引向错误方向。
    if (-not (Test-Path -LiteralPath $ExportDir -PathType Container)) { throw "$Label 目录不存在：$ExportDir" }
    $newest = Get-TreeNewestWriteTime $ExportDir
    if ($null -eq $newest) { throw "$Label 目录为空：$ExportDir" }
    if ($newest -lt $BuildStart) {
        $message = '{0} 未刷新：{1} 内最新文件时间为 {2:o}，早于本次构建开始时间 {3:o}。' +
            '说明该工具没有真正重新导出（常见原因：HBuilderX 未运行或导出失败但仍返回 0），' +
            '本轮资源是上一轮的陈旧副本。版本号看似正确也不能作为证据。'
        throw ($message -f $Label, $ExportDir, $newest, $BuildStart)
    }
    return $newest
}

function Get-TreeNewestWriteTime([string]$Directory) {
    # 陈旧导出防护的判据：**递归文件的 LastWriteTime 最大值**。
    # 不得改用目录自身的 mtime——原地改写文件不会移动目录 mtime。
    $stats = Get-SourceStats $Directory
    if (-not $stats.Exists) { return $null }
    return $stats.Newest
}
