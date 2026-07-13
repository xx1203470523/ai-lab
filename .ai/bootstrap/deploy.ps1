<#
.SYNOPSIS
  Deploy skills and rules from ai-lab to ~/.claude/
.DESCRIPTION
  Reads config.json, syncs core skills/rules (default) and optional project skills/rules
  to personal Claude Code config. Idempotent: skips missing sources, overwrites existing.
.PARAMETER Core
  Sync core (skills + rules), enabled by default
.PARAMETER Project
  Project name(s) to sync (wms, trade). Omit to skip project skills/rules.
.PARAMETER All
  Sync all (core + all projects)
.PARAMETER List
  List configured sources without syncing
.PARAMETER DryRun
  Preview mode: show what would be synced
.EXAMPLE
  .\deploy.ps1                    # core only
  .\deploy.ps1 -Project wms       # core + wms
  .\deploy.ps1 -All               # all
  .\deploy.ps1 -List              # show config
#>

param(
    [switch]$Core = $true,
    [string[]]$Project = @(),
    [switch]$All,
    [switch]$List,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$script:Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:ConfigPath = Join-Path $PSScriptRoot "config.json"

function Write-Step { Write-Host ">> $args" -ForegroundColor Cyan }
function Write-OK   { Write-Host "   OK  $args" -ForegroundColor Green }
function Write-Skip { Write-Host "   --  $args" -ForegroundColor Yellow }
function Write-Err  { Write-Host "   !!  $args" -ForegroundColor Red }

function Resolve-Target {
    param([object]$Target)
    $resolved = $Target.path -replace '^~/', "$env:USERPROFILE\"
    if (-not (Test-Path $resolved)) {
        New-Item -ItemType Directory -Force -Path $resolved | Out-Null
    }
    return @{ path = $resolved; itemType = $Target.itemType }
}

function Sync-Type {
    param(
        [string]$Type,
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$ItemType = "dir"
    )

    if (-not (Test-Path $SourcePath)) {
        Write-Skip "$Type source not found: $SourcePath"
        return @{ synced = 0; skipped = 0 }
    }

    $items = if ($ItemType -eq 'file') {
        Get-ChildItem -File $SourcePath
    } else {
        Get-ChildItem -Directory $SourcePath
    }
    if ($items.Count -eq 0) {
        Write-Skip "no $Type in directory"
        return @{ synced = 0; skipped = 0 }
    }

    $s = 0; $sk = 0
    foreach ($item in $items) {
        $itemName = $item.Name
        $destPath = Join-Path $TargetPath $itemName

        if ($DryRun) {
            $action = if (Test-Path $destPath) { "update (exists)" } else { "CREATE" }
            Write-Host "   [$Type] $itemName --> $action"
            $s++
        } else {
            try {
                if (Test-Path $destPath) {
                    Remove-Item -Recurse -Force $destPath
                }
                Copy-Item -Recurse -Force $item.FullName $destPath
                Write-OK "$Type/$itemName"
                $s++
            } catch {
                Write-Err "$Type/$itemName : $_"
                $sk++
            }
        }
    }
    return @{ synced = $s; skipped = $sk }
}

# ============================================================
# Main
# ============================================================

if (-not (Test-Path $script:ConfigPath)) {
    Write-Err "config.json not found: $script:ConfigPath"
    exit 1
}
$config = Get-Content $script:ConfigPath -Encoding UTF8 | ConvertFrom-Json

# Resolve targets
$targets = @{}
foreach ($type in $config.targets.PSObject.Properties.Name) {
    $targets[$type] = Resolve-Target -Target $config.targets.$type
}

# --list mode
if ($List) {
    Write-Step "Sources"
    foreach ($key in $config.sources.PSObject.Properties.Name) {
        $src = $config.sources.$key
        $flag = if ($src.always) { "[core]" } else { "[project]" }
        Write-Host "  $key $flag $($src.description)"
        foreach ($type in $config.targets.PSObject.Properties.Name) {
            if (-not $src.$type) { continue }
            $srcPath = Join-Path $script:Root $src.$type
            $exists = Test-Path $srcPath
            $mark = if ($exists) { "[OK]" } else { "[MISSING]" }
            $itemType = $config.targets.$type.itemType
            $count = if ($exists) {
                if ($itemType -eq 'file') { (Get-ChildItem -File $srcPath).Count }
                else { (Get-ChildItem -Directory $srcPath).Count }
            } else { 0 }
            Write-Host "    $mark $type : $($src.$type) ($count items)"
        }
    }
    Write-Host ""
    Write-Step "Targets"
    foreach ($type in $config.targets.PSObject.Properties.Name) {
        Write-Host "  $type : $($config.targets.$type.path) --> $($targets[$type].path)"
    }
    exit 0
}

# Determine sources to sync
$toSync = @{}
if ($Core) {
    if ($config.sources.core) { $toSync['core'] = $config.sources.core }
}

if ($All) {
    foreach ($key in $config.sources.PSObject.Properties.Name) {
        if ($key -ne 'core') { $toSync[$key] = $config.sources.$key }
    }
} else {
    foreach ($proj in $Project) {
        if ($config.sources.$proj) {
            $toSync[$proj] = $config.sources.$proj
        } else {
            Write-Err "Unknown project: $proj (available: $($config.sources.PSObject.Properties.Name -join ', '))"
            exit 1
        }
    }
}

Write-Step "Deploy start ($(Get-Date -Format 'HH:mm:ss'))"
Write-Host "   source : $script:Root"
foreach ($type in $config.targets.PSObject.Properties.Name) {
    Write-Host "   target $type : $($targets[$type].path)"
}
Write-Host "   scope  : $($toSync.Keys -join ', ')"
if ($DryRun) { Write-Host "   mode   : DRY RUN" -ForegroundColor Magenta }
Write-Host ""

$totalSynced = 0
$totalSkipped = 0

foreach ($key in $toSync.Keys) {
    $src = $toSync[$key]

    Write-Step "[$key] $($src.description)"

    foreach ($type in $config.targets.PSObject.Properties.Name) {
        if (-not $src.$type) { continue }

        $srcPath = Join-Path $script:Root $src.$type
        $tgt = $targets[$type]
        $result = Sync-Type -Type $type -SourcePath $srcPath -TargetPath $tgt.path -ItemType $tgt.itemType
        $totalSynced += $result.synced
        $totalSkipped += $result.skipped
    }
}

Write-Host ""
Write-Step "Deploy done: $totalSynced synced, $totalSkipped skipped"
