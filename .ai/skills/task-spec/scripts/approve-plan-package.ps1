[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackagePath,
    [Parameter(Mandatory)][ValidateSet('APPROVED','REJECTED','CHANGES_REQUESTED')][string]$Decision,
    [string]$ApprovalInputPath,
    [string]$Actor = 'local-user',
    [string]$Statement = ''
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlanPackage.psm1') -Force

function Test-HasProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Assert-RequiredMetadata {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string]$Label)
    foreach ($name in $Names) {
        if (-not (Test-HasProperty $Object $name) -or $null -eq $Object.$name -or ([string]$Object.$name).Length -eq 0) {
            throw "$Label requires $name"
        }
    }
}

function ConvertTo-ApprovalTimestamp {
    param($Value, [Parameter(Mandatory)][string]$Label, [switch]$Required)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        if ($Required) { throw "$Label is required" }
        return $null
    }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Value, [ref]$parsed)) { throw "$Label is not a valid timestamp" }
    return $parsed.ToUniversalTime().ToString('o')
}

function Test-SamePath {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $leftPath = [IO.Path]::GetFullPath($Left).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rightPath = [IO.Path]::GetFullPath($Right).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [string]::Equals($leftPath, $rightPath, [StringComparison]::OrdinalIgnoreCase)
}

function Get-NormalizedItemComments {
    param($Items, [Parameter(Mandatory)]$ValidItems, [Parameter(Mandatory)][string]$SourceName)
    $result = @()
    foreach ($item in @($Items)) {
        if ($null -eq $item) { throw "$SourceName contains a null item" }
        Assert-RequiredMetadata $item @('id') "$SourceName item"
        $id = [string]$item.id
        if (-not $ValidItems.ContainsKey($id)) { throw "Unknown feedback item: $id" }
        if (-not (Test-HasProperty $item 'comment')) { throw "$SourceName item '$id' requires comment" }
        $comment = [string]$item.comment
        if ([string]::IsNullOrWhiteSpace($comment)) { continue }
        if (Test-HasProperty $item 'actor') {
            if ([string]::IsNullOrWhiteSpace([string]$item.actor)) { throw "$SourceName item '$id' has an empty actor" }
        }
        $commentedAt = $null
        if (Test-HasProperty $item 'commented_at') { $commentedAt = ConvertTo-ApprovalTimestamp $item.commented_at "$SourceName item '$id' commented_at" }
        elseif (Test-HasProperty $item 'decided_at') { $commentedAt = ConvertTo-ApprovalTimestamp $item.decided_at "$SourceName item '$id' decided_at" }
        $normalized = [ordered]@{ id = $id; comment = $comment }
        if (Test-HasProperty $item 'actor') { $normalized.actor = [string]$item.actor }
        if ($commentedAt) { $normalized.commented_at = $commentedAt }
        $result += ,$normalized
    }
    return $result
}

function Assert-CurrentPointer {
    param(
        [Parameter(Mandatory)]$Pointer,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$ActualHash,
        [Parameter(Mandatory)][string[]]$AllowedStatuses
    )
    Assert-RequiredMetadata $Pointer @('spec_id','revision','path','status','plan_package_sha256') 'current.json'
    if ([string]$Pointer.spec_id -ne [string]$Package.spec.spec_id -or [int]$Pointer.revision -ne [int]$Package.package_revision) {
        throw 'current.json does not point to this package revision'
    }
    if (-not (Test-SamePath ([string]$Pointer.path) $PackageRoot)) { throw 'current.json path does not match package path' }
    if ([string]$Pointer.plan_package_sha256 -ne $ActualHash) { throw 'current.json hash does not match package hash' }
    if ([string]$Pointer.status -notin $AllowedStatuses) { throw "current.json status is inconsistent: $($Pointer.status)" }
}

function Assert-ApprovedPointer {
    param([Parameter(Mandatory)]$Pointer, [Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$SpecRoot)
    Assert-RequiredMetadata $Pointer @('spec_id','revision','path','status','package_sha256') 'approved.json'
    if ([string]$Pointer.spec_id -ne [string]$Package.spec.spec_id) { throw 'approved.json spec_id does not match package spec_id' }
    if ([string]$Pointer.status -ne 'APPROVED') { throw "approved.json has invalid status: $($Pointer.status)" }
    if ([int]$Pointer.revision -lt 1) { throw 'approved.json has invalid revision' }
    if ([int]$Pointer.revision -gt [int]$Package.package_revision) { throw 'approved.json points to a later revision than current.json' }
    $pointerPath = [IO.Path]::GetFullPath([string]$Pointer.path)
    $specRootPath = [IO.Path]::GetFullPath($SpecRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $pointerPath.StartsWith($specRootPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'approved.json path is outside the package root' }
}

function Write-TerminalPointers {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$PackageRoot,
        [Parameter(Mandatory)][string]$SpecRoot,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$ActualHash,
        $ExistingApproved
    )
    if ($Status -eq 'APPROVED' -and $null -ne $ExistingApproved -and [int]$ExistingApproved.revision -eq [int]$Package.package_revision) {
        if (-not (Test-SamePath ([string]$ExistingApproved.path) $PackageRoot) -or [string]$ExistingApproved.package_sha256 -ne $ActualHash) {
            throw 'approved.json conflicts with this approved revision'
        }
    }
    $currentValue = [ordered]@{
        spec_id = $Package.spec.spec_id
        revision = $Package.package_revision
        path = $PackageRoot
        status = $Status
        plan_package_sha256 = $ActualHash
    }
    Write-JsonAtomic -Path (Join-Path $SpecRoot 'current.json') -Value $currentValue
    if ($Status -eq 'APPROVED') {
        Write-JsonAtomic -Path (Join-Path $SpecRoot 'approved.json') -Value ([ordered]@{
            spec_id = $Package.spec.spec_id
            revision = $Package.package_revision
            path = $PackageRoot
            status = 'APPROVED'
            package_sha256 = $ActualHash
        })
    }
}

$packageFile = if ((Test-Path -LiteralPath $PackagePath -PathType Leaf) -and ([IO.Path]::GetFileName($PackagePath) -eq 'plan-package.json')) {
    [IO.Path]::GetFullPath($PackagePath)
} else {
    Join-Path ([IO.Path]::GetFullPath($PackagePath)) 'plan-package.json'
}
if (-not (Test-Path -LiteralPath $packageFile -PathType Leaf)) { throw "Package file not found: $packageFile" }
$packageRoot = Split-Path -Parent $packageFile
$specRoot = Split-Path -Parent $packageRoot
$package = Get-Content -LiteralPath $packageFile -Raw -Encoding UTF8 | ConvertFrom-Json
Test-PlanPackage $package | Out-Null
$actualHash = Get-PlanPackageSha256 $package
if ([string]$package.plan_package_sha256 -ne $actualHash) { throw 'Package hash is invalid' }
if ([string]$package.status -ne 'READY_FOR_APPROVAL') { throw "Package is not ready for approval: $($package.status)" }

$approvalFile = Join-Path $packageRoot 'approval.json'
if (-not (Test-Path -LiteralPath $approvalFile -PathType Leaf)) { throw "Approval metadata not found: $approvalFile" }
$current = Get-Content -LiteralPath $approvalFile -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-RequiredMetadata $current @('schema_version','spec_id','package_revision','package_sha256','status') 'approval.json'
if ([string]$current.schema_version -ne '1.0') { throw "Unsupported approval.json schema_version: $($current.schema_version)" }
if ([string]$current.spec_id -ne [string]$package.spec.spec_id -or [int]$current.package_revision -ne [int]$package.package_revision -or [string]$current.package_sha256 -ne $actualHash) {
    throw 'Existing approval metadata does not match package identity, revision, or hash'
}
if ([string]$current.status -notin @('PENDING','APPROVED','REJECTED','CHANGES_REQUESTED')) { throw "Invalid existing approval status: $($current.status)" }
if ([string]$current.status -eq 'APPROVED') {
    if (-not (Test-HasProperty $current 'approved_revision') -or [int]$current.approved_revision -ne [int]$package.package_revision) { throw 'Existing approval has an invalid approved_revision' }
} elseif ((Test-HasProperty $current 'approved_revision') -and $null -ne $current.approved_revision) {
    throw "Existing $($current.status) approval must not have approved_revision"
}
if ([string]$current.status -ne 'PENDING') {
    Assert-RequiredMetadata $current @('actor','decided_at') 'sealed approval.json'
    ConvertTo-ApprovalTimestamp $current.decided_at 'approval.json decided_at' -Required | Out-Null
}

$currentPointerFile = Join-Path $specRoot 'current.json'
if (-not (Test-Path -LiteralPath $currentPointerFile -PathType Leaf)) { throw "Current pointer not found: $currentPointerFile" }
$currentPointer = Get-Content -LiteralPath $currentPointerFile -Raw -Encoding UTF8 | ConvertFrom-Json
$approvedPointerFile = Join-Path $specRoot 'approved.json'
$approvedPointer = if (Test-Path -LiteralPath $approvedPointerFile -PathType Leaf) { Get-Content -LiteralPath $approvedPointerFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
if ($null -ne $approvedPointer) { Assert-ApprovedPointer $approvedPointer $package $specRoot }

$input = $null
$itemDecisions = @()
$itemComments = @()
$inputDecidedAt = $null
if ($ApprovalInputPath) {
    $inputFile = [IO.Path]::GetFullPath($ApprovalInputPath)
    if (-not (Test-Path -LiteralPath $inputFile -PathType Leaf)) { throw "Approval input not found: $inputFile" }
    $input = Get-Content -LiteralPath $inputFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-RequiredMetadata $input @('schema_version','spec_id','package_revision','package_sha256','decision') 'Approval input'
    if ([string]$input.schema_version -ne '1.0') { throw "Unsupported approval input schema_version: $($input.schema_version)" }
    if ([string]$input.spec_id -ne [string]$package.spec.spec_id -or [int]$input.package_revision -ne [int]$package.package_revision -or [string]$input.package_sha256 -ne $actualHash) {
        throw 'Approval input does not match package identity, revision, or hash'
    }
    if ([string]$input.decision -ne $Decision) { throw 'Approval input decision does not match -Decision' }
    if (Test-HasProperty $input 'actor') { $Actor = [string]$input.actor }
    if (Test-HasProperty $input 'statement') { $Statement = [string]$input.statement }
    if (Test-HasProperty $input 'decided_at') { $inputDecidedAt = ConvertTo-ApprovalTimestamp $input.decided_at 'Approval input decided_at' }
}
if ([string]::IsNullOrWhiteSpace($Actor)) { throw 'Approval actor is required' }
$Actor = $Actor.Trim()
$Statement = if ($null -eq $Statement) { '' } else { [string]$Statement }

$validItems = @{}
$decisionItems = @{}
foreach ($item in @($package.open_decisions)) {
    $id = [string]$item.id
    if (-not [string]::IsNullOrWhiteSpace($id)) { $validItems[$id] = 'decision'; $decisionItems[$id] = $item }
}
foreach ($item in @($package.risks)) { $id = [string]$item.id; if (-not [string]::IsNullOrWhiteSpace($id)) { $validItems[$id] = 'risk' } }
foreach ($item in @($package.acceptance_criteria)) { $id = [string]$item.id; if (-not [string]::IsNullOrWhiteSpace($id)) { $validItems[$id] = 'acceptance_criterion' } }
foreach ($item in @($package.packages)) { $id = [string]$item.id; if (-not [string]::IsNullOrWhiteSpace($id)) { $validItems[$id] = 'package' } }

$seenDecisions = @{}
if ($null -ne $input -and (Test-HasProperty $input 'item_decisions')) {
    foreach ($item in @($input.item_decisions)) {
        if ($null -eq $item) { throw 'item_decisions contains a null item' }
        Assert-RequiredMetadata $item @('id','kind','decision','actor','decided_at') 'item_decisions item'
        $id = [string]$item.id
        if ($seenDecisions.ContainsKey($id)) { throw "Duplicate item decision: $id" }
        $seenDecisions[$id] = $true
        if (-not $decisionItems.ContainsKey($id)) { throw "Unknown decision item: $id" }
        if ([string]$item.kind -ne 'decision') { throw "Item '$id' has invalid kind: $($item.kind)" }
        if ([string]$item.decision -notin @('APPROVED','REJECTED','CHANGES_REQUESTED')) { throw "Item '$id' has invalid decision: $($item.decision)" }
        if ([string]::IsNullOrWhiteSpace([string]$item.actor)) { throw "Item '$id' actor is required" }
        if ([string]$item.actor -ne $Actor) { throw "Item '$id' actor does not match package actor" }
        $itemTime = ConvertTo-ApprovalTimestamp $item.decided_at "Item '$id' decided_at" -Required
        $comment = if (Test-HasProperty $item 'comment') { [string]$item.comment } else { '' }
        if ([string]$item.decision -ne 'APPROVED' -and [string]::IsNullOrWhiteSpace($comment)) { throw "Item '$id' requires a comment for $($item.decision)" }
        $itemDecisions += ,[ordered]@{ id=$id; kind='decision'; decision=[string]$item.decision; actor=[string]$item.actor; comment=$comment; decided_at=$itemTime }
    }
}

if ($null -ne $input) {
    if (Test-HasProperty $input 'item_comments') {
        $itemComments = @(Get-NormalizedItemComments $input.item_comments $validItems 'item_comments')
    } elseif (Test-HasProperty $input 'item_feedback') {
        $itemComments = @(Get-NormalizedItemComments $input.item_feedback $validItems 'item_feedback')
    }
}
$commentKeys = @{}
foreach ($comment in $itemComments) { $commentKeys[([string]$comment.id + "`n" + [string]$comment.comment)] = $true }
foreach ($item in $itemDecisions) {
    if (-not [string]::IsNullOrWhiteSpace([string]$item.comment)) {
        $key = [string]$item.id + "`n" + [string]$item.comment
        if (-not $commentKeys.ContainsKey($key)) {
            $itemComments += ,[ordered]@{ id=[string]$item.id; comment=[string]$item.comment; actor=[string]$item.actor; commented_at=[string]$item.decided_at }
            $commentKeys[$key] = $true
        }
    }
}

$nonApproved = @($itemDecisions | Where-Object { [string]$_.decision -ne 'APPROVED' })
if ($nonApproved.Count -gt 0) {
    $mismatched = @($nonApproved | Where-Object { [string]$_.decision -ne $Decision })
    if ($mismatched.Count -gt 0) { throw "Item decision does not match package decision: $($mismatched.id -join ', ')" }
}
if ($Decision -eq 'APPROVED') {
    $approvedById = @{}
    foreach ($item in $itemDecisions) { $approvedById[[string]$item.id] = [string]$item.decision }
    $blocking = @($package.open_decisions | Where-Object {
        [string]$_.resolution -eq 'user-required' -and $_.blocking -eq $true -and
        (-not $approvedById.ContainsKey([string]$_.id) -or $approvedById[[string]$_.id] -ne 'APPROVED')
    })
    if ($blocking.Count -gt 0) { throw "Blocking user-required decisions remain unresolved: $($blocking.id -join ', ')" }
} elseif ([string]::IsNullOrWhiteSpace($Statement) -and $itemComments.Count -eq 0) {
    throw "$Decision requires a statement or item comment"
}

$effectiveInput = if ($null -ne $input) { $input } else {
    [ordered]@{
        schema_version = '1.0'
        spec_id = $package.spec.spec_id
        package_revision = $package.package_revision
        package_sha256 = $actualHash
        decision = $Decision
        actor = $Actor
        statement = $Statement
        item_decisions = $itemDecisions
        item_comments = $itemComments
    }
}
$inputHash = Get-ObjectSha256 $effectiveInput
$normalizedRequest = [ordered]@{ decision=$Decision; actor=$Actor; statement=$Statement; item_decisions=$itemDecisions; item_comments=$itemComments }

if ([string]$current.status -ne 'PENDING') {
    $sameInput = (Test-HasProperty $current 'approval_input_sha256') -and [string]$current.approval_input_sha256 -eq $inputHash
    if (-not $sameInput) {
        $existingRequest = [ordered]@{
            decision = [string]$current.status
            actor = [string]$current.actor
            statement = [string]$current.statement
            item_decisions = if (Test-HasProperty $current 'item_decisions') { @($current.item_decisions) } else { @() }
            item_comments = if (Test-HasProperty $current 'item_comments') { @($current.item_comments) } elseif (Test-HasProperty $current 'item_feedback') { @($current.item_feedback) } else { @() }
        }
        $sameInput = (Get-ObjectSha256 $existingRequest) -eq (Get-ObjectSha256 $normalizedRequest)
    }
    if (-not $sameInput) { throw "Approval is already sealed: $($current.status)" }
    Assert-CurrentPointer $currentPointer $package $packageRoot $actualHash @('READY_FOR_APPROVAL', [string]$current.status)
    if ([string]$current.status -eq 'APPROVED' -and $null -eq $approvedPointer) { throw 'approved.json is missing for sealed APPROVED revision' }
    Write-TerminalPointers $package $packageRoot $specRoot ([string]$current.status) $actualHash $approvedPointer
    Write-Output "Already recorded $($current.status): $packageFile"
    exit 0
}

Assert-CurrentPointer $currentPointer $package $packageRoot $actualHash @('READY_FOR_APPROVAL')
if ($null -ne $approvedPointer -and [int]$approvedPointer.revision -eq [int]$package.package_revision) {
    throw 'approved.json points to a revision whose approval is still pending'
}

$now = (Get-Date).ToUniversalTime().ToString('o')
$history = if (Test-HasProperty $current 'history') { @($current.history) } else { @() }
$historyEntry = [ordered]@{
    status = $Decision
    actor = $Actor
    decided_at = $now
    statement = $Statement
    item_decisions = $itemDecisions
    item_comments = $itemComments
    approval_input_sha256 = $inputHash
}
$history += ,$historyEntry
$result = [ordered]@{
    schema_version = '1.0'
    spec_id = $package.spec.spec_id
    package_revision = $package.package_revision
    package_sha256 = $actualHash
    status = $Decision
    approved_revision = if ($Decision -eq 'APPROVED') { $package.package_revision } else { $null }
    actor = $Actor
    decided_at = $now
    approval_input_decided_at = $inputDecidedAt
    recorded_at = $now
    statement = $Statement
    item_decisions = $itemDecisions
    item_comments = $itemComments
    approval_input_sha256 = $inputHash
    history = $history
}
Write-JsonAtomic -Path $approvalFile -Value $result
Write-TerminalPointers $package $packageRoot $specRoot $Decision $actualHash $approvedPointer
Write-Output "Recorded $Decision for $($package.plan_package_id)"
