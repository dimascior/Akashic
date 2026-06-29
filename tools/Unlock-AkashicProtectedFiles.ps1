<#
.SYNOPSIS
    Remove OS-native filesystem locks from Helios protected runtime files.
.DESCRIPTION
    Uses Get-AkashicLockStrategy to resolve the platform backend, then
    dispatches through AkashicLockDispatch to remove locks.

    Windows: icacls /remove:d to strip deny ACEs for Everyone (*S-1-1-0)
    Linux:   chattr -i to clear immutable attribute
    macOS:   chflags nouchg to clear user immutable flag
    POSIX:   chmod u+w to restore owner write
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER IncludeSettingsJson
    Also unlock the Claude settings.json.
.PARAMETER SettingsJsonPath
    Path to Claude settings.json.
.PARAMETER IncludeTemplates
    Also unlock the templates/ directory and its contents.
.PARAMETER PrivilegeMode
    Privilege escalation mode for Linux. Auto|None|Sudo|Doas|RootOnly.
.PARAMETER RequireStrongLock
    Fail if a strong backend is not available.
.PARAMETER AllowWeakFallback
    Allow degradation to chmod u+w.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [switch]$IncludeSettingsJson,

    [string]$SettingsJsonPath,

    [switch]$IncludeTemplates,

    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [switch]$RequireStrongLock,

    [switch]$AllowWeakFallback
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'AkashicLockTargets.ps1')
. (Join-Path $libDir 'AkashicLockBackend.ps1')

if (-not $SettingsJsonPath) {
    $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { '~' }
    $SettingsJsonPath = Resolve-AkashicPath $homeDir '.claude/settings.json'
}

$Strategy = & (Join-Path $PSScriptRoot 'Get-AkashicLockStrategy.ps1') `
    -PrivilegeMode $PrivilegeMode `
    -RequireStrongLock:$RequireStrongLock `
    -AllowWeakFallback:$AllowWeakFallback

Write-Host "Unlock backend: $($Strategy.backend) ($($Strategy.strength)) on $($Strategy.platform)"

if (-not $Strategy.implemented) {
    Write-Error "No lock backend available. Blockers: $($Strategy.blockers -join ', '). Notes: $($Strategy.notes -join '; ')"
    return @()
}

function Unlock-SingleFile {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        Write-Warning "SKIP: $Label not found at $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND' }
    }

    if ($PSCmdlet.ShouldProcess($FilePath, "Remove $($Strategy.backend) lock")) {
        $r = Invoke-AkashicUnlockPath -Strategy $Strategy -Path $FilePath
        if ($r.ExitCode -eq 0) {
            Write-Host "UNLOCKED: $Label -> $FilePath [$($Strategy.backend)]"
            return @{ Path = $FilePath; Label = $Label; Status = 'UNLOCKED'; Backend = $Strategy.backend }
        } else {
            Write-Warning "FAILED to unlock $Label : $($r.Output)"
            return @{ Path = $FilePath; Label = $Label; Status = 'FAILED'; Detail = $r.Output; Backend = $Strategy.backend }
        }
    } else {
        Write-Host "WOULD UNLOCK: $Label -> $FilePath [$($Strategy.backend)]"
        return @{ Path = $FilePath; Label = $Label; Status = 'WHATIF'; Backend = $Strategy.backend }
    }
}

$results = @()

foreach ($relPath in $AkashicProtectedFiles) {
    $fullPath = Resolve-AkashicPath $HeliosGateRoot $relPath
    $results += Unlock-SingleFile -FilePath $fullPath -Label $relPath
}

if ($IncludeTemplates) {
    $templatesDir = Join-Path $HeliosGateRoot 'templates'
    if (Test-Path $templatesDir) {
        if ($PSCmdlet.ShouldProcess($templatesDir, "Remove $($Strategy.backend) lock on templates directory")) {
            $r = Invoke-AkashicUnlockPath -Strategy $Strategy -Path $templatesDir
            if ($r.ExitCode -eq 0) {
                Write-Host "UNLOCKED: templates/ directory -> $templatesDir [$($Strategy.backend)]"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'UNLOCKED'; Backend = $Strategy.backend }
            } else {
                Write-Warning "FAILED to unlock templates/ directory: $($r.Output)"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'FAILED'; Detail = $r.Output; Backend = $Strategy.backend }
            }
        }
        $templateFiles = Get-ChildItem -Path $templatesDir -File -Recurse
        foreach ($tf in $templateFiles) {
            $relLabel = "templates/$($tf.Name)"
            $results += Unlock-SingleFile -FilePath $tf.FullName -Label $relLabel
        }
    } else {
        Write-Warning "SKIP: templates/ directory not found at $templatesDir"
        $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'NOT_FOUND' }
    }
}

if ($IncludeSettingsJson) {
    $results += Unlock-SingleFile -FilePath $SettingsJsonPath -Label 'settings.json (external control-plane)'
}

$unlocked = ($results | Where-Object { $_.Status -eq 'UNLOCKED' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$notFound = ($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count
$whatIf   = ($results | Where-Object { $_.Status -eq 'WHATIF' }).Count

Write-Host "`n--- Unlock Summary ---"
Write-Host "Backend:   $($Strategy.backend) ($($Strategy.strength))"
Write-Host "Unlocked:  $unlocked"
Write-Host "Failed:    $failed"
Write-Host "Not found: $notFound"
if ($whatIf -gt 0) { Write-Host "WhatIf:    $whatIf" }

if ($failed -gt 0) {
    Write-Error "Unlock operation completed with $failed failure(s)."
}

$results
