# Install-AkashicHeliosRuntime.ps1 — Akashic installer for a Helios runtime
# Akashic installs, prepares, verifies, activates, and locks a Helios runtime.
# Helios is the runtime that actually controls Claude's Bash/PowerShell execution.
#
# Phase boundary: Prepare copies files and generates the manifest. Activation
# modifies Claude settings to point to Helios hooks. These are separate steps
# — Prepare never touches settings, and activation requires explicit opt-in.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$RuntimeBundleRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [ValidateSet('Auto', 'Windows', 'Linux', 'macOS')]
    [string]$Platform = 'Auto',

    [switch]$ActivateClaudeHooks,

    [switch]$Verify,

    [switch]$LockRuntime,

    [switch]$RunFixtureCheck,

    [switch]$RequireStrongLock,

    [switch]$WhatIf,

    [string]$ClaudeSettingsPath,

    [int]$HookTimeout = 15,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

if ($Platform -eq 'Auto') {
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { $Platform = 'Windows' }
    elseif ($IsMacOS) { $Platform = 'macOS' }
    elseif ($IsLinux) { $Platform = 'Linux' }
    else { $Platform = 'Windows' }
}

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $AkashicRoot 'evidence\phase42'
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$results = [ordered]@{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    platform      = $Platform
    steps         = [System.Collections.Generic.List[object]]::new()
    overall       = 'PENDING'
}

function Add-Step([string]$Name, [string]$Status, $Detail) {
    $results.steps.Add([ordered]@{ step = $Name; status = $Status; detail = $Detail })
    $mark = switch ($Status) { 'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }; 'SKIP' { '[SKIP]' }; default { "[${Status}]" } }
    Write-Host "$mark $Name"
}

$modeLabel = if ($WhatIf) { ' (DRY RUN)' } else { '' }
Write-Host "=== Helios Runtime Install via Akashic$modeLabel ==="
Write-Host "Platform:          $Platform"
Write-Host "AkashicRoot:       $AkashicRoot"
Write-Host "RuntimeBundleRoot: $RuntimeBundleRoot"
Write-Host "HeliosGateRoot:    $HeliosGateRoot"
Write-Host ""

# ============================================================
# Step 0: Prerequisites
# ============================================================
Write-Host "--- Step 0: Prerequisites ---"
$prereqScript = Join-Path $ScriptDir 'Test-HeliosPrerequisites.ps1'
if (Test-Path $prereqScript) {
    $prereqArgs = @{
        HeliosGateRoot = $HeliosGateRoot
        Platform       = $Platform
    }
    if ($ClaudeSettingsPath) { $prereqArgs['ClaudeSettingsPath'] = $ClaudeSettingsPath }

    $prereqResult = & $prereqScript @prereqArgs

    if ($prereqResult.status -eq 'READY') {
        Add-Step 'Prerequisites' 'PASS' ([ordered]@{
            checks   = $prereqResult.checks.Count
            blockers = 0
        })
    } else {
        Add-Step 'Prerequisites' 'FAIL' ([ordered]@{
            blockers = $prereqResult.blockers
        })
        $results.overall = 'BLOCKED'
        Write-Host ""
        Write-Host "=== Helios Install BLOCKED at Prerequisites ==="
        return $results
    }
} else {
    Add-Step 'Prerequisites' 'SKIP' 'Test-HeliosPrerequisites.ps1 not found'
}

# ============================================================
# Step 1: Run Prepare
# ============================================================
Write-Host ""
Write-Host "--- Step 1: Prepare ---"
$prepareArgs = @{
    AkashicRoot       = $AkashicRoot
    RuntimeBundleRoot = $RuntimeBundleRoot
    HeliosGateRoot    = $HeliosGateRoot
    Platform          = $Platform
    Mode              = 'Prepare'
    EvidenceOutputDir = $EvidenceOutputDir
}
if ($RunFixtureCheck) { $prepareArgs['RunFixtureCheck'] = $true }
if ($RequireStrongLock) { $prepareArgs['RequireStrongLock'] = $true }

$preparePlan = & (Join-Path $ScriptDir 'AkashicHeliosInstallPlan.ps1') @prepareArgs

if ($preparePlan.overall_status -eq 'READY') {
    Add-Step 'Prepare' 'PASS' ([ordered]@{
        mode            = $preparePlan.mode
        manifest_status = $preparePlan.manifest_status
        phase_count     = $preparePlan.phases.Count
        blockers        = $preparePlan.blockers
    })
} else {
    Add-Step 'Prepare' 'FAIL' ([ordered]@{
        overall_status = $preparePlan.overall_status
        blockers       = $preparePlan.blockers
    })
    $results.overall = 'BLOCKED'
    Write-Host ""
    Write-Host "=== Install BLOCKED at Prepare step ==="
    return $results
}

# ============================================================
# Step 2: Activate Claude Hooks (optional)
# ============================================================
if ($ActivateClaudeHooks) {
    Write-Host ""
    Write-Host "--- Step 2: Activate Claude Hooks ---"
    $applyArgs = @{
        HeliosGateRoot   = $HeliosGateRoot
        Platform         = $Platform
        HookTimeout      = $HookTimeout
        EvidenceOutputDir = $EvidenceOutputDir
    }
    if ($ClaudeSettingsPath) { $applyArgs['ClaudeSettingsPath'] = $ClaudeSettingsPath }
    if ($WhatIf) { $applyArgs['WhatIf'] = $true }

    $activationResult = & (Join-Path $ScriptDir 'Apply-AkashicClaudeHooks.ps1') @applyArgs

    if ($activationResult.status -eq 'WHATIF') {
        Add-Step 'Activate Claude Hooks' 'PLAN' ([ordered]@{
            hooks_would_add   = $activationResult.hooks_would_add
            hooks_already     = $activationResult.hooks_already_present
            different_root    = $activationResult.different_root_detected
        })
    } elseif ($activationResult.status -eq 'ACTIVATED' -or $activationResult.status -eq 'ALREADY_ACTIVE') {
        Add-Step 'Activate Claude Hooks' 'PASS' ([ordered]@{
            status            = $activationResult.status
            hooks_added       = $activationResult.hooks_added
            hooks_already     = $activationResult.hooks_already_present
            settings_path     = $activationResult.settings_path
            backup_path       = $activationResult.backup_path
        })
    } else {
        Add-Step 'Activate Claude Hooks' 'FAIL' $activationResult
        $results.overall = 'PARTIAL'
    }
} else {
    Add-Step 'Activate Claude Hooks' 'SKIP' 'Not requested (pass -ActivateClaudeHooks)'
}

# ============================================================
# Step 3: Verify (optional)
# ============================================================
if ($Verify) {
    Write-Host ""
    Write-Host "--- Step 3: Live Operational Verification ---"
    $verifyArgs = @{
        HeliosGateRoot   = $HeliosGateRoot
        Platform         = $Platform
        EvidenceOutputDir = $EvidenceOutputDir
    }
    if ($ClaudeSettingsPath) { $verifyArgs['ClaudeSettingsPath'] = $ClaudeSettingsPath }

    $verifyResult = & (Join-Path $ScriptDir 'Test-HeliosLiveOperational.ps1') @verifyArgs

    if ($verifyResult.overall_status -eq 'PASS') {
        Add-Step 'Live Verification' 'PASS' ([ordered]@{
            checks            = $verifyResult.checks.Count
            failures          = $verifyResult.failures.Count
            manifest_integrity = $verifyResult.manifest_integrity
            hook_points        = $verifyResult.hook_points_correct
        })
    } else {
        Add-Step 'Live Verification' 'FAIL' ([ordered]@{
            failures = $verifyResult.failures
        })
        $results.overall = 'PARTIAL'
    }
} else {
    Add-Step 'Live Verification' 'SKIP' 'Not requested (pass -Verify)'
}

# ============================================================
# Step 4: Lock Runtime (optional)
# ============================================================
if ($LockRuntime) {
    Write-Host ""
    Write-Host "--- Step 4: Lock Runtime ---"

    if (-not $ActivateClaudeHooks -or -not $Verify) {
        Add-Step 'Lock Runtime' 'FAIL' 'Locking requires -ActivateClaudeHooks and -Verify to both be passed and succeed'
        $results.overall = 'PARTIAL'
    } else {
        $lockScript = Join-Path $ScriptDir 'Lock-AkashicProtectedFiles.ps1'
        if (Test-Path $lockScript) {
            $lockArgs = @{ HeliosGateRoot = $HeliosGateRoot }
            if ($RequireStrongLock) { $lockArgs['RequireStrongLock'] = $true }
            try {
                & $lockScript @lockArgs
                Add-Step 'Lock Runtime' 'PASS' 'Protected files locked'
            } catch {
                Add-Step 'Lock Runtime' 'FAIL' $_.Exception.Message
                $results.overall = 'PARTIAL'
            }
        } else {
            Add-Step 'Lock Runtime' 'FAIL' "Lock tool not found: $lockScript"
            $results.overall = 'PARTIAL'
        }
    }
} else {
    Add-Step 'Lock Runtime' 'SKIP' 'Not requested (pass -LockRuntime)'
}

# ============================================================
# Final status
# ============================================================
if ($results.overall -eq 'PENDING') {
    $anyFail = $results.steps | Where-Object { $_.status -eq 'FAIL' }
    $results.overall = if ($anyFail) { 'PARTIAL' } else { 'COMPLETE' }
}

Write-Host ""
Write-Host "=== Helios Install $($results.overall)$modeLabel ==="
Write-Host ""
foreach ($s in $results.steps) {
    Write-Host "  $($s.status.PadRight(6)) $($s.step)"
}

# Write install summary evidence
if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
$summaryPath = Join-Path $EvidenceOutputDir 'install-summary.json'
$summaryJson = $results | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($summaryPath, $summaryJson, $Utf8NoBom)
Write-Host "Summary: $summaryPath"

return $results
