Set-StrictMode -Version Latest

$script:PlanPackageStatuses = @('READY_FOR_APPROVAL','APPROVED','REJECTED','CHANGES_REQUESTED','SUPERSEDED')
$script:ItemKinds = @('decision','risk','acceptance_criteria','package')

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-CanonicalObject {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in ($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            $result[$key] = ConvertTo-CanonicalObject $Value[$key]
        }
        return ,$result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in ($Value.PSObject.Properties | Sort-Object Name)) {
            $result[$property.Name] = ConvertTo-CanonicalObject $property.Value
        }
        return ,$result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @()
        foreach ($item in $Value) { $items += ,(ConvertTo-CanonicalObject $item) }
        return ,$items
    }
    return $Value
}

function Get-CanonicalJson {
    param($Value)
    $canonical = ConvertTo-CanonicalObject $Value
    return (ConvertTo-Json -InputObject $canonical -Depth 100 -Compress)
}

function Get-ObjectSha256 {
    param($Value)
    $json = Get-CanonicalJson $Value
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PlanPackageSha256 {
    param([Parameter(Mandatory)]$Package)
    $copy = [ordered]@{}
    foreach ($property in $Package.PSObject.Properties) {
        if ($property.Name -ne 'plan_package_sha256') {
            $copy[$property.Name] = $property.Value
        }
    }
    return Get-ObjectSha256 ([pscustomobject]$copy)
}

function Write-Utf8Atomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($temp, $Content, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    Write-Utf8Atomic -Path $Path -Content (($Value | ConvertTo-Json -Depth 100) + "`r`n")
}

function Assert-RelativePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path must not be empty' }
    if ([System.IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)') { throw "Path must remain project-relative: $Path" }
}

function Assert-Sha256 {
    param([AllowNull()][string]$Hash, [Parameter(Mandatory)][string]$Name)
    if (-not [string]::IsNullOrWhiteSpace($Hash) -and $Hash -notmatch '^[0-9a-fA-F]{64}$') { throw "$Name must be a SHA-256 hex string" }
}

function Assert-StableId {
    param($Item, [Parameter(Mandatory)][string]$Context)
    if ($null -eq $Item.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$Item.id)) { throw "$Context requires a stable id" }
}

function Test-DependencyGraph {
    param([Parameter(Mandatory)]$Packages)
    $packages = @($Packages)
    $ids = @($packages | ForEach-Object { [string]$_.id })
    if (@($ids).Count -lt 1 -or @($ids).Count -gt 5) { throw 'packages must contain 1 to 5 items' }
    if (@($ids | Sort-Object -Unique).Count -ne @($ids).Count) { throw 'package IDs must be unique' }
    $known = @{}; foreach ($id in $ids) { $known[$id] = $true }
    foreach ($package in $packages) {
        foreach ($dependency in @($package.depends_on)) {
            if ([string]::IsNullOrWhiteSpace([string]$dependency) -or -not $known.ContainsKey([string]$dependency)) { throw "Unknown dependency '$dependency' in package '$($package.id)'" }
            if ([string]$dependency -eq [string]$package.id) { throw "Package cannot depend on itself: $($package.id)" }
        }
    }
    $visiting = @{}; $visited = @{}
    function Visit([string]$id) {
        if ($visiting.ContainsKey($id)) { throw "Dependency cycle detected at: $id" }
        if ($visited.ContainsKey($id)) { return }
        $visiting[$id] = $true
        $package = $packages | Where-Object { [string]$_.id -eq $id }
        foreach ($dependency in @($package.depends_on)) { Visit ([string]$dependency) }
        $visiting.Remove($id); $visited[$id] = $true
    }
    foreach ($id in $ids) { Visit $id }
}

function Test-PlanPackage {
    param([Parameter(Mandatory)]$Package)
    foreach ($field in @('schema_version','plan_package_id','spec','package_revision','status','packages','total_packages','package_root','package_path','project_root','request_slug','created_at','source_proposal_sha256')) {
        if ($null -eq $Package.PSObject.Properties[$field]) { throw "Missing package field: $field" }
    }
    if ([string]$Package.status -notin $script:PlanPackageStatuses) { throw "Invalid package status: $($Package.status)" }
    if ([int]$Package.package_revision -lt 1) { throw 'package_revision must be at least 1' }
    if ([int]$Package.spec.revision -ne [int]$Package.package_revision) { throw 'spec.revision must match package_revision' }
    if ([string]::IsNullOrWhiteSpace([string]$Package.spec.spec_id) -or [string]::IsNullOrWhiteSpace([string]$Package.spec.project_id) -or [string]::IsNullOrWhiteSpace([string]$Package.spec.evidence_baseline)) { throw 'spec requires spec_id, project_id, and evidence_baseline' }
    if ([string]$Package.request_slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or [string]$Package.request_slug -match '(^|-)\.(\.|$)') { throw 'request_slug must be lowercase kebab-case' }
    Assert-Sha256 $Package.source_proposal_sha256 'source_proposal_sha256'
    if ($null -ne $Package.spec.PSObject.Properties['sha256']) { Assert-Sha256 $Package.spec.sha256 'spec.sha256' }
    if ($null -ne $Package.PSObject.Properties['plan_package_sha256'] -and $null -ne $Package.plan_package_sha256) { Assert-Sha256 $Package.plan_package_sha256 'plan_package_sha256' }
    $packagesProperty = $Package.PSObject.Properties['packages']
    if ($null -eq $packagesProperty) { throw 'Missing package field: packages' }
    $packagesValue = @($packagesProperty.Value)
    if ($null -eq $Package.PSObject.Properties['total_packages'] -or [int]$Package.total_packages -ne $packagesValue.Count) { throw 'total_packages does not match packages' }

    foreach ($section in @('summary','current_state','target_state','behavior','business_rules','scope','risks','technical_direction','reference_code_assessment','open_decisions','acceptance_criteria','implementation_boundary')) {
        if ($null -eq $Package.PSObject.Properties[$section]) { throw "Missing plan section: $section" }
    }

    $allIds = @()
    foreach ($decision in @($Package.open_decisions)) {
        Assert-StableId $decision 'open_decisions item'
        $allIds += [string]$decision.id
        if ([string]$decision.resolution -notin @('auto-resolved','user-required')) { throw "Invalid Decision resolution: $($decision.id)" }
        if ($null -eq $decision.PSObject.Properties['blocking'] -or $decision.blocking -isnot [bool]) { throw "Decision blocking must be boolean: $($decision.id)" }
    }
    foreach ($risk in @($Package.risks)) { Assert-StableId $risk 'risks item'; $allIds += [string]$risk.id }
    foreach ($criterion in @($Package.acceptance_criteria)) { Assert-StableId $criterion 'acceptance_criteria item'; $allIds += [string]$criterion.id }
    foreach ($package in $packagesValue) {
        Assert-StableId $package 'package item'; $allIds += [string]$package.id
        foreach ($field in @('name','skill','domain','layer','depends_on','manifest','boundaries','contract')) { if ($null -eq $package.PSObject.Properties[$field]) { throw "Package $($package.id) missing $field" } }
        foreach ($manifestField in @('knowledge','rules','packs','patterns')) {
            if ($null -eq $package.manifest.PSObject.Properties[$manifestField]) { throw "Package $($package.id) manifest missing $manifestField" }
            foreach ($path in @($package.manifest.$manifestField)) { Assert-RelativePath ([string]$path) }
        }
        foreach ($boundaryField in @('allow_read','allow_write','forbid')) {
            if ($null -eq $package.boundaries.PSObject.Properties[$boundaryField]) { throw "Package $($package.id) boundaries missing $boundaryField" }
            foreach ($path in @($package.boundaries.$boundaryField)) { Assert-RelativePath ([string]$path) }
        }
        foreach ($contractField in @('in_scope','out_of_scope','expected_files','stop_condition')) { if ($null -eq $package.contract.PSObject.Properties[$contractField]) { throw "Package $($package.id) contract missing $contractField" } }
    }
    if (@($allIds | Sort-Object -Unique).Count -ne @($allIds).Count) { throw 'Plan item IDs must be unique' }
    Test-DependencyGraph -Packages $packagesValue
    return $true
}

Export-ModuleMember -Function Get-FileSha256,Get-CanonicalJson,Get-ObjectSha256,Get-PlanPackageSha256,Write-Utf8Atomic,Write-JsonAtomic,Assert-RelativePath,Assert-Sha256,Test-DependencyGraph,Test-PlanPackage
