# Test-HeliosPrerequisites.ps1 - Platform prerequisite checker
# Verifies everything needed before Akashic can install or activate a Helios
# runtime: PowerShell version, lock backend, filesystem support, Claude
# settings path, and runtime ownership.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [ValidateSet('Auto', 'Windows', 'Linux', 'macOS')]
    [string]$Platform = 'Auto',

    [string]$ClaudeSettingsPath
)

$ErrorActionPreference = 'Stop'

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

$checks = @()
$blockers = @()

function Add-Check([string]$Name, [string]$Status, $Detail) {
    $script:checks += [ordered]@{ check = $Name; status = $Status; detail = $Detail }
    $mark = switch ($Status) { 'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }; 'WARN' { '[WARN]' }; 'INFO' { '[INFO]' }; default { "[$Status]" } }
    Write-Host "$mark $Name$(if ($Detail) { ": $Detail" })"
    if ($Status -eq 'FAIL') { $script:blockers += $Name }
}

Write-Host "=== Helios Prerequisites ($Platform) ==="
Write-Host ""

# 1. PowerShell version
$psVer = "$($PSVersionTable.PSVersion)"
if ($Platform -eq 'Windows') {
    if ($PSVersionTable.PSVersion.Major -ge 5) {
        Add-Check 'PowerShell version' 'PASS' "PS $psVer"
    } else {
        Add-Check 'PowerShell version' 'FAIL' "PS $psVer - requires 5.1+"
    }
} else {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        Add-Check 'PowerShell version' 'PASS' "pwsh $psVer"
    } else {
        Add-Check 'PowerShell version' 'FAIL' "pwsh $psVer - requires 7+"
    }
}

# 2. Lock backend
switch ($Platform) {
    'Windows' {
        $icacls = Get-Command icacls -ErrorAction SilentlyContinue
        if ($icacls) { Add-Check 'Lock backend (icacls)' 'PASS' $icacls.Source }
        else { Add-Check 'Lock backend (icacls)' 'FAIL' 'icacls not found' }
    }
    'Linux' {
        $chattr = Get-Command chattr -ErrorAction SilentlyContinue
        $lsattr = Get-Command lsattr -ErrorAction SilentlyContinue
        if (-not $chattr) {
            foreach ($p in '/usr/bin/chattr', '/sbin/chattr', '/usr/sbin/chattr') {
                if (Test-Path $p) { $chattr = @{ Source = $p }; break }
            }
        }
        if (-not $lsattr) {
            foreach ($p in '/usr/bin/lsattr', '/sbin/lsattr', '/usr/sbin/lsattr') {
                if (Test-Path $p) { $lsattr = @{ Source = $p }; break }
            }
        }
        if ($chattr -and $lsattr) { Add-Check 'Lock backend (chattr/lsattr)' 'PASS' "chattr=$($chattr.Source) lsattr=$($lsattr.Source)" }
        elseif ($chattr) { Add-Check 'Lock backend (chattr/lsattr)' 'WARN' 'chattr found but lsattr missing' }
        else { Add-Check 'Lock backend (chattr/lsattr)' 'FAIL' 'chattr not found' }
    }
    'macOS' {
        $chflags = Get-Command chflags -ErrorAction SilentlyContinue
        if ($chflags) { Add-Check 'Lock backend (chflags)' 'PASS' $chflags.Source }
        else { Add-Check 'Lock backend (chflags)' 'FAIL' 'chflags not found' }
    }
}

# 3. Claude settings path
$settingsDir = Split-Path $ClaudeSettingsPath
if (Test-Path $ClaudeSettingsPath) {
    Add-Check 'Claude settings' 'PASS' "exists at $ClaudeSettingsPath"
} elseif (Test-Path $settingsDir) {
    Add-Check 'Claude settings' 'INFO' "directory exists, settings file not yet created: $ClaudeSettingsPath"
} else {
    Add-Check 'Claude settings' 'WARN' "directory does not exist: $settingsDir (will be created during activation)"
}

# 4. HeliosGateRoot target
if (Test-Path $HeliosGateRoot) {
    Add-Check 'Helios gate root' 'PASS' "exists at $HeliosGateRoot"

    # 5. Ownership check (Linux/macOS only)
    if ($Platform -ne 'Windows') {
        $ownerCheckDone = $false
        try {
            $currentUser = $env:USER
            if (-not $currentUser) { $currentUser = & whoami 2>&1 | Select-Object -First 1 }
            if ($currentUser) { $currentUser = "$currentUser".Trim() }

            $owner = $null
            try {
                $statResult = & stat -c '%U' $HeliosGateRoot 2>&1
                if ($LASTEXITCODE -eq 0) { $owner = "$statResult".Trim() }
            } catch { }
            if (-not $owner) {
                try {
                    $statResult = & stat -f '%Su' $HeliosGateRoot 2>&1
                    if ($LASTEXITCODE -eq 0) { $owner = "$statResult".Trim() }
                } catch { }
            }

            if ($owner -and $currentUser) {
                if ($owner -eq $currentUser) {
                    Add-Check 'Runtime ownership' 'PASS' "owned by $owner (current user)"
                } elseif ($owner -eq 'root') {
                    Add-Check 'Runtime ownership' 'FAIL' "owned by root but Claude runs as $currentUser"
                } else {
                    Add-Check 'Runtime ownership' 'WARN' "owned by $owner, current user is $currentUser"
                }
                $ownerCheckDone = $true
            }
        } catch { }
        if (-not $ownerCheckDone) {
            Add-Check 'Runtime ownership' 'INFO' 'could not determine ownership'
        }
    }

    # 6. Mutable directories writable
    $mutableDirs = @('pending', 'inflight', 'evidence', 'blocked')
    $writableFails = @()
    foreach ($dir in $mutableDirs) {
        $dirPath = Join-Path $HeliosGateRoot $dir
        if (Test-Path $dirPath) {
            $testFile = Join-Path $dirPath '.write-test'
            try {
                [System.IO.File]::WriteAllText($testFile, 'test')
                Remove-Item $testFile -Force
            } catch {
                $writableFails += $dir
            }
        }
    }
    if ($writableFails.Count -eq 0) {
        Add-Check 'Mutable directories writable' 'PASS' "all $($mutableDirs.Count) directories writable"
    } else {
        Add-Check 'Mutable directories writable' 'FAIL' "not writable: $($writableFails -join ', ')"
    }
} else {
    Add-Check 'Helios gate root' 'INFO' "does not yet exist: $HeliosGateRoot (will be created during Prepare)"
}

# 7. Filesystem type (Windows only - NTFS required)
if ($Platform -eq 'Windows' -and (Test-Path $HeliosGateRoot)) {
    try {
        $driveLetter = (Resolve-Path $HeliosGateRoot).Drive.Name
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($vol -and $vol.FileSystemType -eq 'NTFS') {
            Add-Check 'Filesystem' 'PASS' "NTFS on drive $driveLetter"
        } elseif ($vol) {
            Add-Check 'Filesystem' 'WARN' "$($vol.FileSystemType) on drive $driveLetter - NTFS recommended for icacls"
        }
    } catch {
        Add-Check 'Filesystem' 'INFO' 'could not determine filesystem type'
    }
}

Write-Host ""
if ($blockers.Count -gt 0) {
    Write-Host "BLOCKED: $($blockers.Count) prerequisite(s) failed: $($blockers -join ', ')"
} else {
    Write-Host "All prerequisites passed."
}

return [ordered]@{
    platform = $Platform
    checks   = $checks
    blockers = $blockers
    status   = if ($blockers.Count -gt 0) { 'BLOCKED' } else { 'READY' }
}
