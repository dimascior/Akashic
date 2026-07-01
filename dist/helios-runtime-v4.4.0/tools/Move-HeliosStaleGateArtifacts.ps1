# Archive stale gate artifacts from pending/ and inflight/.
# Moves files to evidence/stale/ and writes a cleanup-summary.json.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GateRoot,

    [switch]$IncludeBlocked,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$staleDir = Join-Path $GateRoot 'evidence\stale'
if (-not $DryRun -and -not (Test-Path $staleDir)) {
    New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
}

$moved = @()
$skipped = @()

foreach ($sourceDir in @('pending', 'inflight')) {
    $sourcePath = Join-Path $GateRoot $sourceDir
    if (-not (Test-Path $sourcePath)) { continue }

    $files = Get-ChildItem -Path $sourcePath -Filter '*.gate.json' -File
    foreach ($file in $files) {
        $destPath = Join-Path $staleDir "$sourceDir-$($file.Name)"
        $entry = @{
            source      = "$sourceDir/$($file.Name)"
            destination = "evidence/stale/$sourceDir-$($file.Name)"
            size_bytes  = $file.Length
        }

        if ($DryRun) {
            $entry['action'] = 'would_move'
            $moved += $entry
        } else {
            Move-Item -LiteralPath $file.FullName -Destination $destPath -Force
            $entry['action'] = 'moved'
            $moved += $entry
        }
    }
}

if ($IncludeBlocked) {
    $blockedPath = Join-Path $GateRoot 'blocked'
    if (Test-Path $blockedPath) {
        $blockedFiles = Get-ChildItem -Path $blockedPath -Filter '*.blocked.json' -File
        foreach ($file in $blockedFiles) {
            $destPath = Join-Path $staleDir "blocked-$($file.Name)"
            $entry = @{
                source      = "blocked/$($file.Name)"
                destination = "evidence/stale/blocked-$($file.Name)"
                size_bytes  = $file.Length
            }

            if ($DryRun) {
                $entry['action'] = 'would_move'
                $moved += $entry
            } else {
                Move-Item -LiteralPath $file.FullName -Destination $destPath -Force
                $entry['action'] = 'moved'
                $moved += $entry
            }
        }
    }
}

$computeHashesPath = Join-Path $GateRoot 'compute-hashes.ps1'
if (Test-Path $computeHashesPath) {
    $destPath = Join-Path $staleDir 'compute-hashes.ps1'
    $entry = @{
        source      = 'compute-hashes.ps1'
        destination = 'evidence/stale/compute-hashes.ps1'
        size_bytes  = (Get-Item $computeHashesPath).Length
    }

    if ($DryRun) {
        $entry['action'] = 'would_move'
    } else {
        Move-Item -LiteralPath $computeHashesPath -Destination $destPath -Force
        $entry['action'] = 'moved'
    }
    $moved += $entry
}

$summary = @{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    dry_run       = [bool]$DryRun
    artifacts     = $moved
    total_moved   = ($moved | Where-Object { $_.action -eq 'moved' }).Count
    total_pending = ($moved | Where-Object { $_.action -eq 'would_move' }).Count
}

if (-not $DryRun) {
    $summaryPath = Join-Path $staleDir 'cleanup-summary.json'
    $summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    $summary['summary_path'] = $summaryPath
}

$summary | ConvertTo-Json -Depth 3
return $summary
