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
    Expected command pattern for PreToolUse hook. Default: helios_pretooluse.ps1.
.PARAMETER ExpectedPostToolUseHook
    Expected command pattern for PostToolUse hook. Default: evidence_capture.ps1.
.PARAMETER ExpectedHeliosGateRoot
    Expected gate root path. When provided, verifies hook commands reference this path.
#>
[CmdletBinding()]
param(
    [string]$SettingsJsonPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),

    [string]$ExpectedPreToolUseHook = 'helios_pretooluse.ps1',

    [string]$ExpectedPostToolUseHook = 'evidence_capture.ps1',

    [string]$ExpectedHeliosGateRoot
)

$ErrorActionPreference = 'Stop'

$result = @{
    settings_path       = $SettingsJsonPath
    checked_utc         = (Get-Date).ToUniversalTime().ToString('o')
    checks              = @()
    status              = 'UNKNOWN'
    settings_hash       = $null
    hook_commands_found  = @{}
    hook_commands_expected = @{
        PreToolUse         = $ExpectedPreToolUseHook
        PostToolUse        = $ExpectedPostToolUseHook
        PostToolUseFailure = $ExpectedPostToolUseHook
    }
    pwsh_path_absolute  = $false
    gate_root_match     = $null
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

try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($SettingsJsonPath)
    $result.settings_hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
} catch {}

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
        $result.hook_commands_found['PreToolUse'] = @($hasExpectedPre)[0]
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
        $result.hook_commands_found['PostToolUse'] = @($hasExpectedPost)[0]
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
        $result.hook_commands_found['PostToolUseFailure'] = @($hasExpectedFail)[0]
    } else {
        Add-Check -Name 'posttoolusefailure_hook' -Passed $false -Detail "PostToolUseFailure hooks exist but none match '$ExpectedPostToolUseHook'"
    }
} else {
    Add-Check -Name 'posttoolusefailure_hook' -Passed $false -Detail 'No PostToolUseFailure hooks defined — failure evidence capture is INACTIVE'
}

# Check 6: PowerShell path is absolute in hook commands
$allCmds = @($result.hook_commands_found.Values) | Where-Object { $_ }
if ($allCmds.Count -gt 0) {
    $pwshAbsolute = $true
    foreach ($cmd in $allCmds) {
        $firstToken = ($cmd -split '\s+')[0]
        if ($firstToken -notmatch '^[A-Za-z]:\\' -and $firstToken -notmatch '^/' -and $firstToken -ne 'powershell' -and $firstToken -ne 'powershell.exe') {
            if ($firstToken -eq 'pwsh' -or $firstToken -eq 'pwsh.exe') {
                $pwshAbsolute = $false
            }
        }
    }
    $result.pwsh_path_absolute = $pwshAbsolute
    if ($pwshAbsolute) {
        Add-Check -Name 'pwsh_path_absolute' -Passed $true -Detail 'PowerShell executable uses absolute path or known system name'
    } else {
        Add-Check -Name 'pwsh_path_absolute' -Passed $false -Detail 'One or more hook commands use bare "pwsh" instead of absolute path'
    }
}

# Check 7: Gate root matches expected (if provided)
if ($ExpectedHeliosGateRoot) {
    $gateRootMatches = $true
    foreach ($cmd in $allCmds) {
        if ($cmd -notmatch [regex]::Escape($ExpectedHeliosGateRoot)) {
            $gateRootMatches = $false
        }
    }
    $result.gate_root_match = $gateRootMatches
    if ($gateRootMatches) {
        Add-Check -Name 'gate_root_match' -Passed $true -Detail "Hook commands reference expected gate root"
    } else {
        Add-Check -Name 'gate_root_match' -Passed $false -Detail "Hook commands do not match expected gate root: $ExpectedHeliosGateRoot"
    }
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
