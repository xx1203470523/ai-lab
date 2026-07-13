<#
.SYNOPSIS
  Search WMS knowledge base INDEX.md for keyword matches.
.DESCRIPTION
  Reads knowledge/INDEX.md, matches table rows containing the keyword
  (case-insensitive), and outputs matching entries with file references.
.PARAMETER Keyword
  Search keyword. Supports partial matching.
.PARAMETER IndexPath
  Path to INDEX.md. Defaults to ../knowledge/INDEX.md relative to this script.
.PARAMETER Raw
  Output full matched table rows instead of parsed columns.
.EXAMPLE
  .\search-knowledge.ps1 -Keyword "入库"
  .\search-knowledge.ps1 -Keyword "T100" -Raw
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Keyword,

    [string]$IndexPath,

    [switch]$Raw
)

# Resolve index path
if (-not $IndexPath) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $IndexPath = Join-Path $ScriptDir "..\knowledge\INDEX.md"
}
$IndexPath = [System.IO.Path]::GetFullPath($IndexPath)

if (-not (Test-Path $IndexPath)) {
    Write-Host "INDEX.md not found: $IndexPath"
    exit 1
}

$lines = Get-Content -Path $IndexPath -Encoding UTF8
$headerSeen = $false
$found = 0

foreach ($line in $lines) {
    # Detect 3-column index table header (not a separator), skip 2-column directory table
    if (-not $headerSeen -and $line -match '^\|[^|]+\|[^|]+\|[^|]+\|' -and $line -notmatch '^\|[-| ]+\|') {
        $headerSeen = $true
        continue
    }
    # Skip separator rows
    if ($line -match '^\|[-| ]+\|') { continue }
    # Exit table area on non-table line
    if ($line -notmatch '^\|') { $headerSeen = $false; continue }

    # Inside index table body: search for keyword
    if ($headerSeen -and $line -match [regex]::Escape($Keyword)) {
        if ($Raw) {
            Write-Host $line
        } else {
            $parts = $line -split '\|'
            if ($parts.Count -ge 4) {
                $kw = $parts[1].Trim()
                $file = $parts[2].Trim()
                $desc = $parts[3].Trim()
                Write-Host "$kw  ->  $file  |  $desc"
            }
        }
        $found++
    }
}

if ($found -eq 0) {
    Write-Host "No match for '$Keyword' in knowledge index."
}
