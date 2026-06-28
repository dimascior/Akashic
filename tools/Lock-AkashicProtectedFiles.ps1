<#
.SYNOPSIS
    Apply OS-native filesystem locks to Helios protected runtime files.
.DESCRIPTION
    Uses Get-AkashicLockStrategy to resolve the platform backend, then
    dispatches through AkashicLockDispatch to apply locks.

    Windows: icacls deny write/delete to Everyone (*S-1-1-0)
    Linux:   chattr +i immutable attribute
    macOS:   chflags uchg user immutable flag
    POSIX:   chmod a-w (weak fallback, opt-in)
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER IncludeSettingsJson
    Also lock the Claude settings.json.
.PARAMETER SettingsJsonPath
    Path to Claude settings.json.
.PARAMETER IncludeTemplates
    Also lock the templates/ directory and its contents.
.PARAMETER PrivilegeMode
    Privilege escalation mode for Linux. Auto|None|Sudo|Doas|RootOnly.
.PARAMETER RequireStrongLock
    Fail if a strong backend is not available.
.PARAMETER AllowWeakFallback
    Allow degradation to chmod a-w.
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

Write-Host "Lock backend: $($Strategy.backend) ($($Strategy.strength)) on $($Strategy.platform)"

if (-not $Strategy.implemented) {
    Write-Error "No lock backend available. Blockers: $($Strategy.blockers -join ', '). Notes: $($Strategy.notes -join '; ')"
    return @()
}

function Lock-SingleFile {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        Write-Warning "SKIP: $Label not found at $FilePath"
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND' }
    }

    if ($PSCmdlet.ShouldProcess($FilePath, "Apply $($Strategy.backend) lock")) {
        $r = Invoke-AkashicLockPath -Strategy $Strategy -Path $FilePath
        if ($r.ExitCode -eq 0) {
            Write-Host "LOCKED: $Label -> $FilePath [$($Strategy.backend)]"
            return @{ Path = $FilePath; Label = $Label; Status = 'LOCKED'; Backend = $Strategy.backend }
        } else {
            Write-Warning "FAILED to lock $Label : $($r.Output)"
            return @{ Path = $FilePath; Label = $Label; Status = 'FAILED'; Detail = $r.Output; Backend = $Strategy.backend }
        }
    } else {
        Write-Host "WOULD LOCK: $Label -> $FilePath [$($Strategy.backend)]"
        return @{ Path = $FilePath; Label = $Label; Status = 'WHATIF'; Backend = $Strategy.backend }
    }
}

$results = @()

foreach ($relPath in $AkashicProtectedFiles) {
    $fullPath = Resolve-AkashicPath $HeliosGateRoot $relPath
    $results += Lock-SingleFile -FilePath $fullPath -Label $relPath
}

if ($IncludeTemplates) {
    $templatesDir = Join-Path $HeliosGateRoot 'templates'
    if (Test-Path $templatesDir) {
        $templateFiles = Get-ChildItem -Path $templatesDir -File -Recurse
        foreach ($tf in $templateFiles) {
            $relLabel = "templates/$($tf.Name)"
            $results += Lock-SingleFile -FilePath $tf.FullName -Label $relLabel
        }
        if ($PSCmdlet.ShouldProcess($templatesDir, "Apply $($Strategy.backend) lock on templates directory")) {
            $r = Invoke-AkashicLockPath -Strategy $Strategy -Path $templatesDir
            if ($r.ExitCode -eq 0) {
                Write-Host "LOCKED: templates/ directory -> $templatesDir [$($Strategy.backend)]"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'LOCKED'; Backend = $Strategy.backend }
            } else {
                Write-Warning "FAILED to lock templates/ directory: $($r.Output)"
                $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'FAILED'; Detail = $r.Output; Backend = $Strategy.backend }
            }
        }
    } else {
        Write-Warning "SKIP: templates/ directory not found at $templatesDir"
        $results += @{ Path = $templatesDir; Label = 'templates/ (directory)'; Status = 'NOT_FOUND' }
    }
}

if ($IncludeSettingsJson) {
    $results += Lock-SingleFile -FilePath $SettingsJsonPath -Label 'settings.json (external control-plane)'
}

$locked   = ($results | Where-Object { $_.Status -eq 'LOCKED' }).Count
$failed   = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count
$notFound = ($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count
$whatIf   = ($results | Where-Object { $_.Status -eq 'WHATIF' }).Count

Write-Host "`n--- Lock Summary ---"
Write-Host "Backend:   $($Strategy.backend) ($($Strategy.strength))"
Write-Host "Locked:    $locked"
Write-Host "Failed:    $failed"
Write-Host "Not found: $notFound"
if ($whatIf -gt 0) { Write-Host "WhatIf:    $whatIf" }

if ($failed -gt 0) {
    Write-Error "Lock operation completed with $failed failure(s)."
}

$results
