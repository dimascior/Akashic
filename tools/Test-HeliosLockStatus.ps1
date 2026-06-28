<#
.SYNOPSIS
    Verify that all Helios protected runtime files have OS-native locks in place.
.DESCRIPTION
    Checks icacls output for deny ACEs on each protected file.
    Returns structured results indicating LOCKED, UNLOCKED, or NOT_FOUND for each target.
.PARAMETER HeliosGateRoot
    Path to the .command-gate directory.
.PARAMETER IncludeSettingsJson
    Also check the Claude settings.json lock status.
.PARAMETER SettingsJsonPath
    Path to Claude settings.json. Defaults to $env:USERPROFILE\.claude\settings.json.
.PARAMETER IncludeTemplates
    Also check the templates/ directory lock status.
.PARAMETER IncludeMutableLifecycle
    Also verify that mutable lifecycle directories (pending/, inflight/, evidence/, blocked/) are writable.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [switch]$IncludeSettingsJson,

    [string]$SettingsJsonPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),

    [switch]$IncludeTemplates,

    [switch]$IncludeMutableLifecycle
)

$ErrorActionPreference = 'Stop'

$ProtectedFiles = @(
    'hooks\helios_pretooluse.ps1',
    'hooks\gate_check.ps1',
    'hooks\evidence_capture.ps1',
    'hooks\tier_classifier.ps1',
    'hooks\lib\HeliosIntegrityBridge.ps1',
    'policy\command-policy.json',
    'manifest\helios-envelope.json',
    'manifest\helios-envelope.sha256'
)

$MutableDirs = @(
    'pending',
    'inflight',
    'evidence',
    'blocked'
)

function Test-FileLockStatus {
    param([string]$FilePath, [string]$Label)

    if (-not (Test-Path $FilePath)) {
        return @{ Path = $FilePath; Label = $Label; Status = 'NOT_FOUND'; Locked = $false }
    }

    $aclOutput = & icacls $FilePath 2>&1 | Out-String

    # icacls renders the account as the SID (*S-1-1-0) or the localized
    # display name (Everyone, Tout le monde, Jeder, etc.).  We look for
    # a DENY ACE on either form that specifically includes write (W) or
    # delete (D) rights.  This avoids false positives from deny entries
    # that restrict other operations or target a different principal.
    #
    # Typical icacls output line:
    #   *S-1-1-0:(DENY)(W,D)
    #   Everyone:(DENY)(W,D)
    $lines = $aclOutput -split "`n"
    $hasDenyWD = $false
    foreach ($line in $lines) {
        if ($line -match '(?i)(\*S-1-1-0|Everyone)') {
            if ($line -match '\(DENY\)' -and $line -match '\([^)]*[WD][^)]*\)') {
                $hasDenyWD = $true
                break
            }
        }
    }

    if ($hasDenyWD) {
        return @{ Path = $FilePath; Label = $Label; Status = 'LOCKED'; Locked = $true }
    } else {
        return @{ Path = $FilePath; Label = $Label; Status = 'UNLOCKED'; Locked = $false }
    }
}

function Test-DirWritable {
    param([string]$DirPath, [string]$Label)

    if (-not (Test-Path $DirPath)) {
        return @{ Path = $DirPath; Label = $Label; Status = 'NOT_FOUND'; Writable = $null }
    }

    $testFile = Join-Path $DirPath ".helios-lock-test-$(Get-Random)"
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

Write-Host "=== Protected Runtime Lock Status ==="
Write-Host ""

foreach ($relPath in $ProtectedFiles) {
    $fullPath = Join-Path $HeliosGateRoot $relPath
    $r = Test-FileLockStatus -FilePath $fullPath -Label $relPath
    $results += $r

    $icon = if ($r.Locked) { '[LOCKED]' } elseif ($r.Status -eq 'NOT_FOUND') { '[MISSING]' } else { '[UNLOCKED]' }
    Write-Host "  $icon $($r.Label)"

    if (-not $r.Locked -and $r.Status -ne 'NOT_FOUND') { $allPassed = $false }
}

if ($IncludeTemplates) {
    Write-Host ""
    Write-Host "=== Template Lock Status (Conditional) ==="
    Write-Host ""
    $templatesDir = Join-Path $HeliosGateRoot 'templates'
    $r = Test-FileLockStatus -FilePath $templatesDir -Label 'templates/ (directory)'
    $results += $r
    $icon = if ($r.Locked) { '[LOCKED]' } elseif ($r.Status -eq 'NOT_FOUND') { '[N/A]' } else { '[UNLOCKED]' }
    Write-Host "  $icon $($r.Label)"

    if (Test-Path $templatesDir) {
        $templateFiles = Get-ChildItem -Path $templatesDir -File -Recurse
        foreach ($tf in $templateFiles) {
            $relLabel = "templates\$($tf.Name)"
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
    foreach ($dir in $MutableDirs) {
        $fullPath = Join-Path $HeliosGateRoot $dir
        $r = Test-DirWritable -DirPath $fullPath -Label "$dir/"
        $results += $r
        $icon = if ($r.Writable -eq $true) { '[WRITABLE]' } elseif ($r.Status -eq 'NOT_FOUND') { '[MISSING]' } else { '[BLOCKED]' }
        Write-Host "  $icon $($r.Label)"
        if ($r.Writable -eq $false) { $allPassed = $false }
    }
}

Write-Host ""
$lockedCount = ($results | Where-Object { $_.Status -eq 'LOCKED' }).Count
$unlockedCount = ($results | Where-Object { $_.Status -eq 'UNLOCKED' }).Count
$missingCount = ($results | Where-Object { $_.Status -eq 'NOT_FOUND' }).Count

Write-Host "--- Status Summary ---"
Write-Host "Locked:   $lockedCount"
Write-Host "Unlocked: $unlockedCount"
Write-Host "Missing:  $missingCount"

if ($allPassed) {
    Write-Host "`nRESULT: PASS — all checked targets are in expected state."
} else {
    Write-Host "`nRESULT: FAIL — one or more targets are not in expected state."
}

$results
