[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$pendingDir = Join-Path $HeliosGateRoot 'pending'
if (-not (Test-Path $pendingDir)) {
    Write-Host "No pending directory: $pendingDir"
    return @{ removed = 0 }
}

$gateFiles = Get-ChildItem -Path $pendingDir -Filter '*.gate.json' -File -ErrorAction SilentlyContinue
if (-not $gateFiles -or $gateFiles.Count -eq 0) {
    Write-Host 'No pending gates to clean.'
    return @{ removed = 0 }
}

$nowUtc = (Get-Date).ToUniversalTime()
$staleDir = Join-Path $HeliosGateRoot 'evidence' 'stale'
if (-not (Test-Path $staleDir)) {
    New-Item -ItemType Directory -Path $staleDir -Force | Out-Null
}

$removed = @()
$kept = 0

foreach ($file in $gateFiles) {
    try {
        $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        $gate = $raw | ConvertFrom-Json

        $expired = $false
        if ($gate.expires_utc) {
            $expiresAt = [DateTime]::Parse($gate.expires_utc).ToUniversalTime()
            $expired = $nowUtc -gt $expiresAt
        }

        if ($expired) {
            if ($WhatIf) {
                Write-Host "  [WOULD REMOVE] $($file.Name) (expired $($gate.expires_utc))"
            } else {
                $dest = Join-Path $staleDir $file.Name
                Move-Item -Path $file.FullName -Destination $dest -Force
                Write-Host "  [MOVED TO STALE] $($file.Name)"
            }
            $removed += $file.Name
        } else {
            $kept++
        }
    } catch {
        Write-Host "  [ERROR] $($file.Name): $($_.Exception.Message)"
    }
}

$action = if ($WhatIf) { 'would remove' } else { 'moved to stale' }
Write-Host "Stale gate cleanup: $($removed.Count) $action, $kept active gates kept."

return [ordered]@{
    removed       = $removed.Count
    removed_files = $removed
    kept          = $kept
    whatif        = [bool]$WhatIf
}
