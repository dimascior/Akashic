# AkashicCombinedInstallPlan.ps1 — Generate a full install plan from both packages
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AdapterPackageRoot,

    [Parameter(Mandatory)]
    [string]$RuntimeBundleRoot,

    [Parameter(Mandatory)]
    [string]$TargetGateRoot,

    [string]$ClaudeSettingsPath = "$env:USERPROFILE\.claude\settings.json",

    [ValidateSet('PlanOnly', 'Prepare')]
    [string]$Mode = 'PlanOnly',

    [switch]$IncludeSettingsLock,

    [switch]$IncludeTemplatesLock
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $AdapterPackageRoot)) { throw "Adapter package not found: $AdapterPackageRoot" }
if (-not (Test-Path $RuntimeBundleRoot)) { throw "Runtime bundle not found: $RuntimeBundleRoot" }

$AdapterManifestPath = Join-Path $AdapterPackageRoot 'package-manifest.json'
$RuntimeManifestPath = Join-Path $RuntimeBundleRoot 'runtime-manifest.json'

$AdapterManifest = $null
if (Test-Path $AdapterManifestPath) {
    $AdapterManifest = Get-Content -LiteralPath $AdapterManifestPath -Raw | ConvertFrom-Json
}

$RuntimeManifest = $null
if (Test-Path $RuntimeManifestPath) {
    $RuntimeManifest = Get-Content -LiteralPath $RuntimeManifestPath -Raw | ConvertFrom-Json
}

$TargetExists = Test-Path $TargetGateRoot
$SettingsExists = Test-Path $ClaudeSettingsPath

$HooksAlreadyConfigured = $false
if ($SettingsExists) {
    try {
        $settings = Get-Content -LiteralPath $ClaudeSettingsPath -Raw | ConvertFrom-Json
        if ($settings.hooks -and $settings.hooks.PreToolUse) { $HooksAlreadyConfigured = $true }
    } catch {}
}

$RuntimeFileCopyPlan = @()
$RuntimeDirs = @('hooks', 'hooks\lib', 'policy', 'templates', 'schemas', 'tools', 'docs',
                 'maintenance', 'manifest', 'pending', 'inflight', 'evidence', 'blocked',
                 'evidence\integrity', 'evidence\integrity\sessions', 'evidence\stale', 'evidence\maintenance', 'tests')

$ProtectedFiles = @(
    'hooks\helios_pretooluse.ps1', 'hooks\gate_check.ps1',
    'hooks\evidence_capture.ps1', 'hooks\tier_classifier.ps1',
    'hooks\lib\HeliosIntegrityBridge.ps1',
    'policy\command-policy.json',
    'manifest\helios-envelope.json', 'manifest\helios-envelope.sha256'
)

$MutableDirs = @('pending', 'inflight', 'evidence', 'blocked')

$BridgeAndManifestFiles = @(
    'hooks\lib\HeliosIntegrityBridge.ps1',
    'manifest\helios-envelope.json',
    'manifest\helios-envelope.sha256'
)

foreach ($rel in $ProtectedFiles) {
    if ($BridgeAndManifestFiles -contains $rel) { continue }
    $src = Join-Path $RuntimeBundleRoot $rel
    if (Test-Path $src) {
        $RuntimeFileCopyPlan += @{
            source = $src
            dest   = Join-Path $TargetGateRoot $rel
            role   = 'protected_runtime'
        }
    }
}

$SupportPatterns = @(
    @{ Dir = 'schemas'; Filter = '*.json' }
    @{ Dir = 'tools'; Filter = '*.ps1' }
    @{ Dir = 'docs'; Filter = '*.md' }
    @{ Dir = 'tests'; Filter = '*.ps1' }
)
foreach ($sp in $SupportPatterns) {
    $srcDir = Join-Path $RuntimeBundleRoot $sp.Dir
    if (Test-Path $srcDir) {
        $files = @(Get-ChildItem -Path $srcDir -Filter $sp.Filter -File -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $RuntimeFileCopyPlan += @{
                source = $f.FullName
                dest   = Join-Path $TargetGateRoot "$($sp.Dir)\$($f.Name)"
                role   = 'support'
            }
        }
    }
}

$BridgeSyncPlan = @{
    source          = Join-Path $AdapterPackageRoot 'AkashicIntegrityBridge.ps1'
    dest            = Join-Path $TargetGateRoot 'hooks\lib\HeliosIntegrityBridge.ps1'
    verify          = 'SHA-256 byte identity check after copy'
    role            = 'bridge_vendor_copy'
    source_owner    = 'Akashic standalone repo'
}

$LockActivationPlan = [ordered]@{
    protected_lock_targets = $ProtectedFiles
    mutable_dirs           = $MutableDirs
    include_settings_lock  = [bool]$IncludeSettingsLock
    include_templates_lock = [bool]$IncludeTemplatesLock
    settings_path          = $ClaudeSettingsPath
    lock_tool              = 'tools/Lock-AkashicProtectedFiles.ps1'
    status_tool            = 'tools/AkashicLockStatus.ps1'
    requires_approval      = $true
    note                   = 'Lock activation is plan-first: files are not locked during package alignment unless explicitly approved.'
}

$RebaselinePlan = @{
    tool            = 'AkashicEnvelopeManifest.ps1'
    gate_root       = $TargetGateRoot
    rebaselined_by  = 'installer'
    note            = 'Combined install rebaseline'
    bom_safe        = $true
    verify_tool     = 'AkashicEnvelopeIntegrityValidation.ps1'
    expected_verdict = 'CLEAN'
}

$SettingsActivationPlan = @{
    target_file        = $ClaudeSettingsPath
    backup_path        = "$ClaudeSettingsPath.pre-helios-backup"
    requires_approval  = $true
    already_configured = $HooksAlreadyConfigured
    hooks_to_add       = [ordered]@{
        PreToolUse = @(@{
            matcher = 'Bash|PowerShell'
            hooks = @(@{
                type = 'command'
                command = "powershell.exe -ExecutionPolicy Bypass -File `"$TargetGateRoot\hooks\helios_pretooluse.ps1`""
            })
        })
        PostToolUse = @(@{
            matcher = 'Bash|PowerShell'
            hooks = @(@{
                type = 'command'
                command = "powershell.exe -ExecutionPolicy Bypass -File `"$TargetGateRoot\hooks\evidence_capture.ps1`""
            })
        })
        PostToolUseFailure = @(@{
            matcher = 'Bash|PowerShell'
            hooks = @(@{
                type = 'command'
                command = "powershell.exe -ExecutionPolicy Bypass -File `"$TargetGateRoot\hooks\evidence_capture.ps1`""
            })
        })
    }
}

$SmokeTestPlan = @(
    @{ name = 'no_gate_deny'; action = 'Run shell command without pending gate'; expected = 'DENY'; proves = 'Gate enforcement active' }
    @{ name = 'valid_gate_allow'; action = 'Create valid gate then run matching command'; expected = 'ALLOW + 4 evidence files'; proves = 'Full evidence chain' }
)

$RollbackPlan = @{
    steps = @(
        "Restore settings.json from: $ClaudeSettingsPath.pre-helios-backup"
        'Verify no hooks active: run shell command, confirm no gate prompt'
        "Remove target gate root: $TargetGateRoot"
    )
    risk = 'Low — restoring settings.json disables hooks immediately'
}

$Plan = [ordered]@{
    schema_version            = 'helios-combined-install-plan.v2'
    timestamp_utc             = (Get-Date).ToUniversalTime().ToString('o')
    mode                      = $Mode
    adapter_package           = @{
        root    = $AdapterPackageRoot
        version = if ($AdapterManifest) { $AdapterManifest.package_version } else { 'unknown' }
        branch  = if ($AdapterManifest) { $AdapterManifest.source_branch } else { 'unknown' }
        commit  = if ($AdapterManifest) { $AdapterManifest.source_commit } else { 'unknown' }
    }
    runtime_bundle            = @{
        root    = $RuntimeBundleRoot
        version = if ($RuntimeManifest) { $RuntimeManifest.package_version } else { 'unknown' }
        branch  = if ($RuntimeManifest) { $RuntimeManifest.source_branch } else { 'unknown' }
        commit  = if ($RuntimeManifest) { $RuntimeManifest.source_commit } else { 'unknown' }
    }
    target_gate_root          = $TargetGateRoot
    target_exists             = $TargetExists
    directories_to_create     = $RuntimeDirs
    runtime_file_copy_plan    = $RuntimeFileCopyPlan
    bridge_sync_plan          = $BridgeSyncPlan
    rebaseline_plan           = $RebaselinePlan
    settings_activation_plan  = $SettingsActivationPlan
    lock_activation_plan      = $LockActivationPlan
    smoke_tests               = $SmokeTestPlan
    rollback_plan             = $RollbackPlan
    steps                     = @(
        @{ order = 1;  action = 'Verify adapter package'; tool = 'AkashicPackageValidation.ps1'; blocking = $true }
        @{ order = 2;  action = 'Verify runtime bundle'; tool = 'AkashicRuntimeBundleValidation.ps1'; blocking = $true }
        @{ order = 3;  action = 'Create target directories'; blocking = $false }
        @{ order = 4;  action = 'Copy runtime protected files'; blocking = $true }
        @{ order = 5;  action = 'Copy runtime support files'; blocking = $false }
        @{ order = 6;  action = 'Sync adapter bridge to hooks/lib'; blocking = $true }
        @{ order = 7;  action = 'Verify bridge byte identity'; blocking = $true }
        @{ order = 8;  action = 'Generate or verify local manifest (BOM-free)'; tool = 'AkashicEnvelopeManifest.ps1'; blocking = $true }
        @{ order = 9;  action = 'Verify envelope integrity'; tool = 'AkashicEnvelopeIntegrityValidation.ps1'; blocking = $true }
        @{ order = 10; action = 'Verify settings hook routing'; tool = 'AkashicSettingsIntegrity.ps1'; blocking = $true }
        @{ order = 11; action = 'Backup settings.json'; blocking = $false }
        @{ order = 12; action = 'Review settings activation plan'; note = 'REQUIRES HUMAN APPROVAL'; blocking = $true }
        @{ order = 13; action = 'Activate hooks'; note = 'Human applies changes'; blocking = $true }
        @{ order = 14; action = 'Apply protected-file locks'; tool = 'Lock-AkashicProtectedFiles.ps1'; note = 'REQUIRES HUMAN APPROVAL'; blocking = $true }
        @{ order = 15; action = 'Optionally lock settings.json'; tool = 'Lock-AkashicProtectedFiles.ps1 -IncludeSettingsJson'; note = 'Optional, requires approval'; blocking = $false }
        @{ order = 16; action = 'Optionally lock templates'; tool = 'Lock-AkashicProtectedFiles.ps1 -IncludeTemplates'; note = 'Conditional on template trust'; blocking = $false }
        @{ order = 17; action = 'Verify lock status'; tool = 'AkashicLockStatus.ps1'; blocking = $true }
        @{ order = 18; action = 'Verify mutable dirs writable'; tool = 'AkashicLockStatus.ps1 -IncludeMutableLifecycle'; blocking = $true }
        @{ order = 19; action = 'Run no-gate deny smoke test'; blocking = $true }
        @{ order = 20; action = 'Run valid-gate allow smoke test'; blocking = $true }
        @{ order = 21; action = 'Write install evidence'; blocking = $false }
    )
}

if ($Mode -eq 'Prepare') {
    foreach ($dir in $RuntimeDirs) {
        $path = Join-Path $TargetGateRoot $dir
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    $GitkeepDirs = @('pending', 'inflight', 'evidence', 'blocked', 'templates')
    foreach ($gkDir in $GitkeepDirs) {
        $gkPath = Join-Path $TargetGateRoot "$gkDir\.gitkeep"
        if (-not (Test-Path $gkPath)) {
            [System.IO.File]::WriteAllText($gkPath, '', $Utf8NoBom)
        }
    }

    foreach ($copy in $RuntimeFileCopyPlan) {
        $destDir = Split-Path $copy.dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (Test-Path $copy.source) {
            Copy-Item -LiteralPath $copy.source -Destination $copy.dest -Force
        }
    }

    if (Test-Path $BridgeSyncPlan.source) {
        $bridgeDestDir = Split-Path $BridgeSyncPlan.dest -Parent
        if (-not (Test-Path $bridgeDestDir)) {
            New-Item -ItemType Directory -Path $bridgeDestDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $BridgeSyncPlan.source -Destination $BridgeSyncPlan.dest -Force
    }

    $Plan['prepare_completed'] = $true
    $Plan['manifest_status'] = 'pending_rebaseline'
}

$PlanPath = Join-Path $AdapterPackageRoot 'combined-install-plan.json'
$PlanJson = $Plan | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($PlanPath, $PlanJson, $Utf8NoBom)

Write-Host "Combined install plan generated: $PlanPath (mode: $Mode)"
$Plan | ConvertTo-Json -Depth 5
return $Plan
