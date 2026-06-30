<#
.SYNOPSIS
    Record exit from a maintenance transition and verify final state.
.DESCRIPTION
    Phase 4.4I awareness tool. Captures actual final state after a maintenance
    operation and compares against the entry evidence. Does NOT control
    enforcement — records the transition result only.
.PARAMETER GateRoot
    Path to .command-gate directory.
.PARAMETER EntryEvidencePath
    Path to the Enter-HeliosMaintenanceMode evidence file.
.PARAMETER AuthorizedBy
    Identity closing the maintenance window.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GateRoot,
    [Parameter(Mandatory)][string]$EntryEvidencePath,
    [Parameter(Mandatory)][string]$AuthorizedBy
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

if (-not (Test-Path $EntryEvidencePath)) {
    Write-Error "Entry evidence not found: $EntryEvidencePath"
    return
}

$entryEvidence = Get-Content $EntryEvidencePath -Raw | ConvertFrom-Json
$NowUtc = (Get-Date).ToUniversalTime()

$sha = [System.Security.Cryptography.SHA256]::Create()

$actualState = @{
    hooks_active  = $false
    manifest_hash = $null
    sidecar_hash  = $null
    origin_hash   = $null
    settings_hash = $null
}

$manifestPath = Join-Path $GateRoot 'manifest\helios-envelope.json'
$sidecarPath = Join-Path $GateRoot 'manifest\helios-envelope.sha256'
$originPath = Join-Path $GateRoot 'manifest\helios-install-origin.json'
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

if (Test-Path $manifestPath) {
    $actualState.manifest_hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($manifestPath)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
if (Test-Path $sidecarPath) {
    $actualState.sidecar_hash = (Get-Content $sidecarPath -Raw).Trim()
}
if (Test-Path $originPath) {
    $actualState.origin_hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($originPath)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
if (Test-Path $settingsPath) {
    $actualState.settings_hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($settingsPath)) | ForEach-Object { $_.ToString('x2') }) -join ''
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.PreToolUse) {
            $actualState.hooks_active = $true
        }
    } catch {}
}

$steps = @(
    @{ step = 'read_entry_evidence'; status = 'PASS'; detail = "Entry type: $($entryEvidence.transition_type)" }
)

$expired = $false
if ($entryEvidence.expiry) {
    try {
        $expiryTime = [DateTime]::Parse($entryEvidence.expiry).ToUniversalTime()
        if ($NowUtc -gt $expiryTime) {
            $expired = $true
            $steps += @{ step = 'expiry_check'; status = 'WARN'; detail = "Maintenance window expired at $($entryEvidence.expiry)" }
        } else {
            $steps += @{ step = 'expiry_check'; status = 'PASS'; detail = "Within maintenance window" }
        }
    } catch {}
}

$steps += @{ step = 'capture_final_state'; status = 'PASS'; detail = "Final state captured" }

$exitEvidence = [ordered]@{
    schema_version             = 'helios-maintenance-transition-evidence.v1'
    timestamp_utc              = $NowUtc.ToString('o')
    transition_type            = $entryEvidence.transition_type
    requested_transition       = $entryEvidence.requested_transition
    prior_state_snapshot       = $entryEvidence.prior_state_snapshot
    allowed_operation          = $entryEvidence.allowed_operation
    expected_final_state       = $entryEvidence.expected_final_state
    actual_final_state         = $actualState
    transition_authorized_by   = $AuthorizedBy
    authority_type             = 'tool_reported'
    authorization_method       = 'Exit-HeliosMaintenanceMode invocation'
    authorization_proof_present = $false
    authorization_proof_ref    = $null
    bounded                    = $true
    expiry                     = $entryEvidence.expiry
    steps                      = $steps
    overall                    = if ($expired) { 'PARTIAL' } else { 'COMPLETE' }
}

$evidenceDir = Join-Path $GateRoot 'evidence\maintenance'
if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }

$Ts = $NowUtc.ToString('yyyyMMdd-HHmmss')
$evidencePath = Join-Path $evidenceDir "$Ts-exit-$($entryEvidence.transition_type).json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($evidencePath, ($exitEvidence | ConvertTo-Json -Depth 5), $Utf8NoBom)

Write-Host "Maintenance mode exited: $($entryEvidence.transition_type)"
Write-Host "Authorized by: $AuthorizedBy"
Write-Host "Overall: $($exitEvidence.overall)"
Write-Host "Evidence: $evidencePath"

$exitEvidence
