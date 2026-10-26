# lib/exec.ps1 —— 外部命令执行的**唯一**实现。
#
# 全技能只有这一处派生外部进程。publish-chained.ps1（旧技能）曾经复制过一份
# cmd 引用与进程捕获代码，两份实现各自演化是这里最不该出现的维护成本。
#
# 依赖：common.ps1、log.ps1 必须先 dot-source。

# ---------------------------------------------------------------------------
# 命令行引用
# ---------------------------------------------------------------------------

function ConvertTo-CmdQuoted([string]$Value) {
    # cmd.exe 的双引号内仍会对 % 与 ! 做展开。会破坏命令行语义的字符直接失败，
    # 不允许静默拼出一条意思不同的命令（宁可立刻报错，也不要跑到一半才发现参数没传对）。
    if ([string]::IsNullOrEmpty($Value)) { return '""' }
    if ($Value -match '[&|<>^%"!]') {
        throw "参数含有 cmd.exe 无法安全引用的字符（& | < > ^ % `" !）：$Value"
    }
    return '"' + $Value + '"'
}

function Test-CmdQuotable([string]$Value) {
    # 预检只探测不抛错：真正的 ConvertTo-CmdQuoted 发生在用户确认之后，
    # 那时 HBuilderX 可能已经跑完 4 分钟，报错就太晚了，而且构建副作用已经发生。
    try { $null = ConvertTo-CmdQuoted $Value; return $true } catch { return $false }
}

# ---------------------------------------------------------------------------
# 输出读取
# ---------------------------------------------------------------------------

function Read-FileShared([string]$Path) {
    # 必须共享读：PDA 构建留下的 Gradle 守护进程会一直持有子进程输出文件的句柄，
    # 用 [IO.File]::ReadAllText 或 Get-Content 会直接抛「正由另一进程使用」。
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object IO.StreamReader($stream)
        return @($reader.ReadToEnd() -split "`r?`n")
    } finally { $stream.Dispose() }
}

function Get-CapturedText([string[]]$Lines) {
    if ($null -eq $Lines) { return '' }
    return (@($Lines) -join "`n")
}

function Read-FileSharedBytes([string]$Path) {
    # Read-FileShared 的字节版本。解码方式要按内容判断（见 Get-SafeText），
    # 所以必须在拿到**原始字节**之后再决定怎么解码，不能在读取层就定死 UTF-8。
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [byte[]]@() }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $memory = New-Object IO.MemoryStream
        try {
            $stream.CopyTo($memory)
            return $memory.ToArray()
        } finally { $memory.Dispose() }
    } finally { $stream.Dispose() }
}

function Get-SafeText([byte[]]$Bytes) {
    # 子进程在没有控制台的环境里设置 [Console]::OutputEncoding 会失败并退回系统 ANSI 代码页，
    # 此时中文是按 GBK 落盘的。UTF-8 解码对任意字节序列都「成功」，只会把非法序列换成 U+FFFD，
    # 所以判据是「结果里有没有替换字符」，不是「解码有没有抛错」。
    #
    # 必须容忍 $null：PowerShell 从函数返回空数组时会把它解包成「什么都没有」，调用方拿到的是
    # $null 而不是空数组，此时 GetString 会抛 ArgumentNullException。而这里是失败路径上的兜底
    # 函数，它自己再抛一次，就把「发布失败」伪装成了「解析崩溃」。
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $utf8 = [Text.Encoding]::UTF8.GetString($Bytes)
    if ($utf8.IndexOf([char]0xFFFD) -lt 0) { return $utf8 }
    return [Text.Encoding]::Default.GetString($Bytes)
}

# ---------------------------------------------------------------------------
# 进程捕获
# ---------------------------------------------------------------------------

function Invoke-CapturedProcess {
    # 把子进程输出重定向到**文件**，只等待直接子进程退出，不等待任何管道 EOF。
    #
    # 为什么不能写成 `& exe 2>&1 | ForEach-Object`：PDA 构建会留下 Gradle 守护进程
    # （默认存活约 3 小时），它继承了子进程 stdout 管道的写端；只要它不退出，管道读端
    # 就永远等不到 EOF。实测 2026-09-18：build-apk.ps1 早已退出（version.txt 14:09:59 写完、
    # 进程树无残留），publish.ps1 仍静止挂在管道读取上（CPU 仅 0.98s、无任何子进程）。
    # 最小复现：子进程派生一个存活 60 秒的孙进程后立即退出，`& child | ForEach-Object`
    # 25 秒后仍未返回。备选方案同样不可行：PowerShell 的 `*>` 对原生命令内部仍走管道；
    # `Start-Process -Wait` 实测等了 31.4 秒（等到了那个 30 秒的孙进程）；`Start-Process -PassThru`
    # 取不到退出码（实测为空），且 -ArgumentList 数组对含空格的 -File 路径加引号不可靠
    # （实测退出码 -196608）。
    #
    # 唯一可行的是 cmd 的文件重定向：重定向在派生前完成，孙进程继承到的是文件句柄
    # 而不是管道；退出码取自 cmd.exe（即直接子进程），不依赖任何管道 EOF。
    #
    # **本技能一律走这条路**，不再区分「这个命令危不危险」：输出本来就是构建结束后
    # 一次性回显（旧实现的 `@(& exe ...)` 也是先收集再输出，并没有实时流式），
    # 所以隔离不损失任何东西，却把「某天某个工具悄悄派生常驻进程」这类故障从
    # 需要判断的风险变成结构上不可能。
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$TempPrefix = 'wms-publish'
    )
    # 先回收一天前的残留输出文件：守护进程持有句柄时 finally 里的删除会失败，
    # 每次发布都会漏一个。守护进程最长存活约 3 小时，一天前的文件必然已无句柄。
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter "$TempPrefix-*.out" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $outFile = Join-Path ([IO.Path]::GetTempPath()) ('{0}-{1}.out' -f $TempPrefix, [Guid]::NewGuid().ToString('N'))
    $parts = @(ConvertTo-CmdQuoted $FilePath)
    foreach ($argument in @($Arguments)) { $parts += (ConvertTo-CmdQuoted $argument) }

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/c "{0} > {1} 2>&1"' -f ($parts -join ' '), (ConvertTo-CmdQuoted $outFile)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }

    $exitCode = $null
    $output = @()
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $process.Dispose()
        $output = @(Read-FileShared $outFile)
    } finally {
        # 常驻后代仍持有句柄时删不掉，留一个临时文件即可，不影响发布结果。
        Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Invoke-External {
    # 在 Invoke-CapturedProcess 之上加三件事：事件日志、退出码判定、失败即抛。
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$Item = 'command'
    )
    Write-Event 'command' 'started' $Item ((Split-Path -Leaf $FilePath) + ' ' + ($Arguments -join ' '))
    $started = Get-Date
    $captured = Invoke-CapturedProcess -FilePath $FilePath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    $output = @($captured.Output | ForEach-Object { [string]$_ })
    Write-CommandOutput $Item $output

    # 退出码缺失一律判失败，不得默认成功。
    if ($null -eq $captured.ExitCode) {
        Write-Event 'command' 'failed' $Item '未取得退出码'
        throw "无法取得命令退出码：$FilePath"
    }
    if ($captured.ExitCode -ne 0) {
        Write-Event 'command' 'failed' $Item "退出码 $($captured.ExitCode)"
        throw "命令失败（$($captured.ExitCode)）：$FilePath"
    }
    # 原生命令写到 stderr 的内容（Node 警告、NuGet 警告等）只作为日志记录。
    # 输出走文件重定向读回，不再经过 PowerShell 的 `2>&1`，因此旧实现里那段
    # 「局部把 $ErrorActionPreference 降为 Continue」的处理已经没有必要——
    # stderr 现在根本不会变成 NativeCommandError。
    Write-Event 'command' 'succeeded' $Item ("耗时 {0:n1}s" -f ((Get-Date) - $started).TotalSeconds)
    return [pscustomobject]@{ ExitCode = $captured.ExitCode; Output = $output }
}

function Find-Tool([string]$Configured, [string[]]$Names) {
    # 配置给了路径就以配置为准：路径写错时返回 $null 而**不**回退到 PATH 查找，
    # 否则「我把路径写错了」会退化成「悄悄用了另一个同名工具」，最难排查的一类故障。
    if (-not [string]::IsNullOrWhiteSpace($Configured)) {
        if (-not (Test-Path -LiteralPath $Configured -PathType Leaf)) { return $null }
        return [IO.Path]::GetFullPath($Configured)
    }
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    return $null
}
