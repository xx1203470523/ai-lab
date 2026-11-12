# lib/mysql.ps1 —— MySQL 执行层（JDBC 优先，mysql CLI 兜底）。
#
# 职责边界
#   把一个已解析好的连接配置 + 一段 SQL 变成结构化结果 {Columns, Rows, ...}。
#   不决定路由、不读配置、不判断只读性、不打印、不写日志。
#
# 明确不做
#   不把密码放进命令行参数。JDBC 模式通过临时进程环境变量传递；
#   CLI 模式通过 MYSQL_PWD 临时环境变量传递。
#
# 依赖：common.ps1 必须先 dot-source。
#
# 输出协议（JDBC 模式的 Java runner 与 CLI 模式共用）
#   H<TAB>col1<TAB>col2...   表头
#   R<TAB>val1<TAB>val2...   数据行
#   U<TAB>n                  非结果集语句的影响行数
#   T<TAB>0|1                1 = 还有更多行被 maxRows 截断
#   单元格按 \\ \t \n \r 转义；NULL 单独写成 \N（因此字面量 \N 会被转义成 \\N）。
#
# 为什么 JDBC 优先
#   本机没有 mysql CLI，但装了 Java 24 与 DBeaver 的 mysql-connector-j。
#   Java 11+ 的 source-file 模式可以直接跑单个 .java，无需先 javac。

# ---------------------------------------------------------------------------
# 驱动发现
# ---------------------------------------------------------------------------

function Find-DbOpsMysqlCli {
    return Get-Command mysql -ErrorAction SilentlyContinue
}

function Find-DbOpsJava {
    return Get-Command java -ErrorAction SilentlyContinue
}

function Find-DbOpsJdbcJar {
    param([string]$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (Test-Path -LiteralPath $PreferredPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $PreferredPath).Path
        }
        throw ("指定的 MySQL JDBC 驱动不存在：{0}" -f $PreferredPath)
    }

    $roots = @(
        (Join-Path $env:APPDATA 'DBeaverData\drivers\maven\maven-central\com.mysql'),
        (Join-Path $env:USERPROFILE '.dbeaver-drivers'),
        (Join-Path $env:LOCALAPPDATA 'DBeaver')
    )

    $found = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $found += Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*mysql*connector*.jar' -ErrorAction SilentlyContinue
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Resolve-DbOpsDriver {
    param(
        [string]$Requested,
        [string]$JdbcJar
    )

    $mysql = Find-DbOpsMysqlCli
    $java = Find-DbOpsJava

    if ($Requested -eq 'Cli') {
        if ($null -eq $mysql) {
            throw '未找到 mysql CLI。请安装 MySQL 客户端、把 mysql.exe 加入 PATH，或改用 -Driver Jdbc。'
        }
        return [pscustomobject]@{ Kind = 'Cli'; Mysql = $mysql; Java = $java; JdbcJar = $null }
    }

    if ($Requested -eq 'Jdbc') {
        if ($null -eq $java) { throw '未找到 java。JDBC 模式需要 Java 11 及以上。' }
        $jar = Find-DbOpsJdbcJar -PreferredPath $JdbcJar
        if ($null -eq $jar) { throw '未找到 MySQL JDBC 驱动（mysql-connector-j）。可用 -JdbcJar 指定。' }
        return [pscustomobject]@{ Kind = 'Jdbc'; Mysql = $mysql; Java = $java; JdbcJar = $jar }
    }

    if ($null -ne $mysql) {
        return [pscustomobject]@{ Kind = 'Cli'; Mysql = $mysql; Java = $java; JdbcJar = $null }
    }

    if ($null -ne $java) {
        $jar = Find-DbOpsJdbcJar -PreferredPath $JdbcJar
        if ($null -ne $jar) {
            return [pscustomobject]@{ Kind = 'Jdbc'; Mysql = $mysql; Java = $java; JdbcJar = $jar }
        }
    }

    throw '没有可用的 MySQL 执行器：需要 mysql CLI，或 Java 11+ 加 MySQL JDBC 驱动。'
}

# ---------------------------------------------------------------------------
# 连接串与转义
# ---------------------------------------------------------------------------

function New-DbOpsJdbcUrl {
    param(
        [string]$HostName,
        [string]$Port,
        [string]$Database
    )
    return ('jdbc:mysql://{0}:{1}/{2}?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true&connectTimeout=5000&socketTimeout=60000' -f $HostName, $Port, $Database)
}

function ConvertFrom-DbOpsEscapedCell {
    param([string]$Text)

    if ($null -eq $Text) { return $null }
    if ($Text.Length -eq 0) { return '' }

    $builder = New-Object System.Text.StringBuilder
    $index = 0
    while ($index -lt $Text.Length) {
        $ch = $Text[$index]
        if ($ch -eq '\' -and ($index + 1) -lt $Text.Length) {
            $next = $Text[$index + 1]
            if ($next -eq 'n') { $null = $builder.Append("`n"); $index += 2; continue }
            if ($next -eq 'r') { $null = $builder.Append("`r"); $index += 2; continue }
            if ($next -eq 't') { $null = $builder.Append("`t"); $index += 2; continue }
            if ($next -eq '\') { $null = $builder.Append('\'); $index += 2; continue }
        }
        $null = $builder.Append($ch)
        $index++
    }
    return $builder.ToString()
}

function ConvertTo-DbOpsProcessArgument {
    # 按 Windows 命令行规则给单个参数加引号。不用 ProcessStartInfo.ArgumentList：
    # Windows PowerShell 5.1 运行在 .NET Framework 上，没有这个属性。
    param([string]$Value)

    if ($null -eq $Value) { return '""' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }

    $builder = New-Object System.Text.StringBuilder
    $null = $builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $backslashes++; continue }
        if ($ch -eq '"') {
            $null = $builder.Append(('\' * ($backslashes * 2 + 1)))
            $null = $builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) { $null = $builder.Append(('\' * $backslashes)); $backslashes = 0 }
        $null = $builder.Append($ch)
    }
    if ($backslashes -gt 0) { $null = $builder.Append(('\' * ($backslashes * 2))) }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Invoke-DbOpsProcessCapture {
    # 直接起进程并分别捕获 stdout / stderr。
    #
    # 不用 `& exe ... 2> file`：Windows PowerShell 5.1 会把原生命令的 stderr 包装成
    # NativeCommandError；`$ErrorActionPreference='Stop'` 下它直接中断控制流，
    # 设为 Continue 时又会把 PowerShell 的格式化文本（`+ CategoryInfo ...`）写进文件。
    # 两种结果都会让真正的 SQL 错误读不出来。ProcessStartInfo 拿到的才是原始 stderr。
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$StandardInput
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = ($null -ne $StandardInput)
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-DbOpsProcessArgument -Value ([string]$_) }) -join ' ')

    $process = [System.Diagnostics.Process]::Start($psi)
    if ($null -ne $StandardInput) {
        $process.StandardInput.Write($StandardInput)
        $process.StandardInput.Close()
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdoutTask.Result
        StdErr   = $stderrTask.Result
    }
}

function ConvertFrom-DbOpsJavaError {
    # Java 的未捕获异常会带 "Exception in thread "main"" 与堆栈行。堆栈里是临时目录路径，
    # 对使用者没有信息量，还会把一行真正的错误淹没。只保留异常类型与消息。
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $kept = @()
    foreach ($line in @($Text -split "\r?\n")) {
        if ($line -match '^\s*at\s') { continue }
        if ($line -match '^\s*\.\.\.\s+\d+\s+more\s*$') { continue }
        $kept += $line
    }
    $joined = ($kept -join "`n").Trim()
    $joined = $joined -replace '^Exception in thread "[^"]*"\s*', ''
    return $joined.Trim()
}

function Split-DbOpsProtocolLine {
    # 返回 kind 与 cells。行格式：<kind><TAB>cell<TAB>cell...
    param([string]$Line)

    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $kind = $Line.Substring(0, 1)
    $rest = ''
    if ($Line.Length -gt 1) { $rest = $Line.Substring(1) }
    $cells = @()
    if ($rest.StartsWith("`t")) {
        $parts = @($rest.Substring(1) -split "`t")
        foreach ($part in $parts) {
            if ($part -eq '\N') { $cells += $null }
            else { $cells += (ConvertFrom-DbOpsEscapedCell -Text $part) }
        }
    }
    return [pscustomobject]@{ Kind = $kind; Cells = @($cells); Raw = $rest }
}

# ---------------------------------------------------------------------------
# 结果后处理
# ---------------------------------------------------------------------------

function Limit-DbOpsResult {
    # 按 policy 的单元格长度与结果字节上限收敛。**任何一次裁剪都要置 PossiblyTruncated**，
    # 否则调用方会把被截断的结果当成完整结果。
    param(
        $Result,
        [int]$MaxCellChars,
        [int]$MaxResultBytes
    )

    $rows = @($Result.Rows)
    $possiblyTruncated = [bool]$Result.Truncated

    if ($MaxCellChars -gt 0) {
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $row = @($rows[$r])
            for ($c = 0; $c -lt $row.Count; $c++) {
                if ($null -eq $row[$c]) { continue }
                $cell = [string]$row[$c]
                if ($cell.Length -gt $MaxCellChars) {
                    $row[$c] = $cell.Substring(0, $MaxCellChars - 1) + '…'
                    $possiblyTruncated = $true
                }
            }
            $rows[$r] = $row
        }
    }

    if ($MaxResultBytes -gt 0) {
        $total = 0
        $keep = 0
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $rowBytes = 0
            foreach ($cell in @($rows[$r])) {
                if ($null -ne $cell) { $rowBytes += [Text.Encoding]::UTF8.GetByteCount([string]$cell) }
            }
            if ($total + $rowBytes -gt $MaxResultBytes) { $possiblyTruncated = $true; break }
            $total += $rowBytes
            $keep++
        }
        if ($keep -lt $rows.Count) {
            $trimmed = New-Object System.Collections.Generic.List[object]
            for ($index = 0; $index -lt $keep; $index++) { $trimmed.Add($rows[$index]) }
            $rows = @($trimmed.ToArray())
        }
    }

    return [pscustomobject]@{
        Columns           = @($Result.Columns)
        Rows              = @($rows)
        RowsReturned      = @($rows).Count
        AffectedRows      = $Result.AffectedRows
        Truncated         = [bool]$Result.Truncated
        PossiblyTruncated = $possiblyTruncated
        ElapsedMs         = [int]$Result.ElapsedMs
        Driver            = [string]$Result.Driver
    }
}

# ---------------------------------------------------------------------------
# JDBC 执行器
# ---------------------------------------------------------------------------

function Invoke-DbOpsMySqlJdbc {
    param(
        [hashtable]$Config,
        [string]$Database,
        [string]$QueryText,
        [string]$Mode,
        [int]$MaxRows,
        $DriverInfo,
        [int]$MaxCellChars,
        [int]$MaxResultBytes
    )

    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('db-ops-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    $javaFile = Join-Path $tempDir 'DbOpsRunner.java'
    $sqlFile = Join-Path $tempDir 'query.sql'

    $javaSource = @'
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.Statement;

public class DbOpsRunner {
    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            throw new IllegalArgumentException("usage: DbOpsRunner <sqlFile> <query|exec> <maxRows>");
        }
        String sqlFile = args[0];
        String mode = args[1];
        int maxRows = Integer.parseInt(args[2]);

        String url = requireEnv("DBOPS_URL");
        String user = requireEnv("DBOPS_USER");
        String password = requireEnv("DBOPS_PASSWORD");
        String sql = Files.readString(Path.of(sqlFile), StandardCharsets.UTF_8);

        boolean isExec = "exec".equalsIgnoreCase(mode);
        Class.forName("com.mysql.cj.jdbc.Driver");
        try (Connection connection = DriverManager.getConnection(url, user, password)) {
            if (isExec) { connection.setAutoCommit(false); }
            try (Statement statement = connection.createStatement()) {
                boolean hasResultSet = statement.execute(sql);
                if (!hasResultSet) {
                    System.out.println("U\t" + statement.getUpdateCount());
                    if (isExec) { connection.commit(); }
                    return;
                }
                try (ResultSet rs = statement.getResultSet()) {
                    ResultSetMetaData meta = rs.getMetaData();
                    int columnCount = meta.getColumnCount();
                    StringBuilder header = new StringBuilder("H");
                    for (int i = 1; i <= columnCount; i++) {
                        header.append('\t').append(escape(meta.getColumnLabel(i)));
                    }
                    System.out.println(header);

                    int count = 0;
                    boolean truncated = false;
                    while (rs.next()) {
                        if (maxRows > 0 && count >= maxRows) { truncated = true; break; }
                        StringBuilder row = new StringBuilder("R");
                        for (int i = 1; i <= columnCount; i++) {
                            Object value = rs.getObject(i);
                            if (value == null) { row.append('\t').append("\\N"); }
                            else { row.append('\t').append(escape(value.toString())); }
                        }
                        System.out.println(row);
                        count++;
                    }
                    System.out.println("T\t" + (truncated ? "1" : "0"));
                }
                if (isExec) { connection.commit(); }
            } catch (Exception e) {
                if (isExec) {
                    try { connection.rollback(); } catch (Exception ignored) { }
                }
                throw e;
            }
        }
    }

    private static String escape(String value) {
        StringBuilder builder = new StringBuilder(value.length());
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c == '\\') { builder.append("\\\\"); }
            else if (c == '\t') { builder.append("\\t"); }
            else if (c == '\n') { builder.append("\\n"); }
            else if (c == '\r') { builder.append("\\r"); }
            else { builder.append(c); }
        }
        return builder.toString();
    }

    private static String requireEnv(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException("Missing environment variable: " + name);
        }
        return value;
    }
}
'@

    $oldUrl = $env:DBOPS_URL
    $oldUser = $env:DBOPS_USER
    $oldPassword = $env:DBOPS_PASSWORD
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($javaFile, $javaSource, $utf8NoBom)
        [IO.File]::WriteAllText($sqlFile, $QueryText, $utf8NoBom)

        $env:DBOPS_URL = New-DbOpsJdbcUrl -HostName ([string]$Config['DB_HOST']) -Port ([string]$Config['DB_PORT']) -Database $Database
        $env:DBOPS_USER = [string]$Config['DB_USER']
        $env:DBOPS_PASSWORD = [string]$Config['DB_PASS']

        $captured = Invoke-DbOpsProcessCapture -FilePath $DriverInfo.Java.Source -Arguments @(
            '-Dfile.encoding=UTF-8',
            '-Dsun.stdout.encoding=UTF-8',
            '-Dsun.stderr.encoding=UTF-8',
            '-cp', $DriverInfo.JdbcJar,
            $javaFile, $sqlFile, $Mode, [string]$MaxRows
        )
        $exitCode = [int]$captured.ExitCode
        $output = @($captured.StdOut -split "\r?\n")
        $stopwatch.Stop()

        if ($exitCode -ne 0) {
            $errorText = ConvertFrom-DbOpsJavaError -Text ([string]$captured.StdErr)
            if ([string]::IsNullOrWhiteSpace($errorText)) {
                $errorText = 'Java 进程返回非零退出码，且没有 stderr 输出。'
            }
            throw ('MySQL 执行失败：{0}' -f $errorText)
        }

        $columns = @()
        $rows = New-Object System.Collections.Generic.List[object]
        $affectedRows = $null
        $truncated = $false

        foreach ($line in @($output)) {
            $text = [string]$line
            if ($text.EndsWith("`r")) { $text = $text.TrimEnd("`r") }
            if ($text.Length -lt 1) { continue }
            $parsed = Split-DbOpsProtocolLine -Line $text
            if ($null -eq $parsed) { continue }
            if ($parsed.Kind -eq 'H') {
                $columns = @($parsed.Cells | ForEach-Object { [string]$_ })
            } elseif ($parsed.Kind -eq 'R') {
                $rows.Add(@($parsed.Cells))
            } elseif ($parsed.Kind -eq 'U') {
                $raw = [string]$parsed.Raw
                if ($raw.StartsWith("`t")) { $raw = $raw.Substring(1) }
                $number = 0
                if ([int]::TryParse($raw.Trim(), [ref]$number)) { $affectedRows = $number }
            } elseif ($parsed.Kind -eq 'T') {
                $raw = [string]$parsed.Raw
                if ($raw.StartsWith("`t")) { $raw = $raw.Substring(1) }
                $truncated = ($raw.Trim() -eq '1')
            }
        }

        $rawResult = [pscustomobject]@{
            Columns      = @($columns)
            Rows         = @($rows.ToArray())
            AffectedRows = $affectedRows
            Truncated    = $truncated
            ElapsedMs    = [int]$stopwatch.ElapsedMilliseconds
            Driver       = 'Jdbc'
        }
        return (Limit-DbOpsResult -Result $rawResult -MaxCellChars $MaxCellChars -MaxResultBytes $MaxResultBytes)
    } finally {
        if ($null -eq $oldUrl) { Remove-Item Env:\DBOPS_URL -ErrorAction SilentlyContinue } else { $env:DBOPS_URL = $oldUrl }
        if ($null -eq $oldUser) { Remove-Item Env:\DBOPS_USER -ErrorAction SilentlyContinue } else { $env:DBOPS_USER = $oldUser }
        if ($null -eq $oldPassword) { Remove-Item Env:\DBOPS_PASSWORD -ErrorAction SilentlyContinue } else { $env:DBOPS_PASSWORD = $oldPassword }
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# mysql CLI 兜底
# ---------------------------------------------------------------------------

function Invoke-DbOpsMySqlCli {
    param(
        [hashtable]$Config,
        [string]$Database,
        [string]$QueryText,
        [string]$Mode,
        [int]$MaxRows,
        $DriverInfo,
        [int]$MaxCellChars,
        [int]$MaxResultBytes
    )

    # SQL 走 stdin 而不是 -e：-e 会让整段 SQL 出现在进程命令行里（本机进程列表可见），
    # 而 stdin 只存在于父子进程之间。顺带避开 Windows 命令行对长 SQL 的长度限制。
    $arguments = @(
        '--default-character-set=utf8mb4',
        '-h', [string]$Config['DB_HOST'],
        '-P', [string]$Config['DB_PORT'],
        '-u', [string]$Config['DB_USER'],
        '--batch',
        $Database
    )

    $oldPassword = $env:MYSQL_PWD
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $env:MYSQL_PWD = [string]$Config['DB_PASS']
        # 与 JDBC 分支一致：用 ProcessStartInfo 直接读 stdout/stderr。
        # `& native 2> file` 在 Stop 模式下会先把 stderr 包成 NativeCommandError 抛出。
        $captured = Invoke-DbOpsProcessCapture -FilePath $DriverInfo.Mysql.Source -Arguments $arguments -StandardInput $QueryText
        $exitCode = [int]$captured.ExitCode
        $output = @($captured.StdOut -split "\r?\n")
        $stopwatch.Stop()
        if ($exitCode -ne 0) {
            $errorText = [string]$captured.StdErr
            if ([string]::IsNullOrWhiteSpace($errorText)) { $errorText = 'mysql 返回非零退出码，且没有 stderr 输出。' }
            throw ('MySQL 执行失败：{0}' -f $errorText.Trim())
        }

        $lines = @($output)
        $columns = @()
        $rows = New-Object System.Collections.Generic.List[object]
        $index = 0
        foreach ($line in $lines) {
            $text = [string]$line
            if ($text.EndsWith("`r")) { $text = $text.TrimEnd("`r") }
            if ($index -eq 0) {
                $columns = @($text -split "`t" | ForEach-Object { ConvertFrom-DbOpsEscapedCell -Text $_ })
            } else {
                $cells = @()
                foreach ($part in @($text -split "`t")) {
                    if ($part -eq '\N') { $cells += $null }
                    else { $cells += (ConvertFrom-DbOpsEscapedCell -Text $part) }
                }
                $rows.Add($cells)
            }
            $index++
        }

        $possiblyTruncated = ($MaxRows -gt 0 -and @($rows.ToArray()).Count -ge $MaxRows)
        $rawResult = [pscustomobject]@{
            Columns      = @($columns)
            Rows         = @($rows.ToArray())
            AffectedRows = $null
            Truncated    = $possiblyTruncated
            ElapsedMs    = [int]$stopwatch.ElapsedMilliseconds
            Driver       = 'Cli'
        }
        return (Limit-DbOpsResult -Result $rawResult -MaxCellChars $MaxCellChars -MaxResultBytes $MaxResultBytes)
    } finally {
        if ($null -eq $oldPassword) { Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue } else { $env:MYSQL_PWD = $oldPassword }
    }
}

# ---------------------------------------------------------------------------
# 统一入口
# ---------------------------------------------------------------------------

function Invoke-DbOpsSql {
    param(
        [hashtable]$Config,
        [string]$Database,
        [string]$QueryText,
        [ValidateSet('query', 'exec')]
        [string]$Mode,
        $DriverInfo,
        [int]$MaxRows = 0,
        [int]$MaxCellChars = 0,
        [int]$MaxResultBytes = 0
    )

    if ($DriverInfo.Kind -eq 'Cli') {
        return Invoke-DbOpsMySqlCli -Config $Config -Database $Database -QueryText $QueryText -Mode $Mode -MaxRows $MaxRows -DriverInfo $DriverInfo -MaxCellChars $MaxCellChars -MaxResultBytes $MaxResultBytes
    }
    return Invoke-DbOpsMySqlJdbc -Config $Config -Database $Database -QueryText $QueryText -Mode $Mode -MaxRows $MaxRows -DriverInfo $DriverInfo -MaxCellChars $MaxCellChars -MaxResultBytes $MaxResultBytes
}
