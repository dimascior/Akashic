# AkashicHeliosInstallPlan.ps1 — Unified Akashic + Helios install planner
# Supersedes AkashicInstallPlan.ps1 and AkashicCombinedInstallPlan.ps1
# with platform detection, fixture support, RuntimeBundleRoot, and
# corrected phase ordering (manifest after all files in final position).
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$RuntimeBundleRoot,

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
$isPlanOnly = ($Mode -eq 'PlanOnly')
$isActivate = ($Mode -eq 'Activate')

function Add-Phase {
    param(
        [int]$Order,
        [string]$Name,
        [string]$Status,
        [bool]$Blocking = $true,
        [string]$Detail = ''
    )
    $phases.Add([ordered]@{
        phase    = $Order
        name     = $Name
        status   = $Status
        blocking = $Blocking
        detail   = $Detail
    })
}

# ============================================================
# Phase 1: Verify Akashic package/root + tool availability
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
            $toolPath = Join-Path $AkashicRoot ($tool.Replace('/', $sep))
            if (-not (Test-Path $toolPath)) { $missingTools += $tool }
        }
        if ($missingTools.Count -gt 0) {
            $phase1Status = 'FAIL'
            $phase1Detail = "Missing tools: $($missingTools -join ', ')"
            $blockers.Add("Phase 1: $phase1Detail")
        } else {
            $phase1Detail = "Akashic root verified ($($requiredTools.Count) tools present): $AkashicRoot"
        }
    }
}
Add-Phase -Order 1 -Name 'Verify Akashic package/root' -Status $phase1Status -Detail $phase1Detail

# ============================================================
# Phase 2: Verify RuntimeBundleRoot
# ============================================================
$hasRuntimeBundle = $false
$runtimeProtectedCopyPlan = @()
$runtimeSupportCopyPlan = @()

$phase2Status = 'SKIP'
$phase2Detail = 'RuntimeBundleRoot not provided'
if ($RuntimeBundleRoot) {
    if (-not (Test-Path $RuntimeBundleRoot)) {
        $phase2Status = 'FAIL'
        $phase2Detail = "RuntimeBundleRoot not found: $RuntimeBundleRoot"
        $blockers.Add("Phase 2: $phase2Detail")
    } else {
        $hasRuntimeBundle = $true
        $runtimeProtectedSources = @(
            'hooks/helios_pretooluse.ps1',
            'hooks/gate_check.ps1',
            'hooks/evidence_capture.ps1',
            'hooks/tier_classifier.ps1',
            'policy/command-policy.json'
        )
        $missingRuntime = @()
        foreach ($rel in $runtimeProtectedSources) {
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $src = Join-Path $RuntimeBundleRoot ($rel.Replace('/', $sep))
            if (Test-Path $src) {
                $runtimeProtectedCopyPlan += [ordered]@{
                    relative = $rel
                    source   = $src
                    dest     = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
                    role     = 'protected_runtime'
                }
            } else {
                $missingRuntime += $rel
            }
        }

        $supportPatterns = @(
            @{ Dir = 'schemas'; Filter = '*.json' }
            @{ Dir = 'tools'; Filter = '*.ps1' }
            @{ Dir = 'docs'; Filter = '*.md' }
            @{ Dir = 'tests'; Filter = '*.ps1' }
        )
        foreach ($sp in $supportPatterns) {
            $srcDir = Join-Path $RuntimeBundleRoot $sp.Dir
            if (Test-Path $srcDir) {
                $files = @(Get-ChildItem -Path $srcDir -Filter $sp.Filter -File -ErrorAction SilentlyContinue)
                foreach ($f in $files) {
                    $runtimeSupportCopyPlan += [ordered]@{
                        relative = "$($sp.Dir)/$($f.Name)"
                        source   = $f.FullName
                        dest     = Join-Path $HeliosGateRoot "$($sp.Dir)\$($f.Name)"
                        role     = 'support'
                    }
                }
            }
        }

        if ($missingRuntime.Count -gt 0) {
            $phase2Status = 'WARN'
            $phase2Detail = "RuntimeBundleRoot verified but missing: $($missingRuntime -join ', ')"
        } else {
            $phase2Status = 'PASS'
            $phase2Detail = "RuntimeBundleRoot verified: $RuntimeBundleRoot ($($runtimeProtectedCopyPlan.Count) protected, $($runtimeSupportCopyPlan.Count) support files)"
        }
    }
}
Add-Phase -Order 2 -Name 'Verify RuntimeBundleRoot' -Status $phase2Status -Detail $phase2Detail

# ============================================================
# Phase 3: Create runtime directories
# ============================================================
$runtimeDirs = @(
    'hooks', 'hooks/lib', 'policy', 'templates', 'schemas',
    'manifest', 'pending', 'inflight', 'evidence', 'blocked',
    'maintenance', 'evidence/integrity', 'evidence/integrity/sessions',
    'evidence/stale', 'evidence/maintenance'
)
$targetExists = Test-Path $HeliosGateRoot
$missingDirs = @()
if ($targetExists) {
    foreach ($d in $runtimeDirs) {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $dirPath = Join-Path $HeliosGateRoot ($d.Replace('/', $sep))
        if (-not (Test-Path $dirPath)) { $missingDirs += $d }
    }
}

$phase3Status = 'PASS'
$phase3Detail = ''
if (-not $targetExists) {
    if ($isPlanOnly) {
        $phase3Status = 'PLAN'
        $phase3Detail = "Target does not exist (will be created in Prepare/Activate): $HeliosGateRoot"
    } else {
        New-Item -ItemType Directory -Path $HeliosGateRoot -Force | Out-Null
        foreach ($d in $runtimeDirs) {
            $sep = [System.IO.Path]::DirectorySeparatorChar
            $dirPath = Join-Path $HeliosGateRoot ($d.Replace('/', $sep))
            if (-not (Test-Path $dirPath)) {
                New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
            }
        }
        $phase3Detail = "Target + $($runtimeDirs.Count) directories created: $HeliosGateRoot"
    }
} elseif ($missingDirs.Count -eq 0) {
    $phase3Detail = "Target exists, $($runtimeDirs.Count) directories verified"
} elseif ($isPlanOnly) {
    $phase3Status = 'PLAN'
    $phase3Detail = "$($missingDirs.Count) directories to create: $($missingDirs -join ', ')"
} else {
    foreach ($d in $missingDirs) {
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $dirPath = Join-Path $HeliosGateRoot ($d.Replace('/', $sep))
        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
    }
    $phase3Detail = "$($missingDirs.Count) directories created"
}
Add-Phase -Order 3 -Name 'Create runtime directories' -Status $phase3Status -Detail $phase3Detail

# ============================================================
# Phase 4: Copy Helios runtime protected files from RuntimeBundleRoot
# ============================================================
$phase4Status = 'SKIP'
$phase4Detail = 'RuntimeBundleRoot not provided'
if ($hasRuntimeBundle) {
    if ($isPlanOnly) {
        $phase4Status = 'PLAN'
        $phase4Detail = "$($runtimeProtectedCopyPlan.Count) protected files to copy from RuntimeBundleRoot"
    } else {
        $copied = 0
        foreach ($copy in $runtimeProtectedCopyPlan) {
            $destDir = Split-Path $copy.dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $copy.source -Destination $copy.dest -Force
            $copied++
        }
        $phase4Status = 'PASS'
        $phase4Detail = "$copied protected runtime files copied"
    }
}
Add-Phase -Order 4 -Name 'Copy runtime protected files' -Status $phase4Status -Detail $phase4Detail

# ============================================================
# Phase 5: Copy runtime support files from RuntimeBundleRoot
# ============================================================
$phase5Status = 'SKIP'
$phase5Detail = 'RuntimeBundleRoot not provided or no support files'
if ($hasRuntimeBundle -and $runtimeSupportCopyPlan.Count -gt 0) {
    if ($isPlanOnly) {
        $phase5Status = 'PLAN'
        $phase5Detail = "$($runtimeSupportCopyPlan.Count) support files to copy from RuntimeBundleRoot"
    } else {
        $copied = 0
        foreach ($copy in $runtimeSupportCopyPlan) {
            $destDir = Split-Path $copy.dest -Parent
            if (-not (Test-Path $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $copy.source -Destination $copy.dest -Force
            $copied++
        }
        $phase5Status = 'PASS'
        $phase5Detail = "$copied support files copied"
    }
} elseif ($hasRuntimeBundle) {
    $phase5Detail = 'No support files found in RuntimeBundleRoot'
}
Add-Phase -Order 5 -Name 'Copy runtime support files' -Status $phase5Status -Blocking $false -Detail $phase5Detail

# ============================================================
# Phase 6: Sync Akashic bridge
# ============================================================
$bridgeSource = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
$bridgeDest = Join-Path $HeliosGateRoot 'hooks\lib\HeliosIntegrityBridge.ps1'
$bridgeSyncPlan = [ordered]@{
    source        = $bridgeSource
    dest          = $bridgeDest
    source_exists = (Test-Path $bridgeSource)
    role          = 'bridge_vendor_copy'
    verify        = 'SHA-256 byte identity check after copy'
}

$phase6Status = 'PLAN'
$phase6Detail = ''
if (-not $bridgeSyncPlan.source_exists) {
    $phase6Status = 'FAIL'
    $phase6Detail = "Bridge source missing: $bridgeSource"
    $blockers.Add("Phase 6: $phase6Detail")
} elseif ($isPlanOnly) {
    $phase6Detail = "Bridge sync planned: $bridgeSource -> $bridgeDest"
} else {
    $syncScript = Join-Path $AkashicRoot 'tools\Sync-AkashicBridge.ps1'
    if (Test-Path $syncScript) {
        try {
            & $syncScript -AdapterRoot $AkashicRoot -HeliosGateRoot $HeliosGateRoot
            $phase6Status = 'PASS'
            $phase6Detail = "Bridge synced: $bridgeDest"
        } catch {
            $phase6Status = 'FAIL'
            $phase6Detail = "Bridge sync failed: $_"
            $blockers.Add("Phase 6: $phase6Detail")
        }
    } else {
        $phase6Status = 'FAIL'
        $phase6Detail = "Sync script not found: $syncScript"
        $blockers.Add("Phase 6: $phase6Detail")
    }
}
Add-Phase -Order 6 -Name 'Sync Akashic bridge' -Status $phase6Status -Detail $phase6Detail

# ============================================================
# Phase 7: Verify bridge byte identity
# ============================================================
$phase7Status = 'SKIP'
$phase7Detail = 'Bridge byte identity verified after sync in Prepare/Activate'
if (-not $isPlanOnly -and $phase6Status -eq 'PASS') {
    if ((Test-Path $bridgeSource) -and (Test-Path $bridgeDest)) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $srcHash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($bridgeSource)) | ForEach-Object { $_.ToString('x2') }) -join ''
        $dstHash = ($sha.ComputeHash([System.IO.File]::ReadAllBytes($bridgeDest)) | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($srcHash -eq $dstHash) {
            $phase7Status = 'PASS'
            $phase7Detail = "Byte identical: $srcHash"
        } else {
            $phase7Status = 'FAIL'
            $phase7Detail = "Hash mismatch: source=$srcHash dest=$dstHash"
            $blockers.Add("Phase 7: $phase7Detail")
        }
    } else {
        $phase7Status = 'SKIP'
        $phase7Detail = 'Bridge files not both present'
    }
} elseif ($isPlanOnly) {
    $phase7Detail = 'Byte identity check deferred to Prepare/Activate'
}
Add-Phase -Order 7 -Name 'Verify bridge byte identity' -Status $phase7Status -Detail $phase7Detail

# ============================================================
# Phase 8: Generate manifest (after all files in final position)
# ============================================================
$manifestStatus = 'NOT_GENERATED'
$phase8Status = 'SKIP'
$phase8Detail = 'Manifest generation deferred to Prepare/Activate'
if (-not $isPlanOnly) {
    $manifestScript = Join-Path $AkashicRoot 'tools\AkashicEnvelopeManifest.ps1'
    if (Test-Path $manifestScript) {
        try {
            & $manifestScript -HeliosGateRoot $HeliosGateRoot -RebaselinedBy 'installer' -Note 'Unified install plan'
            $manifestStatus = 'GENERATED'
            $phase8Status = 'PASS'
            $phase8Detail = 'Manifest generated from files in final position'
        } catch {
            $manifestStatus = 'FAIL'
            $phase8Status = 'FAIL'
            $phase8Detail = "Manifest generation failed: $_"
            $blockers.Add("Phase 8: $phase8Detail")
        }
    } else {
        $phase8Status = 'FAIL'
        $phase8Detail = "Manifest script not found: $manifestScript"
        $blockers.Add("Phase 8: $phase8Detail")
    }
}
Add-Phase -Order 8 -Name 'Generate manifest' -Status $phase8Status -Detail $phase8Detail

# ============================================================
# Phase 9: Verify envelope integrity
# ============================================================
$phase9Status = 'SKIP'
$phase9Detail = 'Envelope verification deferred to Prepare/Activate'
if (-not $isPlanOnly -and $manifestStatus -eq 'GENERATED') {
    $verifyScript = Join-Path $AkashicRoot 'tools\AkashicEnvelopeIntegrityValidation.ps1'
    if (Test-Path $verifyScript) {
        try {
            $verifyResult = & $verifyScript -HeliosGateRoot $HeliosGateRoot
            if ($verifyResult -and $verifyResult.verdict -eq 'CLEAN') {
                $manifestStatus = 'CLEAN'
                $phase9Status = 'PASS'
                $phase9Detail = 'Envelope integrity: CLEAN'
            } else {
                $manifestStatus = 'DRIFT'
                $phase9Status = 'FAIL'
                $verdict = if ($verifyResult) { $verifyResult.verdict } else { 'unknown' }
                $phase9Detail = "Envelope integrity: $verdict"
                $blockers.Add("Phase 9: $phase9Detail")
            }
        } catch {
            $phase9Status = 'FAIL'
            $phase9Detail = "Envelope verification failed: $_"
            $blockers.Add("Phase 9: $phase9Detail")
        }
    } else {
        $phase9Status = 'WARN'
        $phase9Detail = 'Verification script not found'
    }
}
Add-Phase -Order 9 -Name 'Verify envelope integrity' -Status $phase9Status -Detail $phase9Detail

# ============================================================
# Phase 10: Detect lock strategy + run OS lock fixture
# ============================================================
$strategyScript = Join-Path $AkashicRoot 'tools\Get-AkashicLockStrategy.ps1'
$strategyArgs = @{}
if ($RequireStrongLock) { $strategyArgs['RequireStrongLock'] = $true }
if ($AllowWeakFallback) { $strategyArgs['AllowWeakFallback'] = $true }

$lockStrategy = $null
$fixtureResult = 'NOT_RUN'
$phase10Status = 'FAIL'
$phase10Detail = ''
if (Test-Path $strategyScript) {
    try {
        $lockStrategy = & $strategyScript @strategyArgs
        if ($lockStrategy.implemented) {
            $phase10Status = 'PASS'
            $phase10Detail = "Backend: $($lockStrategy.backend), Strength: $($lockStrategy.strength), Privilege: $($lockStrategy.privilege_mode)"
        } else {
            $phase10Detail = "Lock backend not available: $($lockStrategy.blockers -join ', ')"
            $blockers.Add("Phase 10: $phase10Detail")
        }
    } catch {
        $phase10Detail = "Lock strategy detection failed: $_"
        $blockers.Add("Phase 10: $phase10Detail")
    }
} else {
    $phase10Detail = "Strategy script not found: $strategyScript"
    $blockers.Add("Phase 10: $phase10Detail")
}

if ($RunFixtureCheck -and -not $isPlanOnly -and $lockStrategy -and $lockStrategy.implemented) {
    $fixtureScript = Join-Path $AkashicRoot 'tools\Test-AkashicOsLockFixture.ps1'
    $fixtureArgs = @{}
    if ($RequireStrongLock) { $fixtureArgs['RequireStrongLock'] = $true }
    if ($AllowWeakFallback) { $fixtureArgs['AllowWeakFallback'] = $true }
    if (Test-Path $fixtureScript) {
        try {
            $fixtureOutput = & $fixtureScript @fixtureArgs
            if ($fixtureOutput -and $fixtureOutput.overall_result) {
                $fixtureResult = $fixtureOutput.overall_result
                if ($fixtureResult -ne 'PASS') {
                    $phase10Status = 'FAIL'
                    $phase10Detail += " | Fixture: $fixtureResult"
                    $blockers.Add("Phase 10: Fixture $fixtureResult")
                } else {
                    $phase10Detail += " | Fixture: PASS"
                }
            }
        } catch {
            $fixtureResult = 'FAIL'
            $phase10Status = 'FAIL'
            $phase10Detail += " | Fixture error: $_"
            $blockers.Add("Phase 10: Fixture failed: $_")
        }
    }
} elseif ($RunFixtureCheck -and $isPlanOnly) {
    $phase10Detail += ' | Fixture deferred to Prepare/Activate'
} elseif ($RunFixtureCheck -and $lockStrategy -and -not $lockStrategy.implemented) {
    $fixtureResult = 'BLOCKED'
    $phase10Detail += ' | Fixture blocked: lock strategy not available'
}
Add-Phase -Order 10 -Name 'Detect lock strategy + run fixture' -Status $phase10Status -Detail $phase10Detail

# ============================================================
# Phase 11: Prepare settings activation plan
# ============================================================
$settingsExists = Test-Path $ClaudeSettingsPath
$hooksAlreadyConfigured = $false
if ($settingsExists) {
    try {
        $settings = Get-Content -LiteralPath $ClaudeSettingsPath -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.PreToolUse) { $hooksAlreadyConfigured = $true }
    } catch {}
}

$settingsActivationPlan = $null
$settingsActivationStatus = 'skipped'
$phase11Status = 'SKIP'
$phase11Detail = 'Settings activation not requested'
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

    if ($hooksAlreadyConfigured) {
        $phase11Status = 'PASS'
        $phase11Detail = 'Settings hooks already configured'
        $settingsActivationStatus = 'already_configured'
    } elseif ($isActivate) {
        $phase11Status = 'APPROVAL_REQUIRED'
        $phase11Detail = 'Settings activation requires human approval'
        $settingsActivationStatus = 'APPROVAL_REQUIRED'
    } else {
        $phase11Status = 'PLAN'
        $phase11Detail = 'Settings activation plan generated'
        $settingsActivationStatus = 'plan_only'
    }
}
Add-Phase -Order 11 -Name 'Prepare settings activation plan' -Status $phase11Status -Blocking $false -Detail $phase11Detail

# ============================================================
# Phase 12: Prepare lock activation plan
# ============================================================
$lockActivationStatus = 'skipped'
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

$phase12Status = 'PLAN'
$phase12Detail = ''
if (-not $lockStrategy -or -not $lockStrategy.implemented) {
    $phase12Status = 'BLOCKED'
    $phase12Detail = 'Lock strategy not available'
    $lockActivationStatus = 'blocked'
} elseif ($isActivate -and $fixtureResult -eq 'PASS') {
    $phase12Status = 'APPROVAL_REQUIRED'
    $phase12Detail = "Lock activation requires human approval (fixture PASS, backend: $($lockStrategy.backend))"
    $lockActivationStatus = 'APPROVAL_REQUIRED'
} elseif ($isActivate -and $fixtureResult -ne 'PASS') {
    $phase12Status = 'BLOCKED'
    $phase12Detail = "Lock activation blocked: fixture did not pass ($fixtureResult)"
    $lockActivationStatus = 'blocked'
} elseif ($fixtureResult -eq 'PASS') {
    $phase12Detail = "Lock plan ready (fixture PASS, backend: $($lockStrategy.backend))"
    $lockActivationStatus = 'plan_only'
} else {
    $phase12Detail = "Lock plan generated (fixture: $fixtureResult, backend: $($lockStrategy.backend))"
    $lockActivationStatus = 'plan_only'
}
Add-Phase -Order 12 -Name 'Prepare lock activation plan' -Status $phase12Status -Blocking $false -Detail $phase12Detail

# ============================================================
# Phase 13: Prepare rollback plan
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
Add-Phase -Order 13 -Name 'Prepare rollback plan' -Status 'PASS' -Blocking $false -Detail 'Rollback plan generated'

# ============================================================
# Phase 14: Write install evidence
# ============================================================
$phase14Status = 'SKIP'
$phase14Detail = 'Evidence deferred to Prepare/Activate'
$installEvidence = $null
if (-not $isPlanOnly) {
    $installEvidence = [ordered]@{
        schema_version       = 'akashic-install-evidence.v1'
        timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
        mode                 = $Mode
        platform             = $Platform
        akashic_root         = $AkashicRoot
        runtime_bundle_root  = $RuntimeBundleRoot
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
        settings_activation  = $settingsActivationStatus
        lock_activation      = $lockActivationStatus
        blockers             = [string[]]$blockers
    }

    if (-not (Test-Path $EvidenceOutputDir)) {
        New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null
    }
    $evidencePath = Join-Path $EvidenceOutputDir 'install-evidence.json'
    $evidenceJson = $installEvidence | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($evidencePath, $evidenceJson, $Utf8NoBom)
    $phase14Status = 'PASS'
    $phase14Detail = "Evidence written: $evidencePath"
}
Add-Phase -Order 14 -Name 'Write install evidence' -Status $phase14Status -Blocking $false -Detail $phase14Detail

# ============================================================
# Assemble the install plan
# ============================================================
$plan = [ordered]@{
    schema_version            = 'akashic-helios-install-plan.v2'
    timestamp_utc             = (Get-Date).ToUniversalTime().ToString('o')
    mode                      = $Mode
    platform                  = $Platform
    akashic_root              = $AkashicRoot
    runtime_bundle_root       = $RuntimeBundleRoot
    helios_gate_root          = $HeliosGateRoot
    claude_settings_path      = $ClaudeSettingsPath
    lock_strategy             = if ($lockStrategy) {
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
    fixture_result            = $fixtureResult
    manifest_status           = $manifestStatus
    phases                    = [object[]]$phases
    bridge_sync_plan          = $bridgeSyncPlan
    runtime_protected_copy_plan = $runtimeProtectedCopyPlan
    runtime_support_copy_plan   = $runtimeSupportCopyPlan
    settings_activation_plan  = $settingsActivationPlan
    lock_activation_plan      = $lockActivationPlan
    rollback_plan             = $rollbackPlan
    install_evidence          = $installEvidence
    blockers                  = [string[]]$blockers
    overall_status            = if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }
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
