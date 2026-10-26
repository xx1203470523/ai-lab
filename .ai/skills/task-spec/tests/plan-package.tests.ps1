[CmdletBinding()]
param([string]$TestRoot = (Join-Path $env:TEMP "task-spec-plan-package-$([guid]::NewGuid().ToString('N'))"))
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
$create = Join-Path $scriptRoot 'scripts\create-plan-package.ps1'
$approve = Join-Path $scriptRoot 'scripts\approve-plan-package.ps1'
$reader = Join-Path $scriptRoot 'scripts\read-approved-plan.ps1'
$fixtures = Join-Path $scriptRoot 'tests\fixtures'
$proposalPath = Join-Path $fixtures 'plan-draft.json'

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
  $thrown = $false
  try { & $Action | Out-Null } catch { $thrown = $true }
  Assert-True $thrown $Message
}
function Make-TestPackage {
  param($Root, $Proposal, $Slug, $CreatedAt, $Revision)
  $Revision = [int]$Revision
  & $create -ProposalPath $Proposal -OutputRoot $Root -RequestSlug $Slug -CreatedAt $CreatedAt -Revision $Revision | Out-Null
  $revisionName = if ($Revision -gt 0) { 'r{0:d2}' -f $Revision } else { 'r01' }
  return Join-Path $Root (Join-Path ("20260902-$Slug") $revisionName)
}
function New-ApprovalInput([string]$Template, $Package, [string]$Decision = 'APPROVED', [bool]$IncludeItemDecision = $false) {
  $input = Get-Content -LiteralPath $Template -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $input.PSObject.Properties['package_sha256']) { $input | Add-Member -NotePropertyName package_sha256 -NotePropertyValue '' }
  $input.spec_id = [string]$Package.spec.spec_id
  $input.package_revision = [int]$Package.package_revision
  if ($null -eq $input.PSObject.Properties['package_sha256']) { $input | Add-Member -NotePropertyName package_sha256 -NotePropertyValue $null }
  $input.package_sha256 = [string]$Package.plan_package_sha256
  $input.decision = $Decision
  if ($Decision -eq 'APPROVED') { $input.actor = 'test-user'; $input.statement = '批准该 revision 用于实施' }
  if ($null -eq $input.PSObject.Properties['item_decisions']) { $input | Add-Member -NotePropertyName item_decisions -NotePropertyValue @() }
  if ($null -eq $input.PSObject.Properties['item_feedback']) { $input | Add-Member -NotePropertyName item_feedback -NotePropertyValue @() }
  if ($IncludeItemDecision) {
    $item = [pscustomobject]@{ id = 'D-01'; kind = 'decision'; decision = 'APPROVED'; actor = 'test-user'; comment = '确认使用 JSON'; decided_at = '2026-09-02T10:01:00Z' }
    $input.item_decisions = @($item)
    $input.item_feedback = @([pscustomobject]@{ id = 'D-01'; comment = '确认使用 JSON' })
  }
  return $input
}
function Save-Json($Value, [string]$Path) { $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding UTF8 }

New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
try {
  # Canonical date-slug path, required files, and generated approval UI contract.
  $root = Join-Path $TestRoot 'path'
  $pkg = Make-TestPackage $root $proposalPath 'approval-chain' '2026-09-02T10:00:00Z' 0
  Assert-True (Test-Path (Join-Path $pkg 'plan.md')) 'Missing plan.md'
  Assert-True (Test-Path (Join-Path $pkg 'plan-package.json')) 'Missing plan-package.json'
  Assert-True (Test-Path (Join-Path $pkg 'approval.html')) 'Missing approval.html'
  Assert-True (Test-Path (Join-Path $pkg 'approval.json')) 'Missing approval.json'
  Assert-True ($pkg -eq (Join-Path $root '20260902-approval-chain\r01')) 'Package path is not date-slug/rNN'
  $package = Get-Content (Join-Path $pkg 'plan-package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($package.request_slug -eq 'approval-chain') 'request_slug missing from package'
  Assert-True ($package.folder_name -eq '20260902-approval-chain') 'folder_name mismatch'
  $html = Get-Content (Join-Path $pkg 'approval.html') -Raw -Encoding UTF8
  foreach ($marker in @('plan-data','section-decisions','item_decisions','approve-all','APPROVED','CHANGES_REQUESTED','REJECTED')) { Assert-True ($html.Contains($marker)) "Approval UI missing $marker" }

  # File-driven approval, including the new item_decisions field and reader gate.
  $input = New-ApprovalInput (Join-Path $fixtures 'approval-approved.json') $package 'APPROVED' $true
  $inputPath = Join-Path $TestRoot 'approval-input.json'; Save-Json $input $inputPath
  & $approve -PackagePath $pkg -Decision APPROVED -ApprovalInputPath $inputPath | Out-Null
  $read = & $reader -PackagePath $pkg -AsJson | ConvertFrom-Json
  Assert-True ($read.status -eq 'APPROVED' -and $read.approval.status -eq 'APPROVED') 'Reader did not return approved package'
  Assert-True ($read.approval.item_comments[0].id -eq 'D-01') 'item_decisions/item_feedback was not accepted'
  $before = Get-FileHash (Join-Path $pkg 'approval.json')
  & $approve -PackagePath $pkg -Decision APPROVED -ApprovalInputPath $inputPath | Out-Null
  $after = Get-FileHash (Join-Path $pkg 'approval.json')
  Assert-True ($before.Hash -eq $after.Hash) 'Repeated approval changed sealed record'

  # Blocking user-required decision remains a hard approval gate.
  $blockingProposal = Get-Content $proposalPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $blockingProposal.open_decisions[0].resolution = 'user-required'
  $blockingProposal.open_decisions[0].blocking = $true
  $blockingProposal.open_decisions[0].user_decision = 'PENDING'
  $blockingPath = Join-Path $TestRoot 'plan-blocking.json'; Save-Json $blockingProposal $blockingPath
  $blockingPkg = Make-TestPackage (Join-Path $TestRoot 'blocking') $blockingPath 'blocking-decision' '2026-09-02T10:00:00Z' 0
  $blockingPackage = Get-Content (Join-Path $blockingPkg 'plan-package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $blockingInput = New-ApprovalInput (Join-Path $fixtures 'approval-approved.json') $blockingPackage 'APPROVED' $false
  $blockingInputPath = Join-Path $TestRoot 'blocking-approval.json'; Save-Json $blockingInput $blockingInputPath
  Assert-Throws { & $approve -PackagePath $blockingPkg -Decision APPROVED -ApprovalInputPath $blockingInputPath } 'Blocking decision did not stop approval'

  # Legacy item_feedback input remains importable for change requests.
  $changesPkg = Make-TestPackage (Join-Path $TestRoot 'changes') $proposalPath 'approval-chain' '2026-09-02T10:00:00Z' 0
  $changesPackage = Get-Content (Join-Path $changesPkg 'plan-package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $changesInput = New-ApprovalInput (Join-Path $fixtures 'approval-changes.json') $changesPackage 'CHANGES_REQUESTED' $false
  $changesInputPath = Join-Path $TestRoot 'changes-input.json'; Save-Json $changesInput $changesInputPath
  & $approve -PackagePath $changesPkg -Decision CHANGES_REQUESTED -ApprovalInputPath $changesInputPath | Out-Null
  $changesApproval = Get-Content (Join-Path $changesPkg 'approval.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-True ($changesApproval.status -eq 'CHANGES_REQUESTED') 'CHANGES_REQUESTED was not recorded'

  # Substantive revision gets a new r02 while r01 remains intact.
  $revisionRoot = Join-Path $TestRoot 'revision'
  $r01 = Make-TestPackage $revisionRoot $proposalPath 'approval-chain' '2026-09-02T10:00:00Z' 0
  $r02 = Make-TestPackage $revisionRoot $proposalPath 'approval-chain' '2026-09-02T10:00:00Z' 2
  Assert-True ((Test-Path $r01) -and (Test-Path $r02)) 'Revision directories were not retained'
  Assert-True ((Get-Content (Join-Path $r01 'approval.json') -Raw).Contains('PENDING')) 'r01 was not retained'
  $r02Package = Get-Content (Join-Path $r02 'plan-package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  $r02Input = New-ApprovalInput (Join-Path $fixtures 'approval-approved.json') $r02Package 'APPROVED' $false
  $r02InputPath = Join-Path $TestRoot 'r02-approval.json'; Save-Json $r02Input $r02InputPath
  & $approve -PackagePath $r02 -Decision APPROVED -ApprovalInputPath $r02InputPath | Out-Null
  Assert-True ((Get-Content (Join-Path $r02 'approval.json') -Raw).Contains('APPROVED')) 'r02 was not approved'

  # Reader rejects missing approval and package tampering; legacy is not a default package path.
  $unapproved = Make-TestPackage (Join-Path $TestRoot 'unapproved') $proposalPath 'approval-chain' '2026-09-02T10:00:00Z' 0
  Assert-Throws { & $reader -PackagePath $unapproved } 'Reader accepted unapproved package'
  $tampered = Join-Path $TestRoot 'tampered'; Copy-Item (Join-Path $pkg 'plan-package.json') $tampered -Force
  Assert-Throws { & $reader -PackagePath $tampered } 'Reader accepted package without approval.json'

  Write-Output 'PASS: date-slug path, UI/item_decisions, blocking gate, legacy input, revisions, reader, and idempotency'
} finally { Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue }
