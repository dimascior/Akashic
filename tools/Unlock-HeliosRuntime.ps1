[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

if (-not (Test-Path $HeliosGateRoot)) {
    throw "Helios gate root not found: $HeliosGateRoot"
}

$unlockScript = Join-Path $AkashicRoot 'tools' 'Unlock-AkashicProtectedFiles.ps1'
if (-not (Test-Path $unlockScript)) {
    throw "Unlock script not found: $unlockScript"
}

Write-Host '--- Unlocking runtime ---'
$unlockArgs = @{ HeliosGateRoot = $HeliosGateRoot }
if ($EvidenceOutputDir) {
    $unlockArgs['EvidenceOutputDir'] = $EvidenceOutputDir
}

$unlockResult = & $unlockScript @unlockArgs
Write-Host "Unlock result: $($unlockResult.status)"

return $unlockResult
