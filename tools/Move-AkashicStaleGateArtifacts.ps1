<#
.SYNOPSIS
    Clean up stale gate artifacts from pending/ and inflight/ directories.
.DESCRIPTION
    Phase 4.1 mutable lifecycle hygiene for Phase 4.0 test #5 (stale gate).
    Moves expired gates from pending/ to a stale/ archive directory.
    Moves orphaned inflight gates older than a threshold.
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER StaleArchiveDir
    Where to move stale artifacts. Defaults to .command-gate/stale/.
.PARAMETER InflightMaxAgeMinutes
    Inflight gates older than this are considered orphaned. Default: 30.
.PARAMETER WhatIf
    Show what would be moved without applying changes.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$StaleArchiveDir,

    [int]$InflightMaxAgeMinutes = 30
)

$ErrorActionPreference = 'Stop'

if (-not $StaleArchiveDir) {
    $StaleArchiveDir = Join-Path $HeliosGateRoot 'stale'
}

$nowUtc = (Get-Date).ToUniversalTime()
$results = @()

# Process pending/ for expired gates
$pendingDir = Join-Path $HeliosGateRoot 'pending'
if (Test-Path $pendingDir) {
    $gateFiles = Get-ChildItem -Path $pendingDir -Filter '*.gate.json' -File -ErrorAction SilentlyContinue
    foreach ($gf in $gateFiles) {
        try {
            $gate = Get-Content $gf.FullName -Raw | ConvertFrom-Json
            if ($gate.expires_utc) {
                $expiresUtc = [datetime]::Parse($gate.expires_utc).ToUniversalTime()
                if ($expiresUtc -lt $nowUtc) {
                    if ($PSCmdlet.ShouldProcess($gf.Name, "Move expired gate to stale/")) {
                        if (-not (Test-Path $StaleArchiveDir)) {
                            New-Item -ItemType Directory -Path $StaleArchiveDir -Force | Out-Null
                        }
                        $destPath = Join-Path $StaleArchiveDir $gf.Name
                        Move-Item $gf.FullName $destPath -Force
                        Write-Host "MOVED (expired): $($gf.Name) -> stale/"
                        $results += @{ File = $gf.Name; Source = 'pending'; Reason = 'expired'; ExpiresUtc = $gate.expires_utc; Status = 'MOVED' }
                    } else {
                        Write-Host "WOULD MOVE (expired): $($gf.Name)"
                        $results += @{ File = $gf.Name; Source = 'pending'; Reason = 'expired'; ExpiresUtc = $gate.expires_utc; Status = 'WHATIF' }
                    }
                }
            }
        } catch {
            Write-Warning "Could not parse gate $($gf.Name): $($_.Exception.Message)"
            $results += @{ File = $gf.Name; Source = 'pending'; Reason = 'parse_error'; Status = 'SKIPPED' }
        }
    }

    # Also clean non-.gate.json files that may be leftover
    $nonGateFiles = Get-ChildItem -Path $pendingDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ne '.json' -or $_.Name -notmatch '\.gate\.json$' }
    foreach ($ngf in $nonGateFiles) {
        if ($ngf.Name -match '\.gate\.json$') { continue }
        if ($ngf.Name -eq '.gitkeep') { continue }
        $ageMinutes = ($nowUtc - $ngf.LastWriteTimeUtc).TotalMinutes
        if ($ageMinutes -gt $InflightMaxAgeMinutes) {
            Write-Warning "Non-standard file in pending/: $($ngf.Name) (age: $([int]$ageMinutes) min)"
            $results += @{ File = $ngf.Name; Source = 'pending'; Reason = 'non_standard'; Status = 'FLAGGED' }
        }
    }
}

# Process inflight/ for orphaned gates
$inflightDir = Join-Path $HeliosGateRoot 'inflight'
if (Test-Path $inflightDir) {
    $inflightFiles = Get-ChildItem -Path $inflightDir -Filter '*.gate.json' -File -ErrorAction SilentlyContinue
    foreach ($inf in $inflightFiles) {
        $ageMinutes = ($nowUtc - $inf.LastWriteTimeUtc).TotalMinutes
        if ($ageMinutes -gt $InflightMaxAgeMinutes) {
            if ($PSCmdlet.ShouldProcess($inf.Name, "Move orphaned inflight gate to stale/")) {
                if (-not (Test-Path $StaleArchiveDir)) {
                    New-Item -ItemType Directory -Path $StaleArchiveDir -Force | Out-Null
                }
                $destPath = Join-Path $StaleArchiveDir $inf.Name
                Move-Item $inf.FullName $destPath -Force
                Write-Host "MOVED (orphaned): $($inf.Name) -> stale/ (age: $([int]$ageMinutes) min)"
                $results += @{ File = $inf.Name; Source = 'inflight'; Reason = 'orphaned'; AgeMinutes = [int]$ageMinutes; Status = 'MOVED' }
            } else {
                Write-Host "WOULD MOVE (orphaned): $($inf.Name) (age: $([int]$ageMinutes) min)"
                $results += @{ File = $inf.Name; Source = 'inflight'; Reason = 'orphaned'; AgeMinutes = [int]$ageMinutes; Status = 'WHATIF' }
            }
        }
    }
}

$movedCount = ($results | Where-Object { $_.Status -eq 'MOVED' }).Count
$flaggedCount = ($results | Where-Object { $_.Status -eq 'FLAGGED' }).Count

Write-Host "`n--- Cleanup Summary ---"
Write-Host "Moved:   $movedCount"
Write-Host "Flagged: $flaggedCount"

$results
