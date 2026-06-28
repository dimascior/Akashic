# New-HeliosInstallPlan.ps1 — Generate an install plan for the TCE Helios adapter
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageRoot,

    [Parameter(Mandatory)]
    [string]$HeliosTargetRoot,

    [string]$ClaudeSettingsPath = "$env:USERPROFILE\.claude\settings.json",

    [ValidateSet('PlanOnly', 'Prepare')]
    [string]$Mode = 'PlanOnly'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $PackageRoot)) {
    throw "Package root not found: $PackageRoot"
}

$ManifestPath = Join-Path $PackageRoot 'package-manifest.json'
if (-not (Test-Path $ManifestPath)) {
    throw "Package manifest not found: $ManifestPath. Run Test-HeliosAdapterPackage first."
}

$PackageManifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

$TargetExists = Test-Path $HeliosTargetRoot
$SettingsExists = Test-Path $ClaudeSettingsPath

$ExistingSettings = $null
$HooksAlreadyConfigured = $false
if ($SettingsExists) {
    try {
        $ExistingSettings = Get-Content -LiteralPath $ClaudeSettingsPath -Raw | ConvertFrom-Json
        if ($ExistingSettings.hooks -and $ExistingSettings.hooks.PreToolUse) {
            $HooksAlreadyConfigured = $true
        }
    } catch {
        $ExistingSettings = $null
    }
}

$FilesToCopy = @(
    @{
        source = Join-Path $PackageRoot 'HeliosIntegrityBridge.ps1'
        dest   = Join-Path $HeliosTargetRoot 'hooks\lib\HeliosIntegrityBridge.ps1'
        role   = 'bridge_vendor_copy'
    }
)

$DirectoriesToCreate = @(
    'hooks', 'hooks\lib', 'policy', 'templates', 'schemas',
    'manifest', 'pending', 'inflight', 'evidence', 'blocked',
    'maintenance', 'evidence\integrity', 'evidence\integrity\sessions',
    'evidence\stale', 'evidence\maintenance', 'docs', 'tools', 'tests'
)

$PreToolUseHook = @{
    matcher = 'Bash|PowerShell'
    hooks = @(
        @{
            type    = 'command'
            command = "powershell.exe -ExecutionPolicy Bypass -File `"$HeliosTargetRoot\hooks\helios_pretooluse.ps1`""
        }
    )
}

$PostToolUseHook = @{
    matcher = 'Bash|PowerShell'
    hooks = @(
        @{
            type    = 'command'
            command = "powershell.exe -ExecutionPolicy Bypass -File `"$HeliosTargetRoot\hooks\evidence_capture.ps1`""
        }
    )
}

$SettingsActivation = @{
    action             = 'merge_hooks_into_settings'
    target_file        = $ClaudeSettingsPath
    backup_recommended = $true
    backup_path        = "$ClaudeSettingsPath.pre-helios-backup"
    requires_approval  = $true
    hooks_to_add       = [ordered]@{
        PreToolUse         = @($PreToolUseHook)
        PostToolUse        = @($PostToolUseHook)
        PostToolUseFailure = @($PostToolUseHook)
    }
    already_configured = $HooksAlreadyConfigured
}

$RebaselinePlan = @{
    tool       = 'tools\New-HeliosEnvelopeManifest.ps1'
    parameters = @{
        HeliosGateRoot = $HeliosTargetRoot
        RebaselinedBy  = 'installer'
        Note           = 'Installation rebaseline'
    }
    verify_tool = 'tools\Test-HeliosEnvelopeIntegrity.ps1'
    verify_parameters = @{
        HeliosGateRoot = $HeliosTargetRoot
    }
    expected_verdict = 'CLEAN'
}

$SmokeTestPlan = @(
    @{
        name     = 'no_gate_deny'
        action   = 'Run any shell command without a matching gate in pending/'
        expected = 'Helios denies with "no valid gate found"'
        proves   = 'Gate enforcement is active'
    }
    @{
        name     = 'valid_gate_allow'
        action   = 'Create a valid gate and run the matching command'
        expected = 'Helios allows. Evidence chain: before, decision, after, compare.'
        proves   = 'Full evidence chain operational'
    }
)

$RollbackPlan = @{
    steps = @(
        'Restore settings.json from backup: Copy-Item "<backup>" "<settings>"'
        'Verify no hooks active: run a shell command, confirm no gate prompt'
        'Optionally remove .command-gate/ directory'
    )
    settings_backup = "$ClaudeSettingsPath.pre-helios-backup"
    risk = 'Low — restoring settings.json disables hooks immediately'
}

$InstallPlan = [ordered]@{
    schema_version        = 'helios-install-plan.v1'
    timestamp_utc         = (Get-Date).ToUniversalTime().ToString('o')
    mode                  = $Mode
    package_root          = $PackageRoot
    package_version       = $PackageManifest.package_version
    source_branch         = $PackageManifest.source_branch
    source_commit         = $PackageManifest.source_commit
    helios_target         = $HeliosTargetRoot
    target_exists         = $TargetExists
    settings_path         = $ClaudeSettingsPath
    settings_exists       = $SettingsExists
    hooks_already_active  = $HooksAlreadyConfigured
    directories_to_create = $DirectoriesToCreate
    files_to_copy         = $FilesToCopy
    settings_activation   = $SettingsActivation
    rebaseline_plan       = $RebaselinePlan
    smoke_tests           = $SmokeTestPlan
    rollback_plan         = $RollbackPlan
    steps                 = @(
        @{ order = 1;  action = 'Verify package checksum'; tool = 'Test-HeliosAdapterPackage.ps1'; blocking = $true }
        @{ order = 2;  action = 'Create target directories'; auto = $true; blocking = $false }
        @{ order = 3;  action = 'Copy TCE bridge to vendor location'; auto = $true; blocking = $true }
        @{ order = 4;  action = 'Verify bridge byte identity'; auto = $true; blocking = $true }
        @{ order = 5;  action = 'Copy Helios runtime files (hooks, policy, schemas)'; auto = $false; note = 'From Helios runtime bundle'; blocking = $true }
        @{ order = 6;  action = 'Generate local manifest'; tool = 'New-HeliosEnvelopeManifest.ps1'; blocking = $true }
        @{ order = 7;  action = 'Verify envelope integrity'; tool = 'Test-HeliosEnvelopeIntegrity.ps1'; blocking = $true }
        @{ order = 8;  action = 'Backup settings.json'; auto = $true; blocking = $false }
        @{ order = 9;  action = 'Review settings activation plan'; auto = $false; note = 'REQUIRES HUMAN APPROVAL'; blocking = $true }
        @{ order = 10; action = 'Activate hooks in settings.json'; auto = $false; note = 'Human applies changes'; blocking = $true }
        @{ order = 11; action = 'Run no-gate deny smoke test'; auto = $false; blocking = $true }
        @{ order = 12; action = 'Run valid-gate allow smoke test'; auto = $false; blocking = $true }
        @{ order = 13; action = 'Write install evidence'; auto = $true; blocking = $false }
    )
}

if ($Mode -eq 'Prepare') {
    foreach ($dir in $DirectoriesToCreate) {
        $path = Join-Path $HeliosTargetRoot $dir
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    foreach ($copy in $FilesToCopy) {
        $destDir = Split-Path $copy.dest -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        if (Test-Path $copy.source) {
            Copy-Item -LiteralPath $copy.source -Destination $copy.dest -Force
        }
    }

    $InstallPlan['prepare_completed'] = $true
}

$PlanPath = Join-Path $PackageRoot 'install-plan.json'
$PlanJson = $InstallPlan | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($PlanPath, $PlanJson, $Utf8NoBom)

Write-Host "Install plan generated: $PlanPath (mode: $Mode)"
$InstallPlan | ConvertTo-Json -Depth 5
return $InstallPlan
