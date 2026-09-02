[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProposalPath,
    [string]$OutputRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$SpecPath,
    [string]$RequestSlug,
    [string]$CreatedAt,
    [int]$Revision = 0
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlanPackage.psm1') -Force

function Get-RequiredString([object]$Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) { throw "Proposal requires $Name" }
    return [string]$property.Value
}
function Get-OptionalValue([object]$Object, [string]$Name, $Default = $null) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}
function Get-AbsolutePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    return [IO.Path]::GetFullPath($Path)
}

$proposalFile = Get-AbsolutePath $ProposalPath
$proposal = Get-Content -LiteralPath $proposalFile -Raw -Encoding UTF8 | ConvertFrom-Json
$specId = Get-RequiredString $proposal 'spec_id'
$projectId = Get-RequiredString $proposal 'project_id'
$baseline = Get-RequiredString $proposal 'evidence_baseline'
if ($null -eq $proposal.PSObject.Properties['packages']) { throw 'Proposal requires packages' }
$slug = if (-not [string]::IsNullOrWhiteSpace($RequestSlug)) { $RequestSlug } else { [string](Get-OptionalValue $proposal 'request_slug') }
if ([string]::IsNullOrWhiteSpace($slug)) { throw 'RequestSlug is required (provide -RequestSlug or proposal.request_slug)' }
if ($slug -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $slug.Length -gt 80 -or $slug -match '(^|-)\.(\.|$)') { throw 'RequestSlug must be lowercase kebab-case and at most 80 characters' }

$when = if (-not [string]::IsNullOrWhiteSpace($CreatedAt)) { [datetime]::Parse($CreatedAt).ToUniversalTime() } elseif ($proposal.created_at) { [datetime]::Parse([string]$proposal.created_at).ToUniversalTime() } else { (Get-Date).ToUniversalTime() }
$folderName = $when.ToString('yyyyMMdd') + '-' + $slug
$root = [IO.Path]::GetFullPath($OutputRoot)
$specRoot = Join-Path $root $folderName
New-Item -ItemType Directory -Path $specRoot -Force | Out-Null

$proposalHash = Get-ObjectSha256 $proposal
$existingRevisionDirs = @(Get-ChildItem -LiteralPath $specRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^r\d+$' } | Sort-Object Name)
if ($Revision -le 0) {
    foreach ($candidate in $existingRevisionDirs) {
        $candidateFile = Join-Path $candidate.FullName 'plan-package.json'
        if (Test-Path -LiteralPath $candidateFile -PathType Leaf) {
            try {
                $candidatePackage = Get-Content -LiteralPath $candidateFile -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$candidatePackage.source_proposal_sha256 -eq $proposalHash) {
                    Test-PlanPackage $candidatePackage | Out-Null
                    Write-Output "Already exists: $($candidate.FullName)"
                    exit 0
                }
            } catch { }
        }
    }
}
if ($Revision -le 0) {
    $Revision = if ($existingRevisionDirs.Count) { (($existingRevisionDirs | ForEach-Object { [int]$_.Name.Substring(1) } | Measure-Object -Maximum).Maximum + 1) } else { 1 }
} elseif ($existingRevisionDirs.Name -contains ('r{0:d2}' -f $Revision)) {
    throw "Revision already exists and differs: r{0:d2}" -f $Revision
}
$revisionName = 'r{0:d2}' -f $Revision
$revisionRoot = Join-Path $specRoot $revisionName
if (Test-Path -LiteralPath $revisionRoot) { throw "Revision already exists and is sealed: $revisionName" }

$projectRoot = Get-AbsolutePath (Get-OptionalValue $proposal 'project_root' (Get-Location).Path)
$specFile = if ($SpecPath) { Get-AbsolutePath $SpecPath } elseif ($proposal.spec_path) { Get-AbsolutePath ([string]$proposal.spec_path) } else { $null }
$specDigest = if ($specFile) { Get-FileSha256 $specFile } else { $null }
$previous = if ($existingRevisionDirs.Count) { $existingRevisionDirs[-1] } else { $null }
$supersedes = $null
if ($previous) {
    $supersedes = [ordered]@{ revision = [int]$previous.Name.Substring(1); path = $previous.FullName; reason = [string](Get-OptionalValue $proposal 'change_summary' 'Supersedes previous revision') }
}

$proposalPackages = @($proposal.packages)
$package = [ordered]@{
    schema_version = '1.0'
    plan_package_id = "$specId-$revisionName"
    spec = [ordered]@{ spec_id = $specId; revision = $Revision; path = $specFile; sha256 = $specDigest; project_id = $projectId; evidence_baseline = $baseline }
    package_revision = $Revision
    status = 'READY_FOR_APPROVAL'
    created_at = $when.ToString('o')
    request_slug = $slug
    folder_name = $folderName
    project_root = $projectRoot
    package_root = [IO.Path]::GetFullPath($revisionRoot)
    package_path = [IO.Path]::GetFullPath($revisionRoot)
    supersedes = $supersedes
    source_proposal_sha256 = $proposalHash
    title = Get-OptionalValue $proposal 'title'
    description = Get-OptionalValue $proposal 'description'
    summary = Get-OptionalValue $proposal 'summary'
    current_state = Get-OptionalValue $proposal 'current_state'
    target_state = Get-OptionalValue $proposal 'target_state'
    behavior = Get-OptionalValue $proposal 'behavior'
    business_rules = Get-OptionalValue $proposal 'business_rules'
    scope = Get-OptionalValue $proposal 'scope'
    risks = Get-OptionalValue $proposal 'risks'
    technical_direction = Get-OptionalValue $proposal 'technical_direction'
    reference_code_assessment = Get-OptionalValue $proposal 'reference_code_assessment'
    open_decisions = Get-OptionalValue $proposal 'open_decisions'
    acceptance_criteria = Get-OptionalValue $proposal 'acceptance_criteria'
    implementation_boundary = Get-OptionalValue $proposal 'implementation_boundary'
    packages = $proposalPackages
    total_packages = $proposalPackages.Count
}
$packageObject = [pscustomobject]$package
Test-PlanPackage $packageObject | Out-Null
New-Item -ItemType Directory -Path $revisionRoot -Force | Out-Null
$packageFile = Join-Path $revisionRoot 'plan-package.json'
# 先写入无 hash 的规范对象，再从文件 round-trip 后计算 hash；这样生成端与
# 审批/reader 端使用完全相同的 JSON 形状，避免单元素数组等 PowerShell 展开差异。
New-Item -ItemType Directory -Path $revisionRoot -Force | Out-Null
Write-JsonAtomic -Path $packageFile -Value $packageObject
$packageObject = Get-Content -LiteralPath $packageFile -Raw -Encoding UTF8 | ConvertFrom-Json
Test-PlanPackage $packageObject | Out-Null
$hash = Get-PlanPackageSha256 $packageObject
$packageObject | Add-Member -NotePropertyName plan_package_sha256 -NotePropertyValue $hash -Force
Write-JsonAtomic -Path $packageFile -Value $packageObject
$md = if ($proposal.plan_markdown) { [string]$proposal.plan_markdown } else { "# $($packageObject.title)`r`n`r`n$($packageObject.description)`r`n" }
Write-Utf8Atomic -Path (Join-Path $revisionRoot 'plan.md') -Content ($md.TrimEnd() + "`r`n")
$approval = [ordered]@{ schema_version='1.0'; spec_id=$specId; package_revision=$Revision; package_sha256=$hash; status='PENDING'; approved_revision=$null; actor=$null; decided_at=$null; statement=$null; item_decisions=@(); item_comments=@(); history=@() }
Write-JsonAtomic -Path (Join-Path $revisionRoot 'approval.json') -Value $approval
& (Join-Path $PSScriptRoot 'render-approval.ps1') -PlanPath (Join-Path $revisionRoot 'plan-package.json') -OutputPath (Join-Path $revisionRoot 'approval.html')

$currentPointer = [ordered]@{ spec_id=$specId; project_id=$projectId; project_root=$projectRoot; revision=$Revision; path=[IO.Path]::GetFullPath($revisionRoot); package_path=[IO.Path]::GetFullPath($revisionRoot); status='READY_FOR_APPROVAL'; plan_package_sha256=$hash }
Write-JsonAtomic -Path (Join-Path $specRoot 'current.json') -Value $currentPointer
Write-Output "Created: $revisionRoot"
