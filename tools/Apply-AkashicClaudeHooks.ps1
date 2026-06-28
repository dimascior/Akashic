# Apply-AkashicClaudeHooks.ps1 — Activation helper for a Helios runtime
# Akashic prepares and activates; Helios is the runtime that enforces gates.
# This tool merges Helios hook entries into Claude settings so that Claude
# calls Helios hooks (helios_pretooluse.ps1, evidence_capture.ps1) for every
# Bash/PowerShell command.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$ClaudeSettingsPath,

    [ValidateSet('Auto', 'Windows', 'Linux', 'macOS')]
    [string]$Platform = 'Auto',

    [switch]$NoBackup,

    [switch]$WhatIf,

    [int]$HookTimeout = 15,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($Platform -eq 'Auto') {
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { $Platform = 'Windows' }
    elseif ($IsMacOS) { $Platform = 'macOS' }
    elseif ($IsLinux) { $Platform = 'Linux' }
    else { $Platform = 'Windows' }
}

if (-not $ClaudeSettingsPath) {
    $ClaudeSettingsPath = switch ($Platform) {
        'Windows' { Join-Path $env:USERPROFILE '.claude\settings.json' }
        default   { Join-Path $env:HOME '.claude/settings.json' }
    }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
function Get-FileHash256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

# --- Build hook commands ---
$preToolCommand = switch ($Platform) {
    'Windows' { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$HeliosGateRoot\hooks\helios_pretooluse.ps1`"" }
    default   { "pwsh -NoProfile -File '$HeliosGateRoot/hooks/helios_pretooluse.ps1'" }
}
$evidenceCommand = switch ($Platform) {
    'Windows' { "powershell -NoProfile -ExecutionPolicy Bypass -File `"$HeliosGateRoot\hooks\evidence_capture.ps1`"" }
    default   { "pwsh -NoProfile -File '$HeliosGateRoot/hooks/evidence_capture.ps1'" }
}

$heliosHookEntry = @{
    matcher = 'Bash|PowerShell'
    hooks = @(@{ type = 'command'; command = ''; timeout = $HookTimeout })
}

# --- Verify target hooks exist ---
$preToolPath = Join-Path $HeliosGateRoot (& { if ($Platform -eq 'Windows') { 'hooks\helios_pretooluse.ps1' } else { 'hooks/helios_pretooluse.ps1' } })
$evidencePath = Join-Path $HeliosGateRoot (& { if ($Platform -eq 'Windows') { 'hooks\evidence_capture.ps1' } else { 'hooks/evidence_capture.ps1' } })

if (-not (Test-Path $preToolPath)) {
    throw "helios_pretooluse.ps1 not found at: $preToolPath"
}
if (-not (Test-Path $evidencePath)) {
    throw "evidence_capture.ps1 not found at: $evidencePath"
}

# --- Read existing settings ---
$settingsDir = Split-Path $ClaudeSettingsPath
if (-not (Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
}

$existingSettings = @{}
$hashBefore = $null
if (Test-Path $ClaudeSettingsPath) {
    $raw = [System.IO.File]::ReadAllText($ClaudeSettingsPath)
    $existingSettings = $raw | ConvertFrom-Json
    $hashBefore = Get-FileHash256 $ClaudeSettingsPath
}

# --- Detect existing Helios hooks (path-specific) ---
# Returns: 'exact' if hook points to THIS HeliosGateRoot,
#           'different_root' if hook points to a DIFFERENT Helios root,
#           $false if no Helios hook found.
function Test-HeliosHookPresent($hookArray, $targetCommand) {
    if (-not $hookArray) { return $false }
    foreach ($entry in $hookArray) {
        if ($entry.matcher -eq 'Bash|PowerShell') {
            foreach ($h in $entry.hooks) {
                if (-not $h.command) { continue }
                if ($h.command -eq $targetCommand) { return 'exact' }
                if ($h.command -like '*helios_pretooluse*' -or $h.command -like '*evidence_capture*') {
                    return 'different_root'
                }
            }
        }
    }
    return $false
}

$existingHooks = @{}
if ($existingSettings.hooks) {
    $existingHooks = $existingSettings.hooks
}

$preToolCheck = Test-HeliosHookPresent $existingHooks.PreToolUse $preToolCommand
$postToolCheck = Test-HeliosHookPresent $existingHooks.PostToolUse $evidenceCommand
$postFailCheck = Test-HeliosHookPresent $existingHooks.PostToolUseFailure $evidenceCommand

$differentRootDetected = ($preToolCheck -eq 'different_root') -or ($postToolCheck -eq 'different_root') -or ($postFailCheck -eq 'different_root')

$preToolAlready = $preToolCheck -eq 'exact'
$postToolAlready = $postToolCheck -eq 'exact'
$postFailAlready = $postFailCheck -eq 'exact'

$allAlreadyPresent = $preToolAlready -and $postToolAlready -and $postFailAlready
$hooksAdded = @()
$hooksAlreadyPresent = @()

if ($preToolAlready) { $hooksAlreadyPresent += 'PreToolUse' } else { $hooksAdded += 'PreToolUse' }
if ($postToolAlready) { $hooksAlreadyPresent += 'PostToolUse' } else { $hooksAdded += 'PostToolUse' }
if ($postFailAlready) { $hooksAlreadyPresent += 'PostToolUseFailure' } else { $hooksAdded += 'PostToolUseFailure' }

if ($differentRootDetected -and -not $allAlreadyPresent) {
    Write-Host "WARNING: Existing Helios hooks point to a DIFFERENT runtime root."
    Write-Host "Requested root: $HeliosGateRoot"
    Write-Host "Existing hooks will be replaced with hooks pointing to the requested root."
}

if ($allAlreadyPresent) {
    Write-Host "All Helios hooks already active for this root: $ClaudeSettingsPath"
    $evidence = [ordered]@{
        schema_version       = 'helios-settings-activation-evidence.v1'
        timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
        settings_path        = $ClaudeSettingsPath
        backup_path          = $null
        settings_hash_before = $hashBefore
        settings_hash_after  = $hashBefore
        helios_gate_root     = $HeliosGateRoot
        platform             = $Platform
        hooks_added          = @()
        hooks_already_present = [string[]]$hooksAlreadyPresent
        status               = 'ALREADY_ACTIVE'
    }
    if ($EvidenceOutputDir) {
        if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
        $evPath = Join-Path $EvidenceOutputDir 'settings-activation-evidence.json'
        [System.IO.File]::WriteAllText($evPath, ($evidence | ConvertTo-Json -Depth 5), $Utf8NoBom)
    }
    return $evidence
}

# --- WhatIf: show plan and exit ---
if ($WhatIf) {
    Write-Host ''
    Write-Host '=== DRY RUN (no changes will be made) ==='
    Write-Host "Settings file:  $ClaudeSettingsPath"
    Write-Host "Backup target:  $ClaudeSettingsPath.pre-helios-backup"
    Write-Host "Helios root:    $HeliosGateRoot"
    Write-Host "Platform:       $Platform"
    Write-Host ''
    Write-Host 'Hook commands that WOULD be written:'
    Write-Host "  PreToolUse:         $preToolCommand"
    Write-Host "  PostToolUse:        $evidenceCommand"
    Write-Host "  PostToolUseFailure: $evidenceCommand"
    Write-Host ''
    Write-Host "Hooks to add:            $($hooksAdded -join ', ')"
    Write-Host "Hooks already present:   $($hooksAlreadyPresent -join ', ')"
    if ($differentRootDetected) {
        Write-Host 'NOTE: Existing Helios hooks point to a different root and will be replaced.'
    }
    Write-Host '=== END DRY RUN ==='
    return [ordered]@{
        status               = 'WHATIF'
        settings_path        = $ClaudeSettingsPath
        helios_gate_root     = $HeliosGateRoot
        hooks_would_add      = [string[]]$hooksAdded
        hooks_already_present = [string[]]$hooksAlreadyPresent
        different_root_detected = $differentRootDetected
        hook_commands        = [ordered]@{
            PreToolUse         = $preToolCommand
            PostToolUse        = $evidenceCommand
            PostToolUseFailure = $evidenceCommand
        }
    }
}

# --- Backup ---
$backupPath = $null
if (-not $NoBackup -and (Test-Path $ClaudeSettingsPath)) {
    $backupPath = "$ClaudeSettingsPath.pre-helios-backup"
    Copy-Item -Path $ClaudeSettingsPath -Destination $backupPath -Force
    Write-Host "Backup: $backupPath"
}

# --- Merge hooks ---
if (-not $existingSettings.hooks) {
    $existingSettings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
}
$hooks = $existingSettings.hooks

function Test-IsHeliosHook($entry) {
    foreach ($h in $entry.hooks) {
        if ($h.command -and ($h.command -like '*helios_pretooluse*' -or $h.command -like '*evidence_capture*')) {
            return $true
        }
    }
    return $false
}

function Set-HookEntry($hookName, $command) {
    $newEntry = @{
        matcher = 'Bash|PowerShell'
        hooks = @(@{
            type = 'command'
            command = $command
            timeout = $HookTimeout
        })
    }

    if (-not $hooks.$hookName) {
        $hooks | Add-Member -NotePropertyName $hookName -NotePropertyValue @($newEntry) -Force
    } else {
        $existing = @($hooks.$hookName)
        $nonHelios = @($existing | Where-Object { -not (Test-IsHeliosHook $_) })
        $hooks.$hookName = $nonHelios + @($newEntry)
    }
}

if (-not $preToolAlready) { Set-HookEntry 'PreToolUse' $preToolCommand }
if (-not $postToolAlready) { Set-HookEntry 'PostToolUse' $evidenceCommand }
if (-not $postFailAlready) { Set-HookEntry 'PostToolUseFailure' $evidenceCommand }

# --- Write settings ---
$settingsJson = $existingSettings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ClaudeSettingsPath, $settingsJson, $Utf8NoBom)
$hashAfter = Get-FileHash256 $ClaudeSettingsPath

Write-Host "Settings updated: $ClaudeSettingsPath"
Write-Host "Hooks added: $($hooksAdded -join ', ')"
if ($hooksAlreadyPresent.Count -gt 0) {
    Write-Host "Hooks already present: $($hooksAlreadyPresent -join ', ')"
}

# --- Evidence ---
$evidence = [ordered]@{
    schema_version        = 'helios-settings-activation-evidence.v1'
    timestamp_utc         = (Get-Date).ToUniversalTime().ToString('o')
    settings_path         = $ClaudeSettingsPath
    backup_path           = $backupPath
    settings_hash_before  = $hashBefore
    settings_hash_after   = $hashAfter
    helios_gate_root      = $HeliosGateRoot
    platform              = $Platform
    hook_commands         = [ordered]@{
        PreToolUse         = $preToolCommand
        PostToolUse        = $evidenceCommand
        PostToolUseFailure = $evidenceCommand
    }
    hooks_added           = [string[]]$hooksAdded
    hooks_already_present = [string[]]$hooksAlreadyPresent
    status                = 'ACTIVATED'
}

if ($EvidenceOutputDir) {
    if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
    $evPath = Join-Path $EvidenceOutputDir 'settings-activation-evidence.json'
    [System.IO.File]::WriteAllText($evPath, ($evidence | ConvertTo-Json -Depth 5), $Utf8NoBom)
    Write-Host "Evidence: $evPath"
}

return $evidence
