[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [switch]$RelockAfter,

    [switch]$RequireStrongLock,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

if (-not (Test-Path $HeliosGateRoot)) {
    throw "Helios gate root not found: $HeliosGateRoot"
}

$rebaselineScript = Join-Path $AkashicRoot 'tools' 'Invoke-AkashicRebaseline.ps1'
$manifestScript = Join-Path $AkashicRoot 'tools' 'AkashicEnvelopeManifest.ps1'

if (-not (Test-Path $rebaselineScript)) {
    throw "Rebaseline script not found: $rebaselineScript"
}
if (-not (Test-Path $manifestScript)) {
    throw "Manifest script not found: $manifestScript"
}

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $AkashicRoot 'evidence' 'phase42'
}
if (-not (Test-Path $EvidenceOutputDir)) {
    New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null
}

# Step 1: Unlock if locked
Write-Host '--- Step 1: Unlock runtime for maintenance ---'
$unlockScript = Join-Path $AkashicRoot 'tools' 'Unlock-AkashicProtectedFiles.ps1'
if (Test-Path $unlockScript) {
    try {
        & $unlockScript -HeliosGateRoot $HeliosGateRoot
        Write-Host 'Unlocked.'
    } catch {
        Write-Host "Unlock skipped (may not be locked): $($_.Exception.Message)"
    }
}

# Step 2: Rebaseline manifest
Write-Host '--- Step 2: Rebaseline manifest ---'
$rebaseResult = & $manifestScript -HeliosGateRoot $HeliosGateRoot
Write-Host "Manifest status: $($rebaseResult.status)"

# Step 3: Verify integrity
Write-Host '--- Step 3: Verify envelope integrity ---'
$integrityScript = Join-Path $AkashicRoot 'tools' 'AkashicEnvelopeIntegrityValidation.ps1'
if (Test-Path $integrityScript) {
    $integrityResult = & $integrityScript -HeliosGateRoot $HeliosGateRoot
    Write-Host "Integrity: $($integrityResult.status)"
} else {
    Write-Host "Integrity script not found, skipping verification."
    $integrityResult = @{ status = 'SKIPPED' }
}

# Step 4: Re-lock if requested
$lockResult = @{ status = 'SKIPPED' }
if ($RelockAfter) {
    Write-Host '--- Step 4: Re-lock runtime ---'
    $lockScript = Join-Path $AkashicRoot 'tools' 'Lock-AkashicProtectedFiles.ps1'
    if (Test-Path $lockScript) {
        $lockArgs = @{ HeliosGateRoot = $HeliosGateRoot }
        if ($RequireStrongLock) { $lockArgs['RequireStrongLock'] = $true }
        $lockResult = & $lockScript @lockArgs
        Write-Host "Lock: $($lockResult.status)"
    } else {
        Write-Host 'Lock script not found.'
        $lockResult = @{ status = 'SCRIPT_NOT_FOUND' }
    }
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$summary = [ordered]@{
    schema_version   = 'helios-rebaseline-evidence.v1'
    timestamp_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    helios_gate_root = $HeliosGateRoot
    manifest_status  = $rebaseResult.status
    integrity_status = $integrityResult.status
    relock_status    = $lockResult.status
    overall          = if ($integrityResult.status -eq 'CLEAN' -or $integrityResult.status -eq 'SKIPPED') { 'REBASELINE_COMPLETE' } else { 'REBASELINE_DRIFT' }
}

$summaryPath = Join-Path $EvidenceOutputDir 'rebaseline-evidence.json'
[System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 5), $Utf8NoBom)
Write-Host "Evidence: $summaryPath"
Write-Host "Overall: $($summary.overall)"

return $summary
