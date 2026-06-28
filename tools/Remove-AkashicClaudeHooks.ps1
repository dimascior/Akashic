# Remove-AkashicClaudeHooks.ps1 — Remove Helios hook entries from Claude settings
# Removes only Helios-related hooks (matching helios_pretooluse or evidence_capture
# in command strings). Preserves all non-Helios hooks and other settings keys.
# Optionally restores from backup.
[CmdletBinding()]
param(
    [string]$ClaudeSettingsPath,

    [ValidateSet('Auto', 'Windows', 'Linux', 'macOS')]
    [string]$Platform = 'Auto',

    [switch]$RestoreFromBackup,

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

if (-not (Test-Path $ClaudeSettingsPath)) {
    throw "Settings file not found: $ClaudeSettingsPath"
}

$hashBefore = Get-FileHash256 $ClaudeSettingsPath
$backupPath = "$ClaudeSettingsPath.pre-helios-backup"

if ($RestoreFromBackup) {
    if (-not (Test-Path $backupPath)) {
        throw "Backup file not found: $backupPath"
    }
    Copy-Item -Path $backupPath -Destination $ClaudeSettingsPath -Force
    $hashAfter = Get-FileHash256 $ClaudeSettingsPath
    Write-Host "Restored from backup: $backupPath"

    $evidence = [ordered]@{
        schema_version       = 'helios-rollback-evidence.v1'
        timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
        settings_path        = $ClaudeSettingsPath
        method               = 'restore_from_backup'
        backup_path          = $backupPath
        settings_hash_before = $hashBefore
        settings_hash_after  = $hashAfter
        hooks_removed        = @('all_helios_hooks_via_backup_restore')
        status               = 'DEACTIVATED'
    }

    if ($EvidenceOutputDir) {
        if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
        $evPath = Join-Path $EvidenceOutputDir 'settings-rollback-evidence.json'
        [System.IO.File]::WriteAllText($evPath, ($evidence | ConvertTo-Json -Depth 5), $Utf8NoBom)
    }
    return $evidence
}

# --- Selective removal ---
$raw = [System.IO.File]::ReadAllText($ClaudeSettingsPath)
$settings = $raw | ConvertFrom-Json

if (-not $settings.hooks) {
    Write-Host "No hooks section found in settings."
    return [ordered]@{
        schema_version = 'helios-rollback-evidence.v1'
        timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
        settings_path  = $ClaudeSettingsPath
        method         = 'selective_removal'
        hooks_removed  = @()
        status         = 'NO_HOOKS_FOUND'
    }
}

function Test-IsHeliosHook($entry) {
    foreach ($h in $entry.hooks) {
        if ($h.command -and ($h.command -like '*helios_pretooluse*' -or $h.command -like '*evidence_capture*')) {
            return $true
        }
    }
    return $false
}

$hooksRemoved = @()

foreach ($hookName in @('PreToolUse', 'PostToolUse', 'PostToolUseFailure')) {
    if ($settings.hooks.$hookName) {
        $existing = @($settings.hooks.$hookName)
        $kept = @($existing | Where-Object { -not (Test-IsHeliosHook $_) })
        $removed = @($existing | Where-Object { Test-IsHeliosHook $_ })
        if ($removed.Count -gt 0) {
            $hooksRemoved += $hookName
        }
        if ($kept.Count -eq 0) {
            $settings.hooks.PSObject.Properties.Remove($hookName)
        } else {
            $settings.hooks.$hookName = $kept
        }
    }
}

# Remove empty hooks object
if ($settings.hooks.PSObject.Properties.Count -eq 0) {
    $settings.PSObject.Properties.Remove('hooks')
}

$settingsJson = $settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ClaudeSettingsPath, $settingsJson, $Utf8NoBom)
$hashAfter = Get-FileHash256 $ClaudeSettingsPath

Write-Host "Helios hooks removed from: $ClaudeSettingsPath"
Write-Host "Removed from: $($hooksRemoved -join ', ')"

$evidence = [ordered]@{
    schema_version       = 'helios-rollback-evidence.v1'
    timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
    settings_path        = $ClaudeSettingsPath
    method               = 'selective_removal'
    backup_path          = if (Test-Path $backupPath) { $backupPath } else { $null }
    settings_hash_before = $hashBefore
    settings_hash_after  = $hashAfter
    hooks_removed        = [string[]]$hooksRemoved
    status               = if ($hooksRemoved.Count -gt 0) { 'DEACTIVATED' } else { 'NO_HELIOS_HOOKS_FOUND' }
}

if ($EvidenceOutputDir) {
    if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
    $evPath = Join-Path $EvidenceOutputDir 'settings-rollback-evidence.json'
    [System.IO.File]::WriteAllText($evPath, ($evidence | ConvertTo-Json -Depth 5), $Utf8NoBom)
    Write-Host "Evidence: $evPath"
}

return $evidence
