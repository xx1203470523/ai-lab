[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackagePath,[switch]$AsJson)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlanPackage.psm1') -Force

function Test-HasProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    return $null -ne $Object.PSObject.Properties[$Name]
}
function Assert-Required {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string[]]$Names, [Parameter(Mandatory)][string]$Label)
    foreach ($name in $Names) {
        if (-not (Test-HasProperty $Object $name) -or $null -eq $Object.$name -or [string]::IsNullOrWhiteSpace([string]$Object.$name)) {
            throw "$Label requires $name"
        }
    }
}
function Same-Path {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    $a = [IO.Path]::GetFullPath($Left).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $b = [IO.Path]::GetFullPath($Right).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

$packageFile = if ((Test-Path -LiteralPath $PackagePath -PathType Leaf) -and ([IO.Path]::GetFileName($PackagePath) -eq 'plan-package.json')) {
    [IO.Path]::GetFullPath($PackagePath)
} else {
    Join-Path ([IO.Path]::GetFullPath($PackagePath)) 'plan-package.json'
}
if (-not (Test-Path -LiteralPath $packageFile -PathType Leaf)) { throw "Package file not found: $packageFile" }
$packageRoot = Split-Path -Parent $packageFile
$specRoot = Split-Path -Parent $packageRoot
$approvalFile = Join-Path $packageRoot 'approval.json'
if (-not (Test-Path -LiteralPath $approvalFile -PathType Leaf)) { throw "Approval metadata not found: $approvalFile" }
$package = Get-Content -LiteralPath $packageFile -Raw -Encoding UTF8 | ConvertFrom-Json
$approval = Get-Content -LiteralPath $approvalFile -Raw -Encoding UTF8 | ConvertFrom-Json
Test-PlanPackage $package | Out-Null

if ([string]$approval.status -ne 'APPROVED') { throw "Package is not approved: $($approval.status)" }
if (-not (Test-HasProperty $approval 'approved_revision') -or [int]$approval.approved_revision -ne [int]$package.package_revision) { throw 'Approved revision does not match package revision' }
$actualHash = Get-PlanPackageSha256 $package
if ([string]$package.plan_package_sha256 -ne $actualHash) { throw 'Package hash is invalid' }
if ([string]$approval.package_sha256 -ne $actualHash) { throw 'Package hash does not match approval' }
if ([string]$package.status -notin @('READY_FOR_APPROVAL','APPROVED')) { throw "Package status is not executable: $($package.status)" }
if (-not (Same-Path ([string]$package.package_root) $packageRoot) -or -not (Same-Path ([string]$package.package_path) $packageRoot)) { throw 'Package path metadata does not match package location' }
if (-not [IO.Path]::IsPathRooted([string]$package.project_root)) { throw 'project_root must be an absolute path' }

$currentFile = Join-Path $specRoot 'current.json'
if (-not (Test-Path -LiteralPath $currentFile -PathType Leaf)) { throw "Current pointer not found: $currentFile" }
$current = Get-Content -LiteralPath $currentFile -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Required $current @('spec_id','revision','path','status','plan_package_sha256') 'current.json'
if ([string]$current.spec_id -ne [string]$package.spec.spec_id -or [int]$current.revision -ne [int]$package.package_revision -or -not (Same-Path ([string]$current.path) $packageRoot) -or [string]$current.plan_package_sha256 -ne $actualHash) { throw 'current.json does not point to this package' }
if ([string]$current.status -notin @('READY_FOR_APPROVAL','APPROVED')) { throw "current.json status is invalid: $($current.status)" }

$approvedFile = Join-Path $specRoot 'approved.json'
if (-not (Test-Path -LiteralPath $approvedFile -PathType Leaf)) { throw "Approved pointer not found: $approvedFile" }
$approved = Get-Content -LiteralPath $approvedFile -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-Required $approved @('spec_id','revision','path','status','package_sha256') 'approved.json'
if ([string]$approved.status -ne 'APPROVED' -or [string]$approved.spec_id -ne [string]$package.spec.spec_id -or [int]$approved.revision -ne [int]$package.package_revision -or -not (Same-Path ([string]$approved.path) $packageRoot) -or [string]$approved.package_sha256 -ne $actualHash) { throw 'approved.json does not point to this approved package' }

$decisions = @{}
foreach ($item in @($package.open_decisions)) {
    if ([string]$item.resolution -eq 'user-required' -and $item.blocking -eq $true) { $decisions[[string]$item.id] = $false }
}
foreach ($item in @($approval.item_decisions)) {
    if ($decisions.ContainsKey([string]$item.id) -and [string]$item.decision -eq 'APPROVED') { $decisions[[string]$item.id] = $true }
}
$unresolved = @($decisions.Keys | Where-Object { -not $decisions[$_] })
if ($unresolved.Count -gt 0) { throw "Blocking user-required decisions are not approved: $($unresolved -join ', ')" }

$package.status = 'APPROVED'
$package | Add-Member -NotePropertyName approval -NotePropertyValue $approval -Force
if ($AsJson) { $package | ConvertTo-Json -Depth 100 } else { Write-Output "APPROVED $($package.spec.spec_id) revision $($package.package_revision) package $packageRoot" }
