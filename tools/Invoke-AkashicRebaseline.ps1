<#
.SYNOPSIS
    Coordinated unlock-update-relock-verify rebaseline cycle.
.DESCRIPTION
    Phase 4.1 atomic rebaseline workflow:
      1. Verify current lock status (pre-flight)
      2. Unlock protected files
      3. Execute the update action (user-supplied script block or sync)
      4. Regenerate manifest (AkashicEnvelopeManifest)
      5. Relock protected files
      6. Verify locks restored (post-flight)
      7. Verify envelope integrity (AkashicEnvelopeIntegrityValidation)

    If any step fails, attempts rollback by relocking immediately.
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER UpdateAction
    Script block to execute while files are unlocked. Receives $HeliosGateRoot as argument.
    Example: { param($root) Copy-Item source.ps1 (Join-Path $root 'hooks\gate_check.ps1') -Force }
.PARAMETER RebaselinedBy
    Who authorized the rebaseline. Passed to AkashicEnvelopeManifest.
.PARAMETER IncludeSettingsJson
    Also unlock/relock settings.json during rebaseline.
.PARAMETER SettingsJsonPath
    Path to Claude settings.json.
.PARAMETER IncludeTemplates
    Also unlock/relock templates/ during rebaseline.
.PARAMETER ToolsRoot
    Path to the adapter tools directory. Defaults to the tools/ sibling of this script.
.PARAMETER PrivilegeMode
    Privilege escalation mode for Linux. Auto|None|Sudo|Doas|RootOnly.
.PARAMETER RequireStrongLock
    Fail if a strong backend is not available.
.PARAMETER AllowWeakFallback
    Allow degradation to chmod a-w.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [scriptblock]$UpdateAction,

    [Parameter(Mandatory)]
    [string]$RebaselinedBy,

    [switch]$IncludeSettingsJson,

    [string]$SettingsJsonPath,

    [switch]$IncludeTemplates,

    [string]$ToolsRoot = $PSScriptRoot,

    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [switch]$RequireStrongLock,

    [switch]$AllowWeakFallback
)

$ErrorActionPreference = 'Stop'

$lockScript = Join-Path $ToolsRoot 'Lock-AkashicProtectedFiles.ps1'
$unlockScript = Join-Path $ToolsRoot 'Unlock-AkashicProtectedFiles.ps1'
$lockStatusScript = Join-Path $ToolsRoot 'AkashicLockStatus.ps1'
$manifestScript = Join-Path $ToolsRoot 'AkashicEnvelopeManifest.ps1'
$integrityScript = Join-Path $ToolsRoot 'AkashicEnvelopeIntegrityValidation.ps1'

$rebaselineResult = @{
    schema_version = '1.0'
    started_utc = (Get-Date).ToUniversalTime().ToString('o')
    rebaselined_by = $RebaselinedBy
    steps = @()
    status = 'IN_PROGRESS'
}

foreach ($script in @($lockScript, $unlockScript, $lockStatusScript, $manifestScript, $integrityScript)) {
    if (-not (Test-Path $script)) {
        $rebaselineResult.status = 'FAILED'
        $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
        Write-Error "Required tool not found: $script"
        return $rebaselineResult
    }
}

if (-not $SettingsJsonPath) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { '~' }
    $SettingsJsonPath = Join-Path $homeDir '.claude/settings.json'
}

$commonParams = @{
    HeliosGateRoot    = $HeliosGateRoot
    PrivilegeMode     = $PrivilegeMode
}
if ($RequireStrongLock) { $commonParams['RequireStrongLock'] = $true }
if ($AllowWeakFallback) { $commonParams['AllowWeakFallback'] = $true }
if ($IncludeSettingsJson) {
    $commonParams['IncludeSettingsJson'] = $true
    $commonParams['SettingsJsonPath'] = $SettingsJsonPath
}
if ($IncludeTemplates) {
    $commonParams['IncludeTemplates'] = $true
}

function Add-Step {
    param([string]$Name, [string]$Status, [string]$Detail)
    $rebaselineResult.steps += @{
        step = $Name
        status = $Status
        detail = $Detail
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-Host "[$Status] $Name $(if ($Detail) { "— $Detail" })"
}

function Emergency-Relock {
    Write-Warning "EMERGENCY RELOCK: attempting to restore locks after failure..."
    try {
        & $lockScript @commonParams | Out-Null
        Add-Step -Name 'emergency_relock' -Status 'RECOVERED' -Detail 'Locks restored after failure'
    } catch {
        Add-Step -Name 'emergency_relock' -Status 'FAILED' -Detail $_.Exception.Message
        Write-Error "CRITICAL: Emergency relock failed. Protected files may be exposed. Manual intervention required."
    }
}

# Step 1: Pre-flight lock verification
Write-Host "`n=== Rebaseline: Step 1 — Pre-flight Lock Check ===`n"
try {
    $preflight = & $lockStatusScript @commonParams
    Add-Step -Name 'preflight_lock_check' -Status 'PASS' -Detail 'Current lock state verified'
} catch {
    Add-Step -Name 'preflight_lock_check' -Status 'WARN' -Detail "Lock check: $($_.Exception.Message)"
}

# Step 2: Unlock
Write-Host "`n=== Rebaseline: Step 2 — Unlock ===`n"
try {
    $unlockResults = & $unlockScript @commonParams
    $unlockFailed = ($unlockResults | Where-Object { $_.Status -eq 'FAILED' }).Count
    if ($unlockFailed -gt 0) {
        Add-Step -Name 'unlock' -Status 'FAILED' -Detail "$unlockFailed file(s) failed to unlock"
        $rebaselineResult.status = 'FAILED'
        $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
        return $rebaselineResult
    }
    Add-Step -Name 'unlock' -Status 'PASS' -Detail 'All protected files unlocked'
} catch {
    Add-Step -Name 'unlock' -Status 'FAILED' -Detail $_.Exception.Message
    $rebaselineResult.status = 'FAILED'
    $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
    return $rebaselineResult
}

# Step 3: Execute update action
Write-Host "`n=== Rebaseline: Step 3 — Update Action ===`n"
try {
    & $UpdateAction $HeliosGateRoot
    Add-Step -Name 'update_action' -Status 'PASS' -Detail 'Update completed'
} catch {
    Add-Step -Name 'update_action' -Status 'FAILED' -Detail $_.Exception.Message
    Emergency-Relock
    $rebaselineResult.status = 'FAILED_WITH_RELOCK'
    $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
    return $rebaselineResult
}

# Step 4: Regenerate manifest
Write-Host "`n=== Rebaseline: Step 4 — Regenerate Manifest ===`n"
try {
    & $manifestScript -HeliosGateRoot $HeliosGateRoot -RebaselinedBy $RebaselinedBy
    Add-Step -Name 'regenerate_manifest' -Status 'PASS' -Detail 'Manifest regenerated'
} catch {
    Add-Step -Name 'regenerate_manifest' -Status 'FAILED' -Detail $_.Exception.Message
    Emergency-Relock
    $rebaselineResult.status = 'FAILED_WITH_RELOCK'
    $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
    return $rebaselineResult
}

# Step 5: Relock
Write-Host "`n=== Rebaseline: Step 5 — Relock ===`n"
try {
    $relockResults = & $lockScript @commonParams
    $relockFailed = ($relockResults | Where-Object { $_.Status -eq 'FAILED' }).Count
    if ($relockFailed -gt 0) {
        Add-Step -Name 'relock' -Status 'FAILED' -Detail "$relockFailed file(s) failed to relock"
        $rebaselineResult.status = 'PARTIAL_RELOCK'
        $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
        return $rebaselineResult
    }
    Add-Step -Name 'relock' -Status 'PASS' -Detail 'All protected files relocked'
} catch {
    Add-Step -Name 'relock' -Status 'FAILED' -Detail $_.Exception.Message
    $rebaselineResult.status = 'RELOCK_FAILED'
    $rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
    Write-Error "CRITICAL: Relock failed. Protected files may be exposed."
    return $rebaselineResult
}

# Step 6: Post-flight lock verification
Write-Host "`n=== Rebaseline: Step 6 — Post-flight Lock Check ===`n"
try {
    $postflight = & $lockStatusScript @commonParams
    Add-Step -Name 'postflight_lock_check' -Status 'PASS' -Detail 'Locks verified after rebaseline'
} catch {
    Add-Step -Name 'postflight_lock_check' -Status 'WARN' -Detail "Post-flight: $($_.Exception.Message)"
}

# Step 7: Verify envelope integrity
Write-Host "`n=== Rebaseline: Step 7 — Envelope Integrity Verification ===`n"
try {
    & $integrityScript -HeliosGateRoot $HeliosGateRoot
    Add-Step -Name 'envelope_integrity' -Status 'PASS' -Detail 'Envelope integrity verified after rebaseline'
} catch {
    Add-Step -Name 'envelope_integrity' -Status 'WARN' -Detail "Integrity check: $($_.Exception.Message)"
}

$rebaselineResult.status = 'COMPLETE'
$rebaselineResult.completed_utc = (Get-Date).ToUniversalTime().ToString('o')

Write-Host "`n=== Rebaseline Complete ===`n"

$rebaselineResult
