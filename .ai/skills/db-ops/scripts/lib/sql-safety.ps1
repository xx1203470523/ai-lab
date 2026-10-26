# lib/sql-safety.ps1 —— SQL 静态守卫：注释/字面量掩码、语句种类与条数、只读判定。
#
# 职责边界
#   纯文本分析。输入一段 SQL，输出「是不是只读、是哪种语句、有几条、被哪条规则拒了」。
#
# 明确不做
#   不连数据库、不解析 SQL 语义、不判断权限（关键字拦截是第二道防线，不等于数据库授权）、
#   不写文件、不打印。
#
# 依赖：common.ps1 必须先 dot-source。
#
# 为什么必须先掩码再判关键字
#   旧实现在**原文**上跑关键字黑名单，于是
#     SELECT * FROM t WHERE note = 'please update the record'
#   会被 \bUPDATE\b 判成写操作而拒绝。这类误报的代价不是「多拦了一次」——它会训练使用者
#   绕开守卫，而那才是真正危险的。掩码把注释与字符串字面量替换成同长度的空白，
#   关键字与分号判定只在掩码上做，误报随之消失。
#
# 同时保留两份文本
#   掩码**只**用于关键字与分号判定。原文必须留着：错误回显、阶段 2 的 LIMIT 追加、
#   以及给用户看「你提交的到底是哪句话」，都需要真实文本；在掩码上做这些会把
#   `LIMIT 10` 里的数字一起抹掉。

# ---------------------------------------------------------------------------
# 掩码
# ---------------------------------------------------------------------------

function Get-MaskedSql {
    # 单趟扫描，逐字符输出同长度文本：
    #   - 注释（`-- `、`#`、`/* */`）与字符串字面量（`'...'`、`"..."`、反引号标识符）
    #     的内部字符全部替换成空格；
    #   - **换行原样保留**，否则行号会漂，报错定位就失去意义。
    #
    # MySQL 细节（按方言处理，不按通用 SQL 猜）：
    #   - `--` 只有当后面跟空白或行尾时才是注释（`SELECT a--b` 不是）；
    #   - `#` 到行尾是注释；
    #   - 字符串里 `\x` 是转义，`''` 是「一个单引号」；
    #   - 反引号是标识符引用，也一并掩码（表名叫 `update` 不该触发误报）。
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $chars = $Text.ToCharArray()
    $count = $chars.Length
    $builder = New-Object System.Text.StringBuilder
    $state = 'normal'
    $index = 0

    while ($index -lt $count) {
        $current = $chars[$index]

        if ($state -eq 'normal') {
            if ($current -eq '-' -and ($index + 1) -lt $count -and $chars[$index + 1] -eq '-') {
                $afterIndex = $index + 2
                if ($afterIndex -ge $count -or [char]::IsWhiteSpace($chars[$afterIndex])) {
                    $null = $builder.Append(' ').Append(' ')
                    $index += 2
                    $state = 'linecomment'
                    continue
                }
            }
            if ($current -eq '#') {
                $null = $builder.Append(' ')
                $index++
                $state = 'linecomment'
                continue
            }
            if ($current -eq '/' -and ($index + 1) -lt $count -and $chars[$index + 1] -eq '*') {
                $null = $builder.Append(' ').Append(' ')
                $index += 2
                $state = 'blockcomment'
                continue
            }
            if ($current -eq "'") { $null = $builder.Append(' '); $index++; $state = 'single'; continue }
            if ($current -eq '"') { $null = $builder.Append(' '); $index++; $state = 'double'; continue }
            if ($current -eq '`') { $null = $builder.Append(' '); $index++; $state = 'backtick'; continue }

            $null = $builder.Append($current)
            $index++
            continue
        }

        if ($state -eq 'linecomment') {
            if ($current -eq "`r" -or $current -eq "`n") {
                $null = $builder.Append($current)
                $state = 'normal'
            } else {
                $null = $builder.Append(' ')
            }
            $index++
            continue
        }

        if ($state -eq 'blockcomment') {
            if ($current -eq '*' -and ($index + 1) -lt $count -and $chars[$index + 1] -eq '/') {
                $null = $builder.Append(' ').Append(' ')
                $index += 2
                $state = 'normal'
                continue
            }
            if ($current -eq "`r" -or $current -eq "`n") { $null = $builder.Append($current) }
            else { $null = $builder.Append(' ') }
            $index++
            continue
        }

        # 字符串字面量：single / double / backtick
        $delimiter = "'"
        if ($state -eq 'double') { $delimiter = '"' }
        if ($state -eq 'backtick') { $delimiter = '`' }

        if ($current -eq '\' -and $state -ne 'backtick' -and ($index + 1) -lt $count) {
            # 反斜杠转义：连同被转义字符一起掩掉，免得 \' 被当成字符串结束。
            $null = $builder.Append(' ')
            $escaped = $chars[$index + 1]
            if ($escaped -eq "`r" -or $escaped -eq "`n") { $null = $builder.Append($escaped) } else { $null = $builder.Append(' ') }
            $index += 2
            continue
        }

        if ($current -eq $delimiter) {
            if (($index + 1) -lt $count -and $chars[$index + 1] -eq $delimiter) {
                # 成对定界符（'' 或 ""）：一个转义后的引号，字符串还没结束。
                $null = $builder.Append(' ').Append(' ')
                $index += 2
                continue
            }
            $null = $builder.Append(' ')
            $index++
            $state = 'normal'
            continue
        }

        if ($current -eq "`r" -or $current -eq "`n") { $null = $builder.Append($current) }
        else { $null = $builder.Append(' ') }
        $index++
    }

    return $builder.ToString()
}

# ---------------------------------------------------------------------------
# 语句种类与条数
# ---------------------------------------------------------------------------

function Get-SqlStatementKind {
    # 只看首关键字。**必须传掩码文本**：原文里开头的注释会让首关键字变成注释里的词。
    param([string]$Masked)

    if ([string]::IsNullOrWhiteSpace($Masked)) { return 'EMPTY' }
    $match = [regex]::Match($Masked, '^\s*([A-Za-z]+)')
    if (-not $match.Success) { return 'OTHER' }
    return $match.Groups[1].Value.ToUpperInvariant()
}

function Test-SqlStatementCount {
    # 在掩码上按 ';' 切分并数非空段。字面量与注释里的分号已经被掩成空格，
    # 因此 `WHERE a = 'x;y'` 不会被算成两条语句。
    param([string]$Masked)

    if ([string]::IsNullOrWhiteSpace($Masked)) { return 0 }
    $parts = @($Masked -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return $parts.Count
}

function Test-SqlHasTopLevelLimit {
    # 供阶段 2 的 LIMIT 追加使用：判断语句结尾是否已有 LIMIT/OFFSET。
    #
    # 旧实现用 `-notmatch '\bLIMIT\s+\d+\s*;?\s*$'` 判断，两个缺陷：
    #   1) `LIMIT 10 OFFSET 5` 结尾判不出来，会再追加一个 LIMIT，语句直接语法错误；
    #   2) 结尾有注释时同样判不出来，追加的结果会把注释吃掉。
    # 这里在掩码上判断（注释已消失），并把 OFFSET 一并考虑进去。
    param([string]$Masked)

    if ([string]::IsNullOrWhiteSpace($Masked)) { return $false }
    $trimmed = $Masked.Trim().TrimEnd(';').TrimEnd()
    return ($trimmed -match '(?is)\bLIMIT\s+\d+\s*(OFFSET\s+\d+\s*)?$')
}

function Add-SqlLimitIfMissing {
    # 阶段 2 会用；本阶段由离线测试直接覆盖，保证「追加」这件事只有一处实现。
    # 追加发生在**原文**上，判断发生在掩码上——两者分工不能串。
    param(
        [string]$Text,
        [int]$Limit
    )

    if ($Limit -le 0) { return $Text }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $masked = Get-MaskedSql -Text $Text
    if (Test-SqlHasTopLevelLimit -Masked $masked) { return $Text }

    $trimmed = $Text.TrimEnd()
    $hadSemicolon = $trimmed.EndsWith(';')
    if ($hadSemicolon) { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd() }
    return ($trimmed + ("`nLIMIT {0};" -f $Limit))
}

# ---------------------------------------------------------------------------
# 只读判定
# ---------------------------------------------------------------------------

function Get-SqlBlockedPattern {
    # 写操作、锁语义、会话副作用、服务器文件访问。
    #
    # 关于 `FOR UPDATE` / `LOCK IN SHARE MODE`：旧守卫其实**拦得住**它们，但拦住的
    # 方式是不可靠的——`FOR UPDATE` 命中 \bUPDATE\b，`LOCK IN SHARE MODE` 命中 \bLOCK\b，
    # 也就是说它同时拦掉了 `WHERE action = 'update'` 这种完全正常的只读查询。
    # 这里把它们显式列出来，让「拦住」和「只拦该拦的」同时成立。
    #
    # 真正被旧守卫漏掉的（本清单补上）：
    #   FOR SHARE（MySQL 8 的共享锁，没有 UPDATE/LOCK 字样）
    #   INTO @var（会话变量赋值，有副作用）
    #   GET_LOCK / RELEASE_LOCK 系列（拿锁）
    #   SLEEP / BENCHMARK（把只读查询变成资源消耗）
    #   PROCEDURE ANALYSE（会读数据并给出建议，历史特性）
    #   LOAD_FILE（读服务器本地文件）
    # `INTO` 整体拒绝：纯 SELECT/SHOW/DESC/EXPLAIN/WITH 里不会合法地出现 INTO。
    return ('(?is)\b(ALTER|CREATE|DROP|TRUNCATE|INSERT|UPDATE|DELETE|REPLACE|MERGE|CALL|GRANT|REVOKE|' +
        'LOCK|UNLOCK|LOAD|SET|USE|BEGIN|COMMIT|ROLLBACK|RENAME|HANDLER|PREPARE|EXECUTE|DEALLOCATE|' +
        'SAVEPOINT|XA|PURGE|ANALYZE|OPTIMIZE|REPAIR|FLUSH|RESET|KILL|SHUTDOWN|INSTALL|UNINSTALL)\b' +
        '|\bINTO\b' +
        '|\bFOR\s+(UPDATE|SHARE)\b' +
        '|\bLOCK\s+IN\s+SHARE\s+MODE\b' +
        '|\b(GET_LOCK|RELEASE_LOCK|IS_FREE_LOCK|IS_USED_LOCK)\s*\(' +
        '|\b(SLEEP|BENCHMARK|LOAD_FILE)\s*\(' +
        '|\bPROCEDURE\s+ANALYSE\b' +
        '|\bSTART\s+(TRANSACTION|REPLICA|SLAVE)\b' +
        '|\bSTOP\s+(REPLICA|SLAVE)\b' +
        '|\bCHANGE\s+MASTER\b')
}

function Test-ReadOnlySql {
    # 返回对象，**不抛异常**：调用方需要能同时拿到「结论」和「为什么」，
    # 而 Validate 模式要把二者一起报给用户。需要「失败即中止」的调用方用 Assert-ReadOnlySql。
    #
    # 返回：{Ok, Kind, StatementCount, Reason, Masked, TextHash}
    param([string]$Text)

    $result = [pscustomobject]@{
        Ok             = $false
        Kind           = 'EMPTY'
        StatementCount = 0
        Reason         = ''
        Masked         = ''
        TextHash       = ''
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        $result.Reason = 'SQL 为空。'
        return $result
    }

    $masked = Get-MaskedSql -Text $Text
    $result.Masked = $masked
    $result.TextHash = Get-Sha256Short -Text $Text -Length 16

    if ([string]::IsNullOrWhiteSpace($masked)) {
        $result.Reason = 'SQL 里只有注释或空白，没有可执行语句。'
        return $result
    }

    $kind = Get-SqlStatementKind -Masked $masked
    $result.Kind = $kind
    $allowedKinds = @('SELECT', 'SHOW', 'DESCRIBE', 'DESC', 'EXPLAIN', 'WITH')
    if ($allowedKinds -notcontains $kind) {
        $result.Reason = ("只读模式只接受 {0} 开头的语句，当前是 {1}。写操作请走 workflows/exec-flow.md 的受控执行流程。" -f ($allowedKinds -join '/'), $kind)
        return $result
    }

    $statementCount = Test-SqlStatementCount -Masked $masked
    $result.StatementCount = $statementCount
    if ($statementCount -gt 1) {
        $result.Reason = ("一次只允许一条语句，检测到 {0} 条。" -f $statementCount)
        return $result
    }
    if ($statementCount -eq 0) {
        $result.Reason = 'SQL 里没有可执行语句。'
        return $result
    }

    $blocked = [regex]::Match($masked, (Get-SqlBlockedPattern))
    if ($blocked.Success) {
        $result.Reason = ("SQL 含被拒绝的写法：'{0}'。" +
            '写操作请走 workflows/exec-flow.md；锁语义（FOR UPDATE / FOR SHARE / LOCK IN SHARE MODE）、' +
            '会话副作用（INTO @var）、服务器文件访问与资源消耗函数（SLEEP/BENCHMARK）在只读模式下没有合法用法。') -f $blocked.Value
        return $result
    }

    $result.Ok = $true
    $result.Reason = ("只读语句通过静态校验（{0}，{1} 条）。" -f $kind, $statementCount)
    return $result
}

function Assert-ReadOnlySql {
    param(
        [string]$Text,
        [string]$Context
    )
    $check = Test-ReadOnlySql -Text $Text
    if (-not $check.Ok) {
        throw ('{0}：{1}' -f $Context, $check.Reason)
    }
    return $check
}

function Test-WriteSql {
    # 阶段 2 的 Exec 闸门会用。本阶段只做分类，不执行任何东西。
    param([string]$Text)

    $masked = Get-MaskedSql -Text $Text
    $kind = Get-SqlStatementKind -Masked $masked
    $writeKinds = @('INSERT', 'UPDATE', 'DELETE', 'REPLACE', 'MERGE', 'ALTER', 'CREATE', 'DROP', 'TRUNCATE', 'RENAME')
    return [pscustomobject]@{
        IsWrite        = ($writeKinds -contains $kind)
        Kind           = $kind
        StatementCount = (Test-SqlStatementCount -Masked $masked)
    }
}
