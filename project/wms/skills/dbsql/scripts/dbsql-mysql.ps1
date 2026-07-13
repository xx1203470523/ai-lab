param(
    [ValidateSet('Check', 'Query', 'File')]
    [string]$Mode = 'Check',

    [ValidateSet('Auto', 'Cli', 'Jdbc')]
    [string]$Driver = 'Auto',

    [string]$EnvPath = "$env:USERPROFILE\.claude\skills\dbsql\.env",

    [string]$Environment,

    [string]$Database,

    [string]$Sql,

    [string]$SqlPath,

    [string]$JdbcJar,

    [int]$Limit = 0
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    # Encoding setup is best-effort for older hosts.
}

function Read-DbsqlEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Env file not found: $Path"
    }

    $result = @{}
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed -notmatch '^([^=]+)=(.*)$') { continue }

        $key = $matches[1].Trim()
        $value = $matches[2].Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            if ($value.Length -ge 2) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $result[$key] = $value
        }
    }

    return $result
}

function Resolve-DbsqlConfig {
    param(
        [hashtable]$EnvValues,
        [string]$EnvironmentName
    )

    $selectedEnvironment = $EnvironmentName
    if ([string]::IsNullOrWhiteSpace($selectedEnvironment) -and $EnvValues.ContainsKey('DBSQL_DEFAULT_ENV')) {
        $selectedEnvironment = [string]$EnvValues['DBSQL_DEFAULT_ENV']
    }

    $prefix = ''
    $displayEnvironment = 'default'
    if (-not [string]::IsNullOrWhiteSpace($selectedEnvironment) -and $selectedEnvironment -notin @('default', 'main')) {
        $displayEnvironment = $selectedEnvironment.Trim().ToLowerInvariant()
        $prefix = $selectedEnvironment.Trim().ToUpperInvariant() + '_'
    }

    $config = @{ DBSQL_ENVIRONMENT = $displayEnvironment }
    foreach ($required in @('DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASS', 'DB_NAME')) {
        $key = $prefix + $required
        if (-not $EnvValues.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$EnvValues[$key])) {
            throw "Env key missing: $key"
        }
        $config[$required] = [string]$EnvValues[$key]
    }

    foreach ($optional in @('DB_SSLMODE', 'DB_ALLOW_LOAD_LOCAL_INFILE', 'DB_POOLING', 'DB_MINIMUM_POOL_SIZE', 'DB_MAXIMUM_POOL_SIZE')) {
        $key = $prefix + $optional
        if ($EnvValues.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$EnvValues[$key])) {
            $config[$optional] = [string]$EnvValues[$key]
        }
    }

    return $config
}

function Test-ReadOnlySql {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'SQL is empty.'
    }

    $normalized = $Text.Trim()
    $normalized = [regex]::Replace($normalized, '^\s*/\*.*?\*/\s*', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $normalized = [regex]::Replace($normalized, '^\s*--[^\r\n]*(\r?\n|$)', '')
    $normalized = $normalized.Trim()

    if ($normalized -notmatch '^(?is)(SELECT|SHOW|DESCRIBE|DESC|EXPLAIN|WITH)\b') {
        throw 'Only read-only SQL is allowed. Statement must start with SELECT, SHOW, DESCRIBE, DESC, EXPLAIN, or WITH.'
    }

    $blockedPattern = '(?is)\b(ALTER|CREATE|DROP|TRUNCATE|INSERT|UPDATE|DELETE|REPLACE|MERGE|CALL|GRANT|REVOKE|LOCK|UNLOCK|LOAD|SET|USE|BEGIN|START\s+TRANSACTION|COMMIT|ROLLBACK)\b|\bINTO\s+(OUTFILE|DUMPFILE)\b'
    if ($normalized -match $blockedPattern) {
        throw 'Blocked non-read-only keyword found in SQL.'
    }
}

function Find-MysqlCli {
    return Get-Command mysql -ErrorAction SilentlyContinue
}

function Find-JavaCommand {
    return Get-Command java -ErrorAction SilentlyContinue
}

function Find-MysqlJdbcJar {
    param([string]$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (Test-Path -LiteralPath $PreferredPath) { return (Resolve-Path -LiteralPath $PreferredPath).Path }
        throw "JDBC jar not found: $PreferredPath"
    }

    $roots = @(
        (Join-Path $env:APPDATA 'DBeaverData\drivers\maven\maven-central\com.mysql'),
        (Join-Path $env:USERPROFILE '.dbeaver-drivers'),
        (Join-Path $env:LOCALAPPDATA 'DBeaver')
    )

    $matches = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $matches += Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*mysql*connector*.jar' -ErrorAction SilentlyContinue
    }

    if ($matches.Count -eq 0) { return $null }
    return ($matches | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Resolve-DbsqlDriver {
    param(
        [string]$RequestedDriver,
        [string]$PreferredJdbcJar
    )

    $mysql = Find-MysqlCli
    $java = Find-JavaCommand
    $jar = Find-MysqlJdbcJar -PreferredPath $PreferredJdbcJar

    if ($RequestedDriver -eq 'Cli') {
        if ($null -eq $mysql) { throw 'mysql CLI not found in PATH. Install MySQL client, add mysql.exe to PATH, or use -Driver Jdbc.' }
        return @{ Kind = 'Cli'; Mysql = $mysql; Java = $java; JdbcJar = $jar }
    }

    if ($RequestedDriver -eq 'Jdbc') {
        if ($null -eq $java) { throw 'java command not found in PATH. JDBC mode requires Java.' }
        if ($null -eq $jar) { throw 'MySQL JDBC driver jar not found. Install DBeaver MySQL driver or pass -JdbcJar <mysql-connector-j.jar>.' }
        return @{ Kind = 'Jdbc'; Mysql = $mysql; Java = $java; JdbcJar = $jar }
    }

    if ($null -ne $mysql) {
        return @{ Kind = 'Cli'; Mysql = $mysql; Java = $java; JdbcJar = $jar }
    }

    if ($null -ne $java -and $null -ne $jar) {
        return @{ Kind = 'Jdbc'; Mysql = $mysql; Java = $java; JdbcJar = $jar }
    }

    throw 'No MySQL execution driver found. Need mysql CLI, or Java plus MySQL JDBC driver jar such as DBeaver mysql-connector-j.'
}

function Invoke-MysqlCli {
    param(
        [hashtable]$Config,
        [string]$TargetDatabase,
        [string]$QueryText,
        [System.Management.Automation.CommandInfo]$MysqlCommand,
        [switch]$NoTable
    )

    $args = @(
        '--default-character-set=utf8mb4',
        '-h', [string]$Config['DB_HOST'],
        '-P', [string]$Config['DB_PORT'],
        '-u', [string]$Config['DB_USER']
    )

    if (-not $NoTable) {
        $args += '--table'
    }

    $args += @($TargetDatabase, '-e', $QueryText)

    $oldPwd = $env:MYSQL_PWD
    $env:MYSQL_PWD = [string]$Config['DB_PASS']
    try {
        & $MysqlCommand.Source @args
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            throw "mysql exited with code $exitCode"
        }
    } finally {
        if ($null -eq $oldPwd) {
            Remove-Item Env:\MYSQL_PWD -ErrorAction SilentlyContinue
        } else {
            $env:MYSQL_PWD = $oldPwd
        }
    }
}

function Invoke-MysqlJdbc {
    param(
        [hashtable]$Config,
        [string]$TargetDatabase,
        [string]$QueryText,
        [System.Management.Automation.CommandInfo]$JavaCommand,
        [string]$DriverJar
    )

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dbsql-jdbc-' + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tempDir > $null
    $javaFile = Join-Path $tempDir 'DbSqlJdbcRunner.java'
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

public class DbSqlJdbcRunner {
    public static void main(String[] args) throws Exception {
        if (args.length < 1) {
            throw new IllegalArgumentException("SQL file path is required.");
        }

        String url = requireEnv("DBSQL_URL");
        String user = requireEnv("DBSQL_USER");
        String password = requireEnv("DBSQL_PASSWORD");
        String sql = Files.readString(Path.of(args[0]), StandardCharsets.UTF_8);

        Class.forName("com.mysql.cj.jdbc.Driver");
        try (Connection connection = DriverManager.getConnection(url, user, password);
             Statement statement = connection.createStatement()) {
            boolean hasResultSet = statement.execute(sql);
            if (!hasResultSet) {
                System.out.println("No result set. Update count: " + statement.getUpdateCount());
                return;
            }

            try (ResultSet rs = statement.getResultSet()) {
                ResultSetMetaData meta = rs.getMetaData();
                int columnCount = meta.getColumnCount();
                for (int i = 1; i <= columnCount; i++) {
                    if (i > 1) System.out.print("\t");
                    System.out.print(meta.getColumnLabel(i));
                }
                System.out.println();

                while (rs.next()) {
                    for (int i = 1; i <= columnCount; i++) {
                        if (i > 1) System.out.print("\t");
                        Object value = rs.getObject(i);
                        if (value == null) {
                            System.out.print("NULL");
                        } else {
                            String text = value.toString().replace("\r", " ").replace("\n", " ").replace("\t", " ");
                            System.out.print(text);
                        }
                    }
                    System.out.println();
                }
            }
        }
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

    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($javaFile, $javaSource, $utf8NoBom)
        [System.IO.File]::WriteAllText($sqlFile, $QueryText, $utf8NoBom)

        $oldUrl = $env:DBSQL_URL
        $oldUser = $env:DBSQL_USER
        $oldPassword = $env:DBSQL_PASSWORD

        $env:DBSQL_URL = 'jdbc:mysql://{0}:{1}/{2}?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true' -f $Config['DB_HOST'], $Config['DB_PORT'], $TargetDatabase
        $env:DBSQL_USER = [string]$Config['DB_USER']
        $env:DBSQL_PASSWORD = [string]$Config['DB_PASS']

        try {
            & $JavaCommand.Source '-Dfile.encoding=UTF-8' '-Dsun.stdout.encoding=UTF-8' '-Dsun.stderr.encoding=UTF-8' '-cp' $DriverJar $javaFile $sqlFile
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "java JDBC runner exited with code $exitCode"
            }
        } finally {
            if ($null -eq $oldUrl) { Remove-Item Env:\DBSQL_URL -ErrorAction SilentlyContinue } else { $env:DBSQL_URL = $oldUrl }
            if ($null -eq $oldUser) { Remove-Item Env:\DBSQL_USER -ErrorAction SilentlyContinue } else { $env:DBSQL_USER = $oldUser }
            if ($null -eq $oldPassword) { Remove-Item Env:\DBSQL_PASSWORD -ErrorAction SilentlyContinue } else { $env:DBSQL_PASSWORD = $oldPassword }
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $envValues = Read-DbsqlEnv -Path $EnvPath
    $config = Resolve-DbsqlConfig -EnvValues $envValues -EnvironmentName $Environment
    $targetDb = $Database
    if ([string]::IsNullOrWhiteSpace($targetDb)) {
        $targetDb = [string]$config['DB_NAME']
    }

    $resolved = Resolve-DbsqlDriver -RequestedDriver $Driver -PreferredJdbcJar $JdbcJar

    if ($Mode -eq 'Check') {
        Write-Output ('Env: OK ({0})' -f $EnvPath)
        Write-Output ('Environment: {0}' -f $config['DBSQL_ENVIRONMENT'])
        Write-Output ('Target: {0}:{1}/{2} as {3}' -f $config['DB_HOST'], $config['DB_PORT'], $targetDb, $config['DB_USER'])
        if ($null -ne $resolved.Mysql) { Write-Output ('mysql CLI: OK ({0})' -f $resolved.Mysql.Source) } else { Write-Output 'mysql CLI: NOT_FOUND' }
        if ($null -ne $resolved.Java) { Write-Output ('java: OK ({0})' -f $resolved.Java.Source) } else { Write-Output 'java: NOT_FOUND' }
        if ($null -ne $resolved.JdbcJar) { Write-Output ('MySQL JDBC: OK ({0})' -f $resolved.JdbcJar) } else { Write-Output 'MySQL JDBC: NOT_FOUND' }
        Write-Output ('Driver: {0}' -f $resolved.Kind)

        if ($resolved.Kind -eq 'Cli') {
            Invoke-MysqlCli -Config $config -TargetDatabase $targetDb -QueryText 'SELECT DATABASE() AS db_name, VERSION() AS mysql_version;' -MysqlCommand $resolved.Mysql -NoTable
        } else {
            Invoke-MysqlJdbc -Config $config -TargetDatabase $targetDb -QueryText 'SELECT DATABASE() AS db_name, VERSION() AS mysql_version;' -JavaCommand $resolved.Java -DriverJar $resolved.JdbcJar
        }

        Write-Output 'Check: OK'
        exit 0
    }

    $queryText = $Sql
    if ($Mode -eq 'File') {
        if ([string]::IsNullOrWhiteSpace($SqlPath)) {
            throw 'SqlPath is required when Mode is File.'
        }
        if (-not (Test-Path -LiteralPath $SqlPath)) {
            throw "SQL file not found: $SqlPath"
        }
        $queryText = Get-Content -LiteralPath $SqlPath -Raw -Encoding UTF8
    }

    Test-ReadOnlySql -Text $queryText

    if ($Limit -gt 0 -and $queryText.TrimEnd() -notmatch '(?is)\bLIMIT\s+\d+\s*;?\s*$') {
        $queryText = $queryText.Trim().TrimEnd(';') + "`nLIMIT $Limit;"
    }

    if ($resolved.Kind -eq 'Cli') {
        Invoke-MysqlCli -Config $config -TargetDatabase $targetDb -QueryText $queryText -MysqlCommand $resolved.Mysql
    } else {
        Invoke-MysqlJdbc -Config $config -TargetDatabase $targetDb -QueryText $queryText -JavaCommand $resolved.Java -DriverJar $resolved.JdbcJar
    }

    exit 0
} catch {
    [Console]::Error.WriteLine(('ERROR: {0}' -f $_.Exception.Message))
    exit 1
}
