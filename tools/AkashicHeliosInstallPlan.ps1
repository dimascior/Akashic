# AkashicHeliosInstallPlan.ps1 — Unified Akashic + Helios install planner
# Supersedes AkashicInstallPlan.ps1 and AkashicCombinedInstallPlan.ps1
# with platform detection, fixture support, and the full 16-phase plan.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [ValidateSet('Auto', 'Windows', 'Linux', 'macOS')]
    [string]$Platform = 'Auto',

    [ValidateSet('PlanOnly', 'Prepare', 'Activate')]
    [string]$Mode = 'PlanOnly',

    [switch]$RunFixtureCheck,

    [switch]$RequireStrongLock,

    [switch]$AllowWeakFallback,

    [switch]$IncludeSettingsActivation,

    [switch]$IncludeSettingsLock,

    [switch]$IncludeTemplatesLock,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptDir 'lib\AkashicLockTargets.ps1')

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $AkashicRoot 'evidence\phase41'
}

# --- Resolve platform ---
if ($Platform -eq 'Auto') {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $Platform = 'Windows'
    } elseif ($IsWindows) {
        $Platform = 'Windows'
    } elseif ($IsMacOS) {
        $Platform = 'macOS'
    } elseif ($IsLinux) {
        $Platform = 'Linux'
    } else {
        $Platform = 'Windows'
    }
}

# --- Resolve settings path per platform ---
$ClaudeSettingsPath = switch ($Platform) {
    'Windows' { Join-Path $env:USERPROFILE '.claude\settings.json' }
    default   { Join-Path $env:HOME '.claude/settings.json' }
}

$phases = [System.Collections.Generic.List[object]]::new()
$blockers = [System.Collections.Generic.List[string]]::new()

function Add-Phase {
    param(
        [int]$Order,
        [string]$Name,
        [string]$Status,
        [bool]$Blocking = $true,
        [string]$Detail = '',
        [string]$Mode = 'All'
    )
    $phases.Add([ordered]@{
        phase    = $Order
        name     = $Name
        status   = $Status
        blocking = $Blocking
        detail   = $Detail
        mode     = $Mode
    })
}

# ============================================================
# Phase 1: Verify Akashic repo/package identity
# ============================================================
$phase1Status = 'PASS'
$phase1Detail = ''
if (-not (Test-Path $AkashicRoot)) {
    $phase1Status = 'FAIL'
    $phase1Detail = "Akashic root not found: $AkashicRoot"
    $blockers.Add("Phase 1: $phase1Detail")
} else {
    $bridgePath = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
    if (-not (Test-Path $bridgePath)) {
        $phase1Status = 'FAIL'
        $phase1Detail = "Bridge source not found: $bridgePath"
        $blockers.Add("Phase 1: $phase1Detail")
    } else {
        $phase1Detail = "Akashic root verified: $AkashicRoot"
    }
}
Add-Phase -Order 1 -Name 'Verify Akashic repo/package identity' -Status $phase1Status -Detail $phase1Detail

# ============================================================
# Phase 2: Verify Akashic tool availability
# ============================================================
$requiredTools = @(
    'tools/Get-AkashicLockStrategy.ps1',
    'tools/lib/AkashicLockTargets.ps1',
    'tools/lib/AkashicLockBackend.ps1',
    'tools/Lock-AkashicProtectedFiles.ps1',
    'tools/Unlock-AkashicProtectedFiles.ps1',
    'tools/AkashicLockStatus.ps1',
    'tools/Test-AkashicOsLockFixture.ps1',
    'tools/Sync-AkashicBridge.ps1',
    'tools/AkashicEnvelopeManifest.ps1',
    'tools/AkashicEnvelopeIntegrityValidation.ps1',
    'tools/AkashicSettingsIntegrity.ps1'
)
$missingTools = @()
foreach ($tool in $requiredTools) {
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $normalized = $tool.Replace('/', $sep)
    $toolPath = Join-Path $AkashicRoot $normalized
    if (-not (Test-Path $toolPath)) { $missingTools += $tool }
}
$phase2Status = if ($missingTools.Count -eq 0) { 'PASS' } else { 'FAIL' }
$phase2Detail = if ($missingTools.Count -eq 0) {
    "$($requiredTools.Count) required tools verified"
} else {
    "Missing: $($missingTools -join ', ')"
}
if ($phase2Status -eq 'FAIL') { $blockers.Add("Phase 2: $phase2Detail") }
Add-Phase -Order 2 -Name 'Verify Akashic tool availability' -Status $phase2Status -Detail $phase2Detail

# ============================================================
# Phase 3: Verify Helios target .command-gate
# ============================================================
$targetExists = Test-Path $HeliosGateRoot
$phase3Status = 'PASS'
$phase3Detail = ''
if ($targetExists) {
    $phase3Detail = "Target exists: $HeliosGateRoot"
} elseif ($Mode -eq 'PlanOnly') {
    $phase3Status = 'WARN'
    $phase3Detail = "Target does not exist (will be created in Prepare/Activate): $HeliosGateRoot"
} else {
    New-Item -ItemType Directory -Path $HeliosGateRoot -Force | Out-Null
    $phase3Detail = "Target created: $HeliosGateRoot"
}
Add-Phase -Order 3 -Name 'Verify Helios target .command-gate' -Status $phase3Status -Detail $phase3Detail

# ============================================================
# Phase 4: Verify required runtime directories
# ============================================================
$runtimeDirs = @(
    'hooks', 'hooks/lib', 'policy', 'templates', 'schemas',
    'manifest', 'pending', 'inflight', 'evidence', 'blocked',
    'maintenance', 'evidence/integrity', 'evidence/integrity/sessions',
    'evidence/stale', 'evidence/maintenance'
)
$missingDirs = @()
foreach ($d in $runtimeDirs) {
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $dirPath = Join-Path $HeliosGateRoot ($d.Replace('/', $sep))
    if (-not (Test-Path $dirPath)) { $missingDirs += $d }
}

$phase4Status = 'PASS'
$phase4Detail = ''
if ($missingDirs.Count -eq 0) {
    $phase4Detail = "$($runtimeDirs.Count) directories verified"
} elseif ($Mode -eq 'PlanOnly') {
    $phase4Status = 'PLAN'
    $phase4Detail = "$($missingDirs.Count) directories to create: $($missingDirs -join ', ')"
} else {
    foreach ($d in $missingDirs) {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $dirPath = Join-Path $HeliosGateRoot ($d.Replace('/', $sep))
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
    }
    $phase4Detail = "$($missingDirs.Count) directories created"
}
Add-Phase -Order 4 -Name 'Verify required runtime directories' -Status $phase4Status -Detail $phase4Detail

# ============================================================
# Phase 5: Verify protected runtime target list
# ============================================================
$phase5Detail = "$($script:AkashicProtectedFiles.Count) protected files defined"
Add-Phase -Order 5 -Name 'Verify protected runtime target list' -Status 'PASS' -Detail $phase5Detail

# ============================================================
# Phase 6: Verify mutable lifecycle directories
# ============================================================
$phase6Detail = "$($script:AkashicMutableDirs.Count) mutable directories defined: $($script:AkashicMutableDirs -join ', ')"
Add-Phase -Order 6 -Name 'Verify mutable lifecycle directories' -Status 'PASS' -Detail $phase6Detail

# ============================================================
# Phase 7: Verify settings hook routing (if requested)
# ============================================================
$settingsExists = Test-Path $ClaudeSettingsPath
$hooksAlreadyConfigured = $false
if ($settingsExists) {
    try {
        $settings = Get-Content -LiteralPath $ClaudeSettingsPath -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.PreToolUse) { $hooksAlreadyConfigured = $true }
    } catch {}
}
$phase7Status = 'SKIP'
$phase7Detail = 'Settings activation not requested'
if ($IncludeSettingsActivation) {
    if ($hooksAlreadyConfigured) {
        $phase7Status = 'PASS'
        $phase7Detail = 'Settings hooks already configured'
    } elseif ($settingsExists) {
        $phase7Status = 'PLAN'
        $phase7Detail = "Settings exist but hooks not configured: $ClaudeSettingsPath"
    } else {
        $phase7Status = 'WARN'
        $phase7Detail = "Settings file not found: $ClaudeSettingsPath"
    }
}
Add-Phase -Order 7 -Name 'Verify settings hook routing' -Status $phase7Status -Blocking $false -Detail $phase7Detail

# ============================================================
# Phase 8: Detect OS lock strategy
# ============================================================
$strategyScript = Join-Path $AkashicRoot 'tools/Get-AkashicLockStrategy.ps1'
$strategyArgs = @{}
if ($RequireStrongLock) { $strategyArgs['RequireStrongLock'] = $true }
if ($AllowWeakFallback) { $strategyArgs['AllowWeakFallback'] = $true }

$lockStrategy = $null
$phase8Status = 'FAIL'
$phase8Detail = ''
if (Test-Path $strategyScript) {
    try {
        $lockStrategy = & $strategyScript @strategyArgs
        if ($lockStrategy.implemented) {
            $phase8Status = 'PASS'
            $phase8Detail = "Backend: $($lockStrategy.backend), Strength: $($lockStrategy.strength), Privilege: $($lockStrategy.privilege_mode)"
        } else {
            $phase8Detail = "Lock backend not available: $($lockStrategy.blockers -join ', ')"
            $blockers.Add("Phase 8: $phase8Detail")
        }
    } catch {
        $phase8Detail = "Lock strategy detection failed: $_"
        $blockers.Add("Phase 8: $phase8Detail")
    }
} else {
    $phase8Detail = "Strategy script not found: $strategyScript"
    $blockers.Add("Phase 8: $phase8Detail")
}
Add-Phase -Order 8 -Name 'Detect OS lock strategy' -Status $phase8Status -Detail $phase8Detail

# ============================================================
# Phase 9: Run disposable OS lock fixture (if requested)
# ============================================================
$fixtureResult = 'NOT_RUN'
$phase9Status = 'SKIP'
$phase9Detail = 'Fixture check not requested'
if ($RunFixtureCheck) {
    if ($Mode -eq 'PlanOnly') {
        $phase9Status = 'SKIP'
        $phase9Detail = 'Fixture only runs in Prepare/Activate mode'
    } elseif ($lockStrategy -and $lockStrategy.implemented) {
        $fixtureScript = Join-Path $AkashicRoot 'tools/Test-AkashicOsLockFixture.ps1'
        if (Test-Path $fixtureScript) {
            try {
                $fixtureOutput = & $fixtureScript
                if ($fixtureOutput -and $fixtureOutput.overall_result) {
                    $fixtureResult = $fixtureOutput.overall_result
                    $phase9Status = if ($fixtureResult -eq 'PASS') { 'PASS' } else { 'FAIL' }
                    $phase9Detail = "Fixture result: $fixtureResult"
                } else {
                    $fixtureResult = 'FAIL'
                    $phase9Status = 'FAIL'
                    $phase9Detail = 'Fixture returned no result'
                }
            } catch {
                $fixtureResult = 'FAIL'
                $phase9Status = 'FAIL'
                $phase9Detail = "Fixture failed: $_"
            }
        } else {
            $phase9Status = 'FAIL'
            $phase9Detail = "Fixture script not found: $fixtureScript"
        }
        if ($phase9Status -eq 'FAIL') { $blockers.Add("Phase 9: $phase9Detail") }
    } else {
        $phase9Status = 'BLOCKED'
        $phase9Detail = 'Lock strategy not available; cannot run fixture'
        $fixtureResult = 'BLOCKED'
    }
}
Add-Phase -Order 9 -Name 'Run disposable OS lock fixture' -Status $phase9Status -Detail $phase9Detail -Mode 'Prepare/Activate'

# ============================================================
# Phase 10: Generate or verify runtime manifest
# ============================================================
$manifestStatus = 'NOT_GENERATED'
$phase10Status = 'SKIP'
$phase10Detail = 'Manifest generation deferred to Prepare/Activate'
if ($Mode -ne 'PlanOnly') {
    $manifestScript = Join-Path $AkashicRoot 'tools/AkashicEnvelopeManifest.ps1'
    if (Test-Path $manifestScript) {
        try {
            & $manifestScript -HeliosGateRoot $HeliosGateRoot -RebaselinedBy 'installer' -Note 'Unified install plan'
            $manifestStatus = 'GENERATED'
            $phase10Status = 'PASS'
            $phase10Detail = 'Manifest generated'
        } catch {
            $manifestStatus = 'FAIL'
            $phase10Status = 'FAIL'
            $phase10Detail = "Manifest generation failed: $_"
            $blockers.Add("Phase 10: $phase10Detail")
        }
    } else {
        $phase10Status = 'FAIL'
        $phase10Detail = "Manifest script not found: $manifestScript"
        $blockers.Add("Phase 10: $phase10Detail")
    }
}
Add-Phase -Order 10 -Name 'Generate or verify runtime manifest' -Status $phase10Status -Detail $phase10Detail -Mode 'Prepare/Activate'

# ============================================================
# Phase 11: Verify envelope integrity
# ============================================================
$phase11Status = 'SKIP'
$phase11Detail = 'Envelope verification deferred to Prepare/Activate'
if ($Mode -ne 'PlanOnly' -and $manifestStatus -eq 'GENERATED') {
    $verifyScript = Join-Path $AkashicRoot 'tools/AkashicEnvelopeIntegrityValidation.ps1'
    if (Test-Path $verifyScript) {
        try {
            $verifyResult = & $verifyScript -HeliosGateRoot $HeliosGateRoot
            if ($verifyResult -and $verifyResult.verdict -eq 'CLEAN') {
                $manifestStatus = 'CLEAN'
                $phase11Status = 'PASS'
                $phase11Detail = 'Envelope integrity: CLEAN'
            } else {
                $manifestStatus = 'DRIFT'
                $phase11Status = 'FAIL'
                $verdict = if ($verifyResult) { $verifyResult.verdict } else { 'unknown' }
                $phase11Detail = "Envelope integrity: $verdict"
                $blockers.Add("Phase 11: $phase11Detail")
            }
        } catch {
            $phase11Status = 'FAIL'
            $phase11Detail = "Envelope verification failed: $_"
            $blockers.Add("Phase 11: $phase11Detail")
        }
    } else {
        $phase11Status = 'WARN'
        $phase11Detail = "Verification script not found"
    }
}
Add-Phase -Order 11 -Name 'Verify envelope integrity' -Status $phase11Status -Detail $phase11Detail -Mode 'Prepare/Activate'

# ============================================================
# Phase 12: Prepare copy/sync plan for bridge
# ============================================================
$bridgeSource = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
$bridgeDest = Join-Path $HeliosGateRoot 'hooks/lib/HeliosIntegrityBridge.ps1'
$bridgeSyncPlan = [ordered]@{
    source       = $bridgeSource
    dest         = $bridgeDest
    source_exists = (Test-Path $bridgeSource)
    role         = 'bridge_vendor_copy'
    verify       = 'SHA-256 byte identity check after copy'
}

$fileCopyPlan = @()
foreach ($rel in $script:AkashicProtectedFiles) {
    if ($rel -eq 'hooks/lib/HeliosIntegrityBridge.ps1') { continue }
    if ($rel -eq 'manifest/helios-envelope.json') { continue }
    if ($rel -eq 'manifest/helios-envelope.sha256') { continue }
    $fileCopyPlan += [ordered]@{
        relative = $rel
        role     = 'protected_runtime'
    }
}

$phase12Status = if ($bridgeSyncPlan.source_exists) { 'PASS' } else { 'FAIL' }
$phase12Detail = if ($bridgeSyncPlan.source_exists) {
    "Bridge sync plan ready: $bridgeSource -> $bridgeDest"
} else {
    "Bridge source missing: $bridgeSource"
}
if ($phase12Status -eq 'FAIL') { $blockers.Add("Phase 12: $phase12Detail") }

if ($Mode -ne 'PlanOnly' -and $bridgeSyncPlan.source_exists) {
    $syncScript = Join-Path $AkashicRoot 'tools/Sync-AkashicBridge.ps1'
    if (Test-Path $syncScript) {
        try {
            & $syncScript -AkashicRoot $AkashicRoot -HeliosGateRoot $HeliosGateRoot
            $phase12Detail = "Bridge synced: $bridgeDest"
        } catch {
            $phase12Status = 'FAIL'
            $phase12Detail = "Bridge sync failed: $_"
            $blockers.Add("Phase 12: $phase12Detail")
        }
    }
}
Add-Phase -Order 12 -Name 'Prepare copy/sync plan for bridge' -Status $phase12Status -Detail $phase12Detail

# ============================================================
# Phase 13: Prepare settings activation plan
# ============================================================
$settingsActivationPlan = $null
$phase13Status = 'SKIP'
$phase13Detail = 'Settings activation not requested'
if ($IncludeSettingsActivation) {
    $hookCommand = switch ($Platform) {
        'Windows' { "powershell.exe -ExecutionPolicy Bypass -File `"$HeliosGateRoot\hooks\helios_pretooluse.ps1`"" }
        default   { "pwsh -File '$HeliosGateRoot/hooks/helios_pretooluse.ps1'" }
    }
    $evidenceCommand = switch ($Platform) {
        'Windows' { "powershell.exe -ExecutionPolicy Bypass -File `"$HeliosGateRoot\hooks\evidence_capture.ps1`"" }
        default   { "pwsh -File '$HeliosGateRoot/hooks/evidence_capture.ps1'" }
    }
    $settingsActivationPlan = [ordered]@{
        target_file        = $ClaudeSettingsPath
        backup_path        = "$ClaudeSettingsPath.pre-helios-backup"
        requires_approval  = $true
        already_configured = $hooksAlreadyConfigured
        hooks_to_add       = [ordered]@{
            PreToolUse = @(@{
                matcher = 'Bash|PowerShell'
                hooks   = @(@{ type = 'command'; command = $hookCommand })
            })
            PostToolUse = @(@{
                matcher = 'Bash|PowerShell'
                hooks   = @(@{ type = 'command'; command = $evidenceCommand })
            })
            PostToolUseFailure = @(@{
                matcher = 'Bash|PowerShell'
                hooks   = @(@{ type = 'command'; command = $evidenceCommand })
            })
        }
    }
    $phase13Status = 'PLAN'
    $phase13Detail = if ($hooksAlreadyConfigured) { 'Hooks already configured; plan generated for verification' } else { 'Settings activation plan generated (requires approval)' }

    if ($Mode -eq 'Activate' -and -not $hooksAlreadyConfigured) {
        $phase13Status = 'APPROVAL_REQUIRED'
        $phase13Detail = 'Settings activation requires human approval in Activate mode'
    }
}
Add-Phase -Order 13 -Name 'Prepare settings activation plan' -Status $phase13Status -Blocking $false -Detail $phase13Detail

# ============================================================
# Phase 14: Prepare lock activation plan
# ============================================================
$lockActivationPlan = [ordered]@{
    protected_lock_targets = [string[]]$script:AkashicProtectedFiles
    mutable_dirs           = [string[]]$script:AkashicMutableDirs
    include_settings_lock  = [bool]$IncludeSettingsLock
    include_templates_lock = [bool]$IncludeTemplatesLock
    lock_tool              = 'tools/Lock-AkashicProtectedFiles.ps1'
    status_tool            = 'tools/AkashicLockStatus.ps1'
    requires_approval      = $true
    lock_strategy          = if ($lockStrategy) {
        [ordered]@{
            backend    = $lockStrategy.backend
            strength   = $lockStrategy.strength
            privilege  = $lockStrategy.privilege_mode
        }
    } else { $null }
    fixture_prerequisite   = $fixtureResult
}

$phase14Status = 'PLAN'
$phase14Detail = ''
if (-not $lockStrategy -or -not $lockStrategy.implemented) {
    $phase14Status = 'BLOCKED'
    $phase14Detail = 'Lock strategy not available'
} elseif ($fixtureResult -eq 'PASS') {
    $phase14Detail = "Lock plan ready (fixture PASS, backend: $($lockStrategy.backend))"
    if ($Mode -eq 'Activate') {
        $phase14Status = 'APPROVAL_REQUIRED'
        $phase14Detail += ' — requires human approval'
    }
} elseif ($RunFixtureCheck -and $fixtureResult -ne 'PASS') {
    $phase14Status = 'BLOCKED'
    $phase14Detail = "Lock plan blocked: fixture did not pass ($fixtureResult)"
} else {
    $phase14Detail = "Lock plan generated (fixture not run, backend: $($lockStrategy.backend))"
}
Add-Phase -Order 14 -Name 'Prepare lock activation plan' -Status $phase14Status -Blocking $false -Detail $phase14Detail

# ============================================================
# Phase 15: Prepare rollback plan
# ============================================================
$rollbackPlan = [ordered]@{
    steps = @(
        "Restore settings.json from backup: $ClaudeSettingsPath.pre-helios-backup"
        'Remove deny ACLs from locked files (Unlock-AkashicProtectedFiles)'
        'Verify no hooks active: run shell command, confirm no gate prompt'
        "Optionally remove target: $HeliosGateRoot"
    )
    risk = 'Low — restoring settings.json disables hooks immediately'
}
Add-Phase -Order 15 -Name 'Prepare rollback plan' -Status 'PASS' -Blocking $false -Detail 'Rollback plan generated'

# ============================================================
# Phase 16: Write install evidence
# ============================================================
$phase16Status = 'SKIP'
$phase16Detail = 'Evidence deferred to Prepare/Activate'
$installEvidence = $null
if ($Mode -ne 'PlanOnly') {
    $installEvidence = [ordered]@{
        schema_version       = 'akashic-install-evidence.v1'
        timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
        mode                 = $Mode
        platform             = $Platform
        akashic_root         = $AkashicRoot
        helios_gate_root     = $HeliosGateRoot
        lock_strategy        = if ($lockStrategy) {
            [ordered]@{
                backend   = $lockStrategy.backend
                strength  = $lockStrategy.strength
                privilege = $lockStrategy.privilege_mode
            }
        } else { $null }
        fixture_result       = $fixtureResult
        manifest_status      = $manifestStatus
        settings_activation  = if ($IncludeSettingsActivation -and $Mode -eq 'Activate') { 'activated' } elseif ($IncludeSettingsActivation) { 'plan_only' } else { 'skipped' }
        lock_activation      = if ($Mode -eq 'Activate' -and $fixtureResult -eq 'PASS') { 'activated' } elseif ($lockStrategy -and $lockStrategy.implemented) { 'plan_only' } else { 'skipped' }
        blockers             = [string[]]$blockers
    }

    if (-not (Test-Path $EvidenceOutputDir)) {
        New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null
    }
    $evidencePath = Join-Path $EvidenceOutputDir 'install-evidence.json'
    $evidenceJson = $installEvidence | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($evidencePath, $evidenceJson, $Utf8NoBom)
    $phase16Status = 'PASS'
    $phase16Detail = "Evidence written: $evidencePath"
}
Add-Phase -Order 16 -Name 'Write install evidence' -Status $phase16Status -Blocking $false -Detail $phase16Detail -Mode 'Prepare/Activate'

# ============================================================
# Assemble the install plan
# ============================================================
$plan = [ordered]@{
    schema_version          = 'akashic-helios-install-plan.v1'
    timestamp_utc           = (Get-Date).ToUniversalTime().ToString('o')
    mode                    = $Mode
    platform                = $Platform
    akashic_root            = $AkashicRoot
    helios_gate_root        = $HeliosGateRoot
    claude_settings_path    = $ClaudeSettingsPath
    lock_strategy           = if ($lockStrategy) {
        [ordered]@{
            backend            = $lockStrategy.backend
            implemented        = $lockStrategy.implemented
            strength           = $lockStrategy.strength
            requires_elevation = $lockStrategy.requires_elevation
            privilege_mode     = $lockStrategy.privilege_mode
            blockers           = $lockStrategy.blockers
            notes              = $lockStrategy.notes
        }
    } else { $null }
    fixture_result          = $fixtureResult
    manifest_status         = $manifestStatus
    phases                  = [object[]]$phases
    bridge_sync_plan        = $bridgeSyncPlan
    file_copy_plan          = $fileCopyPlan
    settings_activation_plan = $settingsActivationPlan
    lock_activation_plan    = $lockActivationPlan
    rollback_plan           = $rollbackPlan
    install_evidence        = $installEvidence
    blockers                = [string[]]$blockers
    overall_status          = if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }
}

$planPath = Join-Path $AkashicRoot 'install-plan.json'
$planJson = $plan | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($planPath, $planJson, $Utf8NoBom)

Write-Host "Install plan generated: $planPath (mode: $Mode, platform: $Platform, status: $($plan.overall_status))"
if ($blockers.Count -gt 0) {
    Write-Host "Blockers ($($blockers.Count)):"
    foreach ($b in $blockers) { Write-Host "  - $b" }
}

$plan | ConvertTo-Json -Depth 5
return $plan
