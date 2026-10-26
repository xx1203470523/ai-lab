# QingLong 任务编排入口
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File ql.ps1 -Verb <verb> [参数]
#
# 退出码：0 成功 / 1 硬失败 / 2 需要确认（已输出计划与摘要）/ 3 缺少确认摘要 / 4 摘要不匹配
#
# 风险分级：level 0 只读、level 1 可预期变更、level 2 高风险。
# level >= 1 必须先不带 -ConfirmPlan 跑一次拿摘要，再带摘要执行。

param(
    [Parameter(Mandatory = $true)][string]$Verb,
    [string]$Key,
    [int]$Id = 0,
    [string]$ContentFile,
    [string]$ConfirmPlan,
    [int]$Limit = 0,
    [int]$Threshold = 8,
    [switch]$Force,
    [switch]$IncludeDisabled,
    [switch]$Full
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

$qlHere = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $qlHere 'lib\ql-api.ps1')
. (Join-Path $qlHere 'lib\ql-task.ps1')
. (Join-Path $qlHere 'lib\ql-script.ps1')
. (Join-Path $qlHere 'lib\ql-log.ps1')
. (Join-Path $qlHere 'lib\ql-state.ps1')

$script:QlLevels = @{
    'auth.check'     = 0
    'task.list'      = 0
    'task.get'       = 0
    'script.list'    = 0
    'script.get'     = 0
    'log.list'       = 0
    'log.tail'       = 0
    'state.diff'     = 0
    'state.orphans'  = 0
    'diagnose'       = 0
    'task.create'    = 1
    'task.update'    = 1
    'task.adopt'     = 1
    'task.enable'    = 1
    'task.disable'   = 1
    'script.new'     = 1
    'script.put'     = 1
    'state.reconcile'= 2
    'task.delete'    = 2
    'task.run'       = 2
    'script.delete'  = 2
}

function Get-QlLevel {
    param([string]$Name)
    if (-not $script:QlLevels.ContainsKey($Name)) { throw "未知动词：$Name" }
    return [int]$script:QlLevels[$Name]
}

# 摘要不匹配同时覆盖「摘要写错」与「计划后状态已变化」，两者都必须重新出计划
function Test-QlPlanConfirmed {
    param($Plan)
    $digest = Get-QlPlanDigest -PlanObject $Plan
    if ([string]::IsNullOrWhiteSpace($ConfirmPlan)) {
        Set-QlEnvelope -Name 'planned' -Value $Plan
        Set-QlEnvelope -Name 'planDigest' -Value $digest
        Write-QlEnvelope -Status 'awaiting-confirmation' -Ok $false
        exit 2
    }
    if ($ConfirmPlan.Trim().ToLower() -ne $digest) {
        Set-QlEnvelope -Name 'planned' -Value $Plan
        Set-QlEnvelope -Name 'planDigest' -Value $digest
        Add-QlError "计划摘要不匹配：传入 $ConfirmPlan，当前状态算出 $digest。状态可能在计划后发生变化，请重新出计划。"
        Write-QlEnvelope -Status 'plan-drift' -Ok $false
        exit 4
    }
    Set-QlEnvelope -Name 'planDigest' -Value $digest
    return $true
}

function Get-QlActualDigest {
    param($Actual)
    if ($null -eq $Actual) { return 'absent' }
    return (Get-QlPlanDigest -PlanObject ([ordered]@{
        id = [int]$Actual.id; name = [string]$Actual.name
        command = [string]$Actual.command; schedule = [string]$Actual.schedule
        isDisabled = [int]$Actual.isDisabled
        labels = @($Actual.labels)
    }))
}

function Get-QlManagedList {
    param($Tasks = $null)
    if ($null -eq $Tasks) { $Tasks = Get-QlTasks }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Tasks) {
        $out.Add([ordered]@{
            id         = [int]$t.id
            name       = [string]$t.name
            command    = [string]$t.command
            schedule   = [string]$t.schedule
            enabled    = ([int]$t.isDisabled -eq 0)
            fields     = @(([string]$t.schedule).Trim() -split '\s+' | Where-Object { $_ -ne '' }).Count
            lastRun    = if ($t.last_execution_time) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$t.last_execution_time).LocalDateTime).ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            managed    = (Test-QlManaged -Task $t)
            key        = (Get-QlLabelValue -Labels $t.labels -Key 'qls.key')
        })
    }
    # OrderedDictionary 的属性不参与 Sort-Object 默认比较，必须显式取键
    return @($out | Sort-Object { [int]$_['id'] })
}

function Invoke-QlVerifyTask {
    param([string]$TargetKey, $Expect)
    $fresh = Get-QlTaskByKey -Key $TargetKey
    if ($null -eq $Expect) {
        if ($null -ne $fresh) { throw "回读校验失败：$TargetKey 仍存在于平台（id=$($fresh.id)）" }
        return $null
    }
    if ($null -eq $fresh) { throw "回读校验失败：$TargetKey 写入后读不到" }
    $d = Get-QlDesired -Key $TargetKey
    $diff = @(Compare-QlTask -Desired $d -Actual $fresh)
    if ($diff.Count -gt 0) {
        throw ("回读校验失败：$TargetKey 写入后仍有 {0} 处差异，平台未按期望落地" -f $diff.Count)
    }
    return $fresh
}

# ======================================================================
try {
    $level = Get-QlLevel -Name $Verb
    Initialize-QlEnvelope -Verb $Verb -Level $level

    switch ($Verb) {

        # ---------------- level 0 ----------------
        'auth.check' {
            Import-QlEnv
            $tok = New-QlToken
            $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$tok.expiration).LocalDateTime
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                baseUrl = $script:QlBaseUrl
                scope   = 'crons,scripts,logs'
                tokenExpiresAt = $exp.ToString('yyyy-MM-dd HH:mm:ss')
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.list' {
            $tasks = Get-QlTasks
            $list = Get-QlManagedList -Tasks $tasks
            if (-not $IncludeDisabled) { }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                total   = @($tasks).Count
                managed = @($list | Where-Object { $_.managed }).Count
                tasks   = @($list)
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.get' {
            if ([string]::IsNullOrWhiteSpace($Key) -and $Id -le 0) { throw 'task.get 需要 -Key 或 -Id' }
            $tasks = Get-QlTasks
            $t = $null
            if (-not [string]::IsNullOrWhiteSpace($Key)) { $t = Get-QlTaskByKey -Key $Key -Tasks $tasks }
            elseif ($Id -gt 0) { $t = $tasks | Where-Object { [int]$_.id -eq $Id } | Select-Object -First 1 }
            if ($null -eq $t) { throw "找不到任务（Key=$Key Id=$Id）" }
            Set-QlEnvelope -Name 'actual' -Value ([ordered]@{
                id = [int]$t.id; name = [string]$t.name; command = [string]$t.command
                schedule = [string]$t.schedule; enabled = ([int]$t.isDisabled -eq 0)
                isPinned = [int]$t.isPinned
                labels = @($t.labels)
                managed = (Test-QlManaged -Task $t)
                key = (Get-QlLabelValue -Labels $t.labels -Key 'qls.key')
                logPath = [string]$t.log_path
                lastRun = if ($t.last_execution_time) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$t.last_execution_time).LocalDateTime).ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
                updatedAt = $t.updatedAt
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'script.list' {
            $tree = Get-QlScriptTree
            $files = @($tree | Where-Object { $_.type -eq 'file' })
            $dirs  = @($tree | Where-Object { $_.type -eq 'directory' })
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                dirCount  = $dirs.Count
                fileCount = $files.Count
                directories = @($dirs | ForEach-Object { $_.key })
                files = @($files | ForEach-Object { [ordered]@{ key = $_.key; size = $_.size } })
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'script.get' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'script.get 需要 -Key（形如 BI/bi_pivot.js）' }
            $c = Get-QlScriptContent -Key $Key
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                key     = $Key
                length  = $c.Length
                content = if ($Full) { $c } else { (Limit-QlLogText -Text $c -Tail 3000) }
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'log.list' {
            if ($Id -le 0) { throw 'log.list 需要 -Id' }
            $files = @(Get-QlTaskLogFiles -Id $Id)
            $take = $files
            if ($Limit -gt 0 -and $files.Count -gt $Limit) { $take = $files[0..($Limit - 1)] }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                id = $Id
                logFileCount = $files.Count
                newest = if ($files.Count -gt 0) { $files[0].filename } else { $null }
                oldest = if ($files.Count -gt 0) { $files[$files.Count - 1].filename } else { $null }
                files  = @($take)
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'log.tail' {
            if ($Id -le 0) { throw 'log.tail 需要 -Id' }
            $text = Get-QlTaskLatestLog -Id $Id
            $facts = Get-QlLogFacts -LogText $text
            Add-QlWarning '日志由业务脚本产出，可能含连接串或客户数据，已截断。'
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                id = $Id
                facts = $facts
                content = (Limit-QlLogText -Text $text)
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'state.diff' {
            $tasks = Get-QlTasks
            $rows = @(Get-QlStateReport -Tasks $tasks)
            $pending = @($rows | Where-Object { $_.action -ne 'no-op' })
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                desiredCount = @(Get-QlDesiredKeys).Count
                pendingCount = $pending.Count
                rows = $rows
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'state.orphans' {
            $tasks = Get-QlTasks
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                orphans = @(Get-QlOrphans -Tasks $tasks)
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'diagnose' {
            $tasks = Get-QlTasks
            # 空数组经函数边界会被解包成 $null，统一用 @() 兜回数组
            $sf = @(Get-QlScheduleFormatRisks -Tasks $tasks)
            $report = [ordered]@{
                total           = @($tasks).Count
                enabled         = @($tasks | Where-Object { [int]$_.isDisabled -eq 0 }).Count
                disabled        = @($tasks | Where-Object { [int]$_.isDisabled -ne 0 }).Count
                scheduleFormat  = $sf
                concurrency     = (Get-QlConcurrencyReport -Tasks $tasks -Threshold $Threshold)
                stale           = @(Get-QlStaleReport -Tasks $tasks)
                stateDiff       = @(Get-QlStateReport -Tasks $tasks | Where-Object { $_.action -ne 'no-op' })
                orphans         = @(Get-QlOrphans -Tasks $tasks)
            }
            Set-QlEnvelope -Name 'result' -Value $report
            if ($sf.Count -gt 0) { Add-QlWarning '存在非 6 段 cron 任务，本部署下 5 段不触发。' }
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        # ---------------- level 1 ----------------
        'task.create' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.create 需要 -Key' }
            $d = Get-QlDesired -Key $Key
            $actual = Get-QlTaskByKey -Key $Key
            if ($null -ne $actual) { throw "任务已存在（id=$($actual.id)），改用 task.update" }
            $plan = [ordered]@{
                action = 'create'; key = $Key
                desired = $d
                wire   = (New-QlTaskWireBody -Desired $d -Actual $null)
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            $created = New-QlTask -Desired $d
            $id = [int](Get-QlProp -Object $created -Name 'id' -Default 0)
            if ($id -le 0) { throw '创建接口未返回任务 id，无法继续' }
            $wantEnabled = $true
            if ($null -ne $d.enabled) { $wantEnabled = [bool]$d.enabled }
            if (-not $wantEnabled) { Set-QlTaskEnabled -Id $id -Enabled $false | Out-Null }
            $final = Invoke-QlVerifyTask -TargetKey $Key -Expect 'present'
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                action = 'created'; id = [int]$final.id; name = [string]$final.name
                enabled = ([int]$final.isDisabled -eq 0)
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.update' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.update 需要 -Key' }
            $d = Get-QlDesired -Key $Key
            $actual = Get-QlTaskByKey -Key $Key
            if ($null -eq $actual) { throw "任务不存在，改用 task.create" }
            $diff = @(Compare-QlTask -Desired $d -Actual $actual)
            if ($diff.Count -eq 0) {
                Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'no-op'; id = [int]$actual.id })
                Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
                exit 0
            }
            $plan = [ordered]@{
                action = 'update'; key = $Key; id = [int]$actual.id
                actualDigest = (Get-QlActualDigest -Actual $actual)
                diff = $diff
                wire = (New-QlTaskWireBody -Desired $d -Actual $actual)
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            $now = Get-QlTaskByKey -Key $Key
            if ((Get-QlActualDigest -Actual $now) -ne $plan.actualDigest) {
                Add-QlError '计划后任务已被改动，拒绝执行。'
                Write-QlEnvelope -Status 'plan-drift' -Ok $false
                exit 4
            }
            Set-QlTask -Desired $d -Actual $now | Out-Null
            $wantEnabled = $true
            if ($null -ne $d.enabled) { $wantEnabled = [bool]$d.enabled }
            if (([int]$now.isDisabled -eq 0) -ne $wantEnabled) {
                Set-QlTaskEnabled -Id ([int]$now.id) -Enabled $wantEnabled | Out-Null
            }
            $final = Invoke-QlVerifyTask -TargetKey $Key -Expect 'present'
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                action = 'updated'; id = [int]$final.id; appliedDiff = $diff
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        # 纳管：把平台上已存在、但未标记 qls.* 的任务收编进期望态管理。
        # 必须先有 tasks/<key>.json；name + command 与平台完全一致才放行，防止把 key 挂错任务。
        'task.adopt' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.adopt 需要 -Key' }
            if ($Id -le 0) { throw 'task.adopt 需要 -Id（平台上已存在任务的 id）' }
            $d = Get-QlDesired -Key $Key
            $tasks = Get-QlTasks
            $actual = Get-QlTaskById -Id $Id -Tasks $tasks
            if ($null -eq $actual) { throw "平台上找不到 id=$Id 的任务" }
            if (Test-QlManaged -Task $actual) {
                $owner = Get-QlLabelValue -Labels $actual.labels -Key 'qls.key'
                throw "id=$Id 已被纳管（qls.key=$owner），改用 task.update"
            }
            $holder = Get-QlTaskByKey -Key $Key -Tasks $tasks
            if ($null -ne $holder) { throw "key=$Key 已被 id=$($holder.id) 占用，不能重复纳管" }
            if (([string]$actual.name).Trim() -ne ([string]$d.name).Trim()) {
                throw "身份不匹配：平台 id=$Id 的 name='$([string]$actual.name)'，期望态声明 '$([string]$d.name)'。拒绝纳管。"
            }
            if (([string]$actual.command).Trim() -ne ([string]$d.command).Trim()) {
                throw "身份不匹配：平台 id=$Id 的 command='$([string]$actual.command)'，期望态声明 '$([string]$d.command)'。拒绝纳管。"
            }
            # 写盘是整体替换 labels，非 qls.* 标签会被丢掉，宁可拒绝也不静默丢数据
            $foreign = @(@($actual.labels) | Where-Object { -not ([string]$_).StartsWith($script:QlLabelPrefix) })
            if ($foreign.Count -gt 0) {
                throw "id=$Id 带有本技能命名空间外的标签（$($foreign -join '、')）。纳管会整体替换 labels，拒绝静默丢弃，请人工处理后重试。"
            }
            $plan = [ordered]@{
                action = 'adopt'; key = $Key; id = $Id
                name = [string]$actual.name
                command = [string]$actual.command
                scheduleBefore = [string]$actual.schedule
                actualDigest = (Get-QlActualDigest -Actual $actual)
                diff = @(Compare-QlTask -Desired $d -Actual $actual)
                wire = (New-QlTaskWireBody -Desired $d -Actual $actual)
                note = '纳管后该任务纳入期望态管理，此后变更走 task.update'
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            $now = Get-QlTaskById -Id $Id
            if ((Get-QlActualDigest -Actual $now) -ne $plan.actualDigest) {
                Add-QlError '计划后任务已被改动，拒绝纳管。'
                Write-QlEnvelope -Status 'plan-drift' -Ok $false
                exit 4
            }
            Set-QlTask -Desired $d -Actual $now | Out-Null
            $wantEnabled = $true
            if ($null -ne $d.enabled) { $wantEnabled = [bool]$d.enabled }
            if (([int]$now.isDisabled -eq 0) -ne $wantEnabled) {
                Set-QlTaskEnabled -Id $Id -Enabled $wantEnabled | Out-Null
            }
            $final = Invoke-QlVerifyTask -TargetKey $Key -Expect 'present'
            if ([int]$final.id -ne $Id) { throw "回读校验失败：纳管后落到 id=$([int]$final.id)，预期 $Id" }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                action = 'adopted'; key = $Key; id = [int]$final.id
                name = [string]$final.name
                schedule = [string]$final.schedule
                enabled = ([int]$final.isDisabled -eq 0)
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.enable' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.enable 需要 -Key' }
            $actual = Get-QlTaskByKey -Key $Key
            if ($null -eq $actual) { throw "找不到任务：$Key" }
            if ([int]$actual.isDisabled -eq 0) {
                Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'no-op'; id = [int]$actual.id; enabled = $true })
                Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
                exit 0
            }
            $plan = [ordered]@{ action = 'enable'; key = $Key; id = [int]$actual.id; name = [string]$actual.name }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            Set-QlTaskEnabled -Id ([int]$actual.id) -Enabled $true | Out-Null
            $final = Get-QlTaskByKey -Key $Key
            if ([int]$final.isDisabled -ne 0) { throw '回读校验失败：任务仍未启用' }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'enabled'; id = [int]$final.id })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.disable' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.disable 需要 -Key' }
            $actual = Get-QlTaskByKey -Key $Key
            if ($null -eq $actual) { throw "找不到任务：$Key" }
            if ([int]$actual.isDisabled -ne 0) {
                Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'no-op'; id = [int]$actual.id; enabled = $false })
                Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
                exit 0
            }
            $plan = [ordered]@{ action = 'disable'; key = $Key; id = [int]$actual.id; name = [string]$actual.name }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            Set-QlTaskEnabled -Id ([int]$actual.id) -Enabled $false | Out-Null
            $final = Get-QlTaskByKey -Key $Key
            if ([int]$final.isDisabled -eq 0) { throw '回读校验失败：任务仍未停用' }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'disabled'; id = [int]$final.id })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'script.new' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'script.new 需要 -Key（形如 dir/file.js）' }
            if ([string]::IsNullOrWhiteSpace($ContentFile)) { throw 'script.new 需要 -ContentFile' }
            $src = (Resolve-Path -LiteralPath $ContentFile).Path
            $content = [System.IO.File]::ReadAllText($src)
            $existing = $null
            try { $existing = Get-QlScriptContent -Key $Key } catch { $existing = $null }
            if ($null -ne $existing) { throw "远端脚本已存在：$Key。覆盖请用 script.put。" }
            $plan = [ordered]@{
                action        = 'script.new'
                key           = $Key
                sourceFile    = $src
                contentLength = $content.Length
                contentDigest = (Get-QlPlanDigest -PlanObject ([ordered]@{ c = $content }))
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            New-QlScript -Key $Key -Content $content | Out-Null
            $after = Get-QlScriptContent -Key $Key
            if ($after.Length -ne $content.Length) {
                throw ("回读校验失败：写入后长度 {0} != 本地 {1}" -f $after.Length, $content.Length)
            }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'script-created'; key = $Key; length = $after.Length })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'script.put' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'script.put 需要 -Key（形如 BI/bi_pivot.js）' }
            if ([string]::IsNullOrWhiteSpace($ContentFile)) { throw 'script.put 需要 -ContentFile' }
            $src = (Resolve-Path -LiteralPath $ContentFile).Path
            $content = [System.IO.File]::ReadAllText($src)
            $existing = $null
            try { $existing = Get-QlScriptContent -Key $Key } catch { $existing = $null }
            if ($null -eq $existing) { throw "远端脚本不存在或读不到：$Key。新建请用 POST，本技能暂不自动新建生产脚本。" }
            $plan = [ordered]@{
                action = 'script.put'; key = $Key
                sourceFile = $src
                remoteLength = $existing.Length
                localLength  = $content.Length
                remoteDigest = (Get-QlPlanDigest -PlanObject ([ordered]@{ c = $existing }))
                localDigest  = (Get-QlPlanDigest -PlanObject ([ordered]@{ c = $content }))
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            $now = Get-QlScriptContent -Key $Key
            if ((Get-QlPlanDigest -PlanObject ([ordered]@{ c = $now })) -ne $plan.remoteDigest) {
                Add-QlError '计划后远端脚本已被改动，拒绝覆盖。'
                Write-QlEnvelope -Status 'plan-drift' -Ok $false
                exit 4
            }
            Set-QlScriptContent -Key $Key -Content $content | Out-Null
            $after = Get-QlScriptContent -Key $Key
            if ($after.Length -ne $content.Length) {
                throw ("回读校验失败：写入后长度 {0} != 本地 {1}" -f $after.Length, $content.Length)
            }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'script-updated'; key = $Key; length = $after.Length })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        # ---------------- level 2 ----------------
        'script.delete' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'script.delete 需要 -Key（形如 dir/file.js）' }
            if (-not (Test-QlScriptExists -Key $Key)) { throw "远端脚本不存在：$Key" }
            $content = Get-QlScriptContent -Key $Key
            # 有任务引用该脚本时，删除等于打断生产任务
            $refs = @(Get-QlTasks | Where-Object { ([string]$_.command).Trim() -eq $Key })
            if ($refs.Count -gt 0 -and -not $Force) {
                $names = ($refs | ForEach-Object { "$([int]$_.id)/$([string]$_.name)" }) -join '、'
                throw "仍有 $($refs.Count) 个任务引用该脚本（$names），拒绝删除。确需删除请显式加 -Force，并先改掉这些任务的 command。"
            }
            $plan = [ordered]@{
                action        = 'script.delete'
                key           = $Key
                contentLength = $content.Length
                contentDigest = (Get-QlPlanDigest -PlanObject ([ordered]@{ c = $content }))
                referencedBy  = @($refs | ForEach-Object { [ordered]@{ id = [int]$_.id; name = [string]$_.name } })
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            $now = $null
            try { $now = Get-QlScriptContent -Key $Key } catch { $now = $null }
            if ($null -eq $now) { throw '脚本已不存在' }
            if ((Get-QlPlanDigest -PlanObject ([ordered]@{ c = $now })) -ne $plan.contentDigest) {
                Add-QlError '计划后远端脚本已被改动，拒绝删除。'
                Write-QlEnvelope -Status 'plan-drift' -Ok $false
                exit 4
            }
            Remove-QlScript -Key $Key | Out-Null
            # 平台对不存在的文件也回 200，只能靠回读判定
            if (Test-QlScriptExists -Key $Key) { throw "回读校验失败：$Key 删除后仍存在" }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'script-deleted'; key = $Key })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.delete' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.delete 需要 -Key。本技能不提供批量删除。' }
            $actual = Get-QlTaskByKey -Key $Key
            if ($null -eq $actual) { throw "找不到任务：$Key" }
            $managed = Test-QlManaged -Task $actual
            if (-not $managed -and -not $Force) {
                throw "任务 $Key 未标记 qls.managed-by=ai，非本技能纳管对象，拒绝删除。确需删除请显式加 -Force。"
            }
            $plan = [ordered]@{
                action = 'delete'; key = $Key; id = [int]$actual.id
                name = [string]$actual.name; command = [string]$actual.command
                schedule = [string]$actual.schedule
                managed = $managed
                actualDigest = (Get-QlActualDigest -Actual $actual)
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            $now = Get-QlTaskByKey -Key $Key
            if ($null -eq $now) { throw '任务已不存在' }
            if ((Get-QlActualDigest -Actual $now) -ne $plan.actualDigest) {
                Add-QlError '计划后任务已被改动，拒绝删除。'
                Write-QlEnvelope -Status 'plan-drift' -Ok $false
                exit 4
            }
            Remove-QlTask -Ids @([int]$now.id) | Out-Null
            Invoke-QlVerifyTask -TargetKey $Key -Expect $null | Out-Null
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'deleted'; id = $plan.id; name = $plan.name })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        'task.run' {
            if ([string]::IsNullOrWhiteSpace($Key)) { throw 'task.run 需要 -Key' }
            $actual = Get-QlTaskByKey -Key $Key
            if ($null -eq $actual) { throw "找不到任务：$Key" }
            $plan = [ordered]@{
                action = 'run-now'; key = $Key; id = [int]$actual.id
                name = [string]$actual.name; command = [string]$actual.command
                note = '立即执行，非计划触发'
                actualDigest = (Get-QlActualDigest -Actual $actual)
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            Start-QlTask -Id ([int]$actual.id) | Out-Null
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{
                action = 'triggered'; id = [int]$actual.id
                note = '已提交立即执行；状态请用 log.list / log.tail 查证'
            })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $false
            exit 0
        }

        'state.reconcile' {
            $tasks = Get-QlTasks
            $rows = @(Get-QlStateReport -Tasks $tasks)
            $pending = @($rows | Where-Object { $_.action -ne 'no-op' })
            if ($pending.Count -eq 0) {
                Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'no-op'; total = $rows.Count })
                Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
                exit 0
            }
            $plan = [ordered]@{
                action = 'reconcile'
                creates = @($pending | Where-Object { $_.action -eq 'create' } | ForEach-Object { $_.key })
                updates = @($pending | Where-Object { $_.action -eq 'update' } | ForEach-Object { [ordered]@{ key = $_.key; id = $_.platformId; diff = $_.diff; actualDigest = (Get-QlActualDigest -Actual (Get-QlTaskByKey -Key $_.key -Tasks $tasks)) } })
                note    = '只做 create / update，不删除任何任务'
            }
            if (-not (Test-QlPlanConfirmed -Plan $plan)) { }
            # 计划里记录了每条的 actualDigest，执行前逐条比对；不符则跳过该条而不是整体回滚
            $plannedUpdate = @{}
            foreach ($u in $plan.updates) { $plannedUpdate[$u.key] = $u.actualDigest }

            $done = New-Object System.Collections.Generic.List[object]
            foreach ($row in $pending) {
                $d = Get-QlDesired -Key $row.key
                if ($row.action -eq 'create') {
                    $c = New-QlTask -Desired $d
                    $newId = [int](Get-QlProp -Object $c -Name 'id' -Default 0)
                    if ($newId -le 0) {
                        Add-QlError ("$($row.key) 创建接口未返回 id，已跳过")
                        continue
                    }
                    $wantEnabled = $true
                    if ($null -ne $d.enabled) { $wantEnabled = [bool]$d.enabled }
                    if (-not $wantEnabled) { Set-QlTaskEnabled -Id $newId -Enabled $false | Out-Null }
                    $done.Add([ordered]@{ key = $row.key; action = 'created'; id = $newId })
                    continue
                }
                $now = Get-QlTaskByKey -Key $row.key
                if ((Get-QlActualDigest -Actual $now) -ne $plannedUpdate[$row.key]) {
                    Add-QlWarning ("$($row.key) 状态在计划后变化，已跳过")
                    continue
                }
                Set-QlTask -Desired $d -Actual $now | Out-Null
                $wantEnabled = $true
                if ($null -ne $d.enabled) { $wantEnabled = [bool]$d.enabled }
                if (([int]$now.isDisabled -eq 0) -ne $wantEnabled) {
                    Set-QlTaskEnabled -Id ([int]$now.id) -Enabled $wantEnabled | Out-Null
                }
                $done.Add([ordered]@{ key = $row.key; action = 'updated'; id = [int]$now.id })
            }
            Set-QlEnvelope -Name 'result' -Value ([ordered]@{ action = 'reconciled'; changes = $done })
            Write-QlEnvelope -Status 'ok' -Ok $true -Verified $true
            exit 0
        }

        default {
            throw "未实现的动词：$Verb"
        }
    }
} catch {
    if ($null -eq $script:QlEnvelope) { Initialize-QlEnvelope -Verb $Verb -Level 0 }
    Add-QlError (Protect-QlText $_.Exception.Message)
    Write-QlEnvelope -Status 'failed' -Ok $false
    exit 1
}
