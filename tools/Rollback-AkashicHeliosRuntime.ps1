[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$ClaudeSettingsPath,

    [switch]$RestoreFromBackup,

    [switch]$UnlockRuntime,

    [switch]$RemoveRuntime,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $ClaudeSettingsPath) {
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $ClaudeSettingsPath = Join-Path $env:USERPROFILE '.claude' 'settings.json'
    } else {
        $ClaudeSettingsPath = Join-Path $env:HOME '.claude' 'settings.json'
    }
}

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path (Split-Path -Parent $scriptDir) 'evidence' 'phase42'
}
if (-not (Test-Path $EvidenceOutputDir)) {
    New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null
}

$steps = [ordered]@{}

# Step 1: Remove hooks from Claude settings
Write-Host '--- Step 1: Deactivate Claude hooks ---'
$removeScript = Join-Path $scriptDir 'Remove-AkashicClaudeHooks.ps1'
if (-not (Test-Path $removeScript)) {
    throw "Remove-AkashicClaudeHooks.ps1 not found at: $removeScript"
}

$removeArgs = @{
    ClaudeSettingsPath = $ClaudeSettingsPath
}
if ($RestoreFromBackup) {
    $removeArgs['RestoreFromBackup'] = $true
}

$removeResult = & $removeScript @removeArgs
$steps['deactivate_hooks'] = $removeResult
Write-Host "Hook removal: $($removeResult.status)"

# Step 2: Unlock runtime (optional)
if ($UnlockRuntime) {
    Write-Host '--- Step 2: Unlock runtime files ---'
    $unlockScript = Join-Path $scriptDir 'Unlock-AkashicProtectedFiles.ps1'
    if (Test-Path $unlockScript) {
        $unlockResult = & $unlockScript -HeliosGateRoot $HeliosGateRoot
        $steps['unlock_runtime'] = $unlockResult
        Write-Host "Unlock: complete"
    } else {
        $steps['unlock_runtime'] = @{ status = 'SKIPPED'; reason = 'Unlock script not found' }
        Write-Host "Unlock: SKIPPED (script not found)"
    }
} else {
    $steps['unlock_runtime'] = @{ status = 'SKIPPED'; reason = 'Not requested' }
}

# Step 3: Remove runtime directory (optional, requires explicit flag)
if ($RemoveRuntime) {
    Write-Host '--- Step 3: Remove runtime directory ---'
    if (Test-Path $HeliosGateRoot) {
        Remove-Item -Path $HeliosGateRoot -Recurse -Force -Confirm:$false
        $steps['remove_runtime'] = @{ status = 'REMOVED'; path = $HeliosGateRoot }
        Write-Host "Runtime removed: $HeliosGateRoot"
    } else {
        $steps['remove_runtime'] = @{ status = 'NOT_FOUND'; path = $HeliosGateRoot }
        Write-Host "Runtime directory not found (already removed?)"
    }
} else {
    $steps['remove_runtime'] = @{ status = 'SKIPPED'; reason = 'Not requested (-RemoveRuntime not set)' }
}

# Step 4: Verify no hooks active
Write-Host '--- Step 4: Verify hooks deactivated ---'
$verifyOk = $true
if (Test-Path $ClaudeSettingsPath) {
    $settingsRaw = Get-Content -Path $ClaudeSettingsPath -Raw -Encoding UTF8
    if ($settingsRaw -match 'helios_pretooluse' -or $settingsRaw -match 'evidence_capture') {
        $verifyOk = $false
        Write-Host 'WARNING: Helios hook references still found in settings.'
    } else {
        Write-Host 'Verified: no Helios hooks in settings.'
    }
} else {
    Write-Host 'Settings file not found (hooks are inactive).'
}
$steps['verify_deactivated'] = @{ hooks_clear = $verifyOk }

# Write rollback summary
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$summary = [ordered]@{
    schema_version     = 'akashic-rollback-summary.v1'
    timestamp_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    helios_gate_root   = $HeliosGateRoot
    settings_path      = $ClaudeSettingsPath
    restore_from_backup = [bool]$RestoreFromBackup
    unlock_runtime     = [bool]$UnlockRuntime
    remove_runtime     = [bool]$RemoveRuntime
    steps              = $steps
    overall_status     = if ($verifyOk) { 'ROLLBACK_COMPLETE' } else { 'ROLLBACK_PARTIAL' }
}

$summaryPath = Join-Path $EvidenceOutputDir 'rollback-summary.json'
$summaryJson = $summary | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($summaryPath, $summaryJson, $Utf8NoBom)
Write-Host "Rollback evidence: $summaryPath"
Write-Host "Overall: $($summary.overall_status)"

return $summary
