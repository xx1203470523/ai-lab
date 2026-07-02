<#
.SYNOPSIS
  Deploy skills from ai-lab to ~/.claude/skills/
.DESCRIPTION
  Reads config.json, syncs core skills (default) and optional project skills
  to personal Claude Code config. Idempotent: skips missing sources, overwrites existing.
.PARAMETER Core
  Sync core skills (.ai/skills), enabled by default
.PARAMETER Project
  Project name(s) to sync (wms, trade). Omit to skip project skills.
.PARAMETER All
  Sync all skills (core + all projects)
.PARAMETER List
  List configured skill sources without syncing
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
    $homeSkills = "$env:USERPROFILE\.claude\skills"
    if (-not (Test-Path $homeSkills)) {
        New-Item -ItemType Directory -Force -Path $homeSkills | Out-Null
    }
    return $homeSkills
}

# ============================================================
# Main
# ============================================================

if (-not (Test-Path $script:ConfigPath)) {
    Write-Err "config.json not found: $script:ConfigPath"
    exit 1
}
$config = Get-Content $script:ConfigPath -Encoding UTF8 | ConvertFrom-Json

# --list mode
if ($List) {
    Write-Step "Skill sources"
    foreach ($key in $config.sources.PSObject.Properties.Name) {
        $src = $config.sources.$key
        $srcPath = Join-Path $script:Root $src.path
        $exists = Test-Path $srcPath
        $mark = if ($exists) { "[OK]" } else { "[MISSING]" }
        $flag = if ($src.always) { "[core]" } else { "[project]" }
        $count = if ($exists) { (Get-ChildItem -Directory $srcPath).Count } else { 0 }
        Write-Host "  $mark $key $flag $($src.description)"
        Write-Host "         $srcPath ($count skills)"
    }
    exit 0
}

# Determine sources to sync
$toSync = @{}
if ($Core) { $toSync['core'] = $config.sources.core }

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

$target = Resolve-Target
$synced = 0
$skipped = 0

Write-Step "Deploy start ($(Get-Date -Format 'HH:mm:ss'))"
Write-Host "   source : $script:Root"
Write-Host "   target : $target"
Write-Host "   scope  : $($toSync.Keys -join ', ')"
if ($DryRun) { Write-Host "   mode   : DRY RUN" -ForegroundColor Magenta }
Write-Host ""

foreach ($key in $toSync.Keys) {
    $src = $toSync[$key]
    $srcPath = Join-Path $script:Root $src.path

    Write-Step "[$key] $($src.description)"

    if (-not (Test-Path $srcPath)) {
        Write-Skip "source not found: $srcPath"
        continue
    }

    $skills = Get-ChildItem -Directory $srcPath
    if ($skills.Count -eq 0) {
        Write-Skip "no skills in directory"
        continue
    }

    foreach ($skillDir in $skills) {
        $skillName = $skillDir.Name
        $destPath = Join-Path $target $skillName

        if ($DryRun) {
            if (Test-Path $destPath) {
                Write-Host "   [$skillName] --> update (exists)"
            } else {
                Write-Host "   [$skillName] --> CREATE"
            }
            $synced++
        } else {
            try {
                # Remove old before copy (avoids stale files)
                if (Test-Path $destPath) {
                    Remove-Item -Recurse -Force $destPath
                }
                Copy-Item -Recurse -Force $skillDir.FullName $destPath
                Write-OK $skillName
                $synced++
            } catch {
                Write-Err "$skillName : $_"
                $skipped++
            }
        }
    }
}

Write-Host ""
Write-Step "Deploy done: $synced synced, $skipped skipped"
