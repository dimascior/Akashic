<#
.SYNOPSIS
    Record entry into a bounded maintenance transition.
.DESCRIPTION
    Phase 4.4I awareness tool. Captures prior state and records the intended
    transition. Does NOT disable enforcement — the maintenance corridor in
    helios_pretooluse.ps1 handles actual rebaseline permissions.
.PARAMETER GateRoot
    Path to .command-gate directory.
.PARAMETER TransitionType
    Type of maintenance transition.
.PARAMETER RequestedTransition
    Human-readable description of what will happen.
.PARAMETER AuthorizedBy
    Identity authorizing the transition.
.PARAMETER ExpiryMinutes
    How long the maintenance window lasts. Default: 30.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GateRoot,
    [Parameter(Mandatory)][ValidateSet('reset', 'restore', 'uninstall', 'activate', 'deactivate')][string]$TransitionType,
    [Parameter(Mandatory)][string]$RequestedTransition,
    [Parameter(Mandatory)][string]$AuthorizedBy,
    [int]$ExpiryMinutes = 30
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

$NowUtc = (Get-Date).ToUniversalTime()
$Expiry = $NowUtc.AddMinutes($ExpiryMinutes)

$sha = [System.Security.Cryptography.SHA256]::Create()

$priorState = @{
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
    $priorState.manifest_hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($manifestPath)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
if (Test-Path $sidecarPath) {
    $priorState.sidecar_hash = (Get-Content $sidecarPath -Raw).Trim()
}
if (Test-Path $originPath) {
    $priorState.origin_hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($originPath)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
if (Test-Path $settingsPath) {
    $priorState.settings_hash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($settingsPath)) | ForEach-Object { $_.ToString('x2') }) -join ''
    try {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.PreToolUse) {
            $priorState.hooks_active = $true
        }
    } catch {}
}

$evidence = [ordered]@{
    schema_version             = 'helios-maintenance-transition-evidence.v1'
    timestamp_utc              = $NowUtc.ToString('o')
    transition_type            = $TransitionType
    requested_transition       = $RequestedTransition
    prior_state_snapshot       = $priorState
    allowed_operation          = $RequestedTransition
    expected_final_state       = $null
    actual_final_state         = $null
    transition_authorized_by   = $AuthorizedBy
    authority_type             = 'tool_reported'
    authorization_method       = 'Enter-HeliosMaintenanceMode invocation'
    authorization_proof_present = $false
    authorization_proof_ref    = $null
    bounded                    = $true
    expiry                     = $Expiry.ToString('o')
    steps                      = @()
    overall                    = 'PARTIAL'
}

$evidenceDir = Join-Path $GateRoot 'evidence\maintenance'
if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }

$Ts = $NowUtc.ToString('yyyyMMdd-HHmmss')
$evidencePath = Join-Path $evidenceDir "$Ts-enter-$TransitionType.json"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 5), $Utf8NoBom)

Write-Host "Maintenance mode entered: $TransitionType"
Write-Host "Authorized by: $AuthorizedBy"
Write-Host "Expires: $($Expiry.ToString('o'))"
Write-Host "Evidence: $evidencePath"

$evidence
