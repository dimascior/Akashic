<#
.SYNOPSIS
    Verify that all Helios protected runtime files have OS-native locks in place.
.DESCRIPTION
    Uses Get-AkashicLockStrategy to resolve the platform backend, then
    dispatches through AkashicLockDispatch to check lock status.

    Windows: parse icacls output for deny ACEs with W/D
    Linux:   parse lsattr output for immutable (i) flag
    macOS:   parse ls -lO output for uchg flag
    POSIX:   check mode bits for absent write permission
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER IncludeSettingsJson
    Also check the Claude settings.json lock status.
.PARAMETER SettingsJsonPath
    Path to Claude settings.json.
.PARAMETER IncludeTemplates
    Also check the templates/ directory lock status.
.PARAMETER IncludeMutableLifecycle
    Verify that mutable lifecycle directories are writable.
.PARAMETER PrivilegeMode
    Privilege escalation mode for Linux. Auto|None|Sudo|Doas|RootOnly.
.PARAMETER RequireStrongLock
    Fail if a strong backend is not available.
.PARAMETER AllowWeakFallback
    Allow degradation to chmod-based status check.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [switch]$IncludeSettingsJson,

    [string]$SettingsJsonPath,

    [switch]$IncludeTemplates,

    [switch]$IncludeMutableLifecycle,

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

if (-not $Strategy.implemented) {
    Write-Error "No lock backend available. Blockers: $($Strategy.blockers -join ', '). Notes: $($Strategy.notes -join '; ')"
    return @()
}

function Test-FileLockStatus {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND'; Locked = $false }
    }

    $locked = Test-AkashicLockState -Strategy $Strategy -Path $FilePath

    $status = if ($locked) { 'LOCKED' } else { 'UNLOCKED' }
    @{ Path = $FilePath; Label = $Label; Status = $status; Locked = $locked; Backend = $Strategy.backend }
}

function Test-DirWritable {
    param([string]$DirPath, [string]$Label)

    if (-not (Test-Path $DirPath)) {
        return @{ Path = $DirPath; Label = $Label; Status = 'NOT_FOUND'; Writable = $null }
    }

    $testFile = Join-Path $DirPath ".akashic-lock-test-$(Get-Random)"
    try {
        [System.IO.File]::WriteAllText($testFile, 'lock-test')
        Remove-Item $testFile -Force
        return @{ Path = $DirPath; Label = $Label; Status = 'WRITABLE'; Writable = $true }
    } catch {
        return @{ Path = $DirPath; Label = $Label; Status = 'NOT_WRITABLE'; Writable = $false }
    }
}

$results = @()
$allPassed = $true

Write-Host "=== Protected Runtime Lock Status ($($Strategy.backend) on $($Strategy.platform)) ==="
Write-Host ""

foreach ($relPath in $AkashicProtectedFiles) {
    $fullPath = Resolve-AkashicPath $HeliosGateRoot $relPath
    $r = Test-FileLockStatus -FilePath $fullPath -Label $relPath
    $results += $r

    $icon = if ($r.Locked) { '[LOCKED]' } elseif ($r.Status -eq 'NOT_FOUND') { '[MISSING]' } else { '[UNLOCKED]' }
    Write-Host "  $icon $($r.Label)"

    if (-not $r.Locked -and $r.Status -ne 'NOT_FOUND') { $allPassed = $false }
}

if ($IncludeTemplates) {
    Write-Host ""
    Write-Host "=== Template Lock Status ==="
    Write-Host ""
    $templatesDir = Join-Path $HeliosGateRoot 'templates'
    $r = Test-FileLockStatus -FilePath $templatesDir -Label 'templates/ (directory)'
    $results += $r
    $icon = if ($r.Locked) { '[LOCKED]' } elseif ($r.Status -eq 'NOT_FOUND') { '[N/A]' } else { '[UNLOCKED]' }
    Write-Host "  $icon $($r.Label)"

    if (Test-Path $templatesDir) {
        $templateFiles = Get-ChildItem -Path $templatesDir -File -Recurse
        foreach ($tf in $templateFiles) {
            $relLabel = "templates/$($tf.Name)"
            $r = Test-FileLockStatus -FilePath $tf.FullName -Label $relLabel
            $results += $r
            $icon = if ($r.Locked) { '[LOCKED]' } else { '[UNLOCKED]' }
            Write-Host "  $icon $($r.Label)"
        }
    }
}

if ($IncludeSettingsJson) {
    Write-Host ""
    Write-Host "=== External Control-Plane Lock Status ==="
    Write-Host ""
    $r = Test-FileLockStatus -FilePath $SettingsJsonPath -Label 'settings.json'
    $results += $r
    $icon = if ($r.Locked) { '[LOCKED]' } elseif ($r.Status -eq 'NOT_FOUND') { '[MISSING]' } else { '[UNLOCKED]' }
    Write-Host "  $icon $($r.Label)"
    if (-not $r.Locked -and $r.Status -ne 'NOT_FOUND') { $allPassed = $false }
}

if ($IncludeMutableLifecycle) {
    Write-Host ""
    Write-Host "=== Mutable Lifecycle Directory Status ==="
    Write-Host ""
    foreach ($dir in $AkashicMutableDirs) {
        $fullPath = Join-Path $HeliosGateRoot $dir
        $r = Test-DirWritable -DirPath $fullPath -Label "$dir/"
        $results += $r
        $icon = if ($r.Writable -eq $true) { '[WRITABLE]' } elseif ($r.Status -eq 'NOT_FOUND') { '[MISSING]' } else { '[BLOCKED]' }
        Write-Host "  $icon $($r.Label)"
        if ($r.Writable -eq $false) { $allPassed = $false }
    }
}

Write-Host ""
$lockedCount   = ($results | Where-Object { $_.Status -eq 'LOCKED' }).Count
$unlockedCount = ($results | Where-Object { $_.Status -eq 'UNLOCKED' }).Count
$missingCount  = ($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count

Write-Host "--- Status Summary ---"
Write-Host "Backend:  $($Strategy.backend) ($($Strategy.strength))"
Write-Host "Locked:   $lockedCount"
Write-Host "Unlocked: $unlockedCount"
Write-Host "Missing:  $missingCount"

if ($allPassed) {
    Write-Host "`nRESULT: PASS — all checked targets are in expected state."
} else {
    Write-Host "`nRESULT: FAIL — one or more targets are not in expected state."
}

$results
