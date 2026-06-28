<#
.SYNOPSIS
    Verify Claude settings.json still contains expected Helios hook entries.
.DESCRIPTION
    Phase 4.1 external control-plane integrity check (Phase 4.0 test #11).
    Reads settings.json and verifies PreToolUse, PostToolUse, and PostToolUseFailure
    hook entries point to the expected Helios scripts.
    This is a secondary integrity check — even with filesystem locks, this confirms
    the hook routing is correct.
.PARAMETER SettingsJsonPath
    Path to Claude settings.json. Defaults to $env:USERPROFILE\.claude\settings.json.
.PARAMETER ExpectedPreToolUseHook
    Expected command pattern for PreToolUse hook. Default: gate_check.ps1.
.PARAMETER ExpectedPostToolUseHook
    Expected command pattern for PostToolUse hook. Default: evidence_capture.ps1.
#>
[CmdletBinding()]
param(
    [string]$SettingsJsonPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),

    [string]$ExpectedPreToolUseHook = 'gate_check.ps1',

    [string]$ExpectedPostToolUseHook = 'evidence_capture.ps1'
)

$ErrorActionPreference = 'Stop'

$result = @{
    settings_path = $SettingsJsonPath
    checked_utc = (Get-Date).ToUniversalTime().ToString('o')
    checks = @()
    status = 'UNKNOWN'
}

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $result.checks += @{
        check = $Name
        passed = $Passed
        detail = $Detail
    }
    $icon = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "  [$icon] $Name — $Detail"
}

Write-Host "=== Settings.json Integrity Check ===`n"

# Check 1: File exists
if (-not (Test-Path $SettingsJsonPath)) {
    Add-Check -Name 'file_exists' -Passed $false -Detail "settings.json not found at $SettingsJsonPath"
    $result.status = 'FAIL'
    Write-Host "`nRESULT: FAIL — settings.json not found. Helios cannot be active."
    return $result
}
Add-Check -Name 'file_exists' -Passed $true -Detail "Found at $SettingsJsonPath"

# Check 2: Parse JSON
try {
    $settings = Get-Content $SettingsJsonPath -Raw | ConvertFrom-Json
    Add-Check -Name 'valid_json' -Passed $true -Detail 'Parsed successfully'
} catch {
    Add-Check -Name 'valid_json' -Passed $false -Detail "Parse error: $($_.Exception.Message)"
    $result.status = 'FAIL'
    Write-Host "`nRESULT: FAIL — settings.json is not valid JSON."
    return $result
}

# Check 3: PreToolUse hook exists
$preToolUseHooks = $null
if ($settings.hooks -and $settings.hooks.PreToolUse) {
    $preToolUseHooks = $settings.hooks.PreToolUse
}

if ($preToolUseHooks) {
    $preToolUseCommands = @()
    foreach ($hook in $preToolUseHooks) {
        if ($hook.command) { $preToolUseCommands += $hook.command }
    }

    $hasExpectedPre = $preToolUseCommands | Where-Object { $_ -match [regex]::Escape($ExpectedPreToolUseHook) }
    if ($hasExpectedPre) {
        Add-Check -Name 'pretooluse_hook' -Passed $true -Detail "Found hook matching '$ExpectedPreToolUseHook'"
    } else {
        Add-Check -Name 'pretooluse_hook' -Passed $false -Detail "PreToolUse hooks exist but none match '$ExpectedPreToolUseHook'. Found: $($preToolUseCommands -join ', ')"
    }
} else {
    Add-Check -Name 'pretooluse_hook' -Passed $false -Detail 'No PreToolUse hooks defined — Helios gate system is INACTIVE'
}

# Check 4: PostToolUse hook exists
$postToolUseHooks = $null
if ($settings.hooks -and $settings.hooks.PostToolUse) {
    $postToolUseHooks = $settings.hooks.PostToolUse
}

if ($postToolUseHooks) {
    $postToolUseCommands = @()
    foreach ($hook in $postToolUseHooks) {
        if ($hook.command) { $postToolUseCommands += $hook.command }
    }

    $hasExpectedPost = $postToolUseCommands | Where-Object { $_ -match [regex]::Escape($ExpectedPostToolUseHook) }
    if ($hasExpectedPost) {
        Add-Check -Name 'posttooluse_hook' -Passed $true -Detail "Found hook matching '$ExpectedPostToolUseHook'"
    } else {
        Add-Check -Name 'posttooluse_hook' -Passed $false -Detail "PostToolUse hooks exist but none match '$ExpectedPostToolUseHook'. Found: $($postToolUseCommands -join ', ')"
    }
} else {
    Add-Check -Name 'posttooluse_hook' -Passed $false -Detail 'No PostToolUse hooks defined — evidence capture is INACTIVE'
}

# Check 5: PostToolUseFailure hook exists
$postFailHooks = $null
if ($settings.hooks -and $settings.hooks.PostToolUseFailure) {
    $postFailHooks = $settings.hooks.PostToolUseFailure
}

if ($postFailHooks) {
    $postFailCommands = @()
    foreach ($hook in $postFailHooks) {
        if ($hook.command) { $postFailCommands += $hook.command }
    }

    $hasExpectedFail = $postFailCommands | Where-Object { $_ -match [regex]::Escape($ExpectedPostToolUseHook) }
    if ($hasExpectedFail) {
        Add-Check -Name 'posttooluseFailure_hook' -Passed $true -Detail "Found hook matching '$ExpectedPostToolUseHook'"
    } else {
        Add-Check -Name 'posttoolusefailure_hook' -Passed $false -Detail "PostToolUseFailure hooks exist but none match '$ExpectedPostToolUseHook'"
    }
} else {
    Add-Check -Name 'posttoolusefailure_hook' -Passed $false -Detail 'No PostToolUseFailure hooks defined — failure evidence capture is INACTIVE'
}

# Overall result
$failedChecks = $result.checks | Where-Object { -not $_.passed }
if ($failedChecks.Count -eq 0) {
    $result.status = 'PASS'
    Write-Host "`nRESULT: PASS — all hook entries verified."
} else {
    $result.status = 'FAIL'
    Write-Host "`nRESULT: FAIL — $($failedChecks.Count) check(s) failed."
}

$result
