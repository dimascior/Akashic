<#
.SYNOPSIS
    Create a disposable .command-gate fixture and test the full lock lifecycle.
.DESCRIPTION
    Proves the OS lock backend against a temporary fixture before any active
    Helios runtime is touched. Creates the 8 protected files and 4 mutable
    directories, runs lock/verify/negative-test/unlock/verify, then writes
    evidence JSON.

    The fixture is created under a temp directory, not inside any live
    .command-gate root. Active Helios runtime is never modified.
.PARAMETER FixtureRoot
    Override the temp directory for the fixture. Defaults to a subdirectory
    under $env:TEMP (Windows) or /tmp (Linux/macOS).
.PARAMETER EvidenceOutputDir
    Where to write the evidence JSON. Defaults to
    evidence/phase41/os-lock-validation/ relative to the adapter repo root.
.PARAMETER PrivilegeMode
    Privilege escalation mode. Auto|None|Sudo|Doas|RootOnly.
.PARAMETER RequireStrongLock
    Fail if a strong backend is not available.
.PARAMETER AllowWeakFallback
    Allow degradation to chmod a-w.
.PARAMETER KeepFixture
    Do not clean up the fixture directory after the test.
#>
[CmdletBinding()]
param(
    [string]$FixtureRoot,

    [string]$EvidenceOutputDir,

    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [switch]$RequireStrongLock,

    [switch]$AllowWeakFallback,

    [switch]$KeepFixture
)

$ErrorActionPreference = 'Stop'

$libDir = Join-Path $PSScriptRoot 'lib'
. (Join-Path $libDir 'AkashicLockTargets.ps1')
. (Join-Path $libDir 'AkashicLockBackend.ps1')

$Strategy = & (Join-Path $PSScriptRoot 'Get-AkashicLockStrategy.ps1') `
    -PrivilegeMode $PrivilegeMode `
    -RequireStrongLock:$RequireStrongLock `
    -AllowWeakFallback:$AllowWeakFallback

$platformTag = switch ($Strategy.platform) {
    'Windows' { 'windows' }
    'Linux'   { 'void-linux' }
    'macOS'   { 'macos' }
    default   { 'unknown' }
}

Write-Host '=== Akashic OS Lock Fixture Test ==='
Write-Host "Platform: $($Strategy.platform)"
Write-Host "Backend:  $($Strategy.backend) ($($Strategy.strength))"
Write-Host ''

$overallResult = 'PASS'
$negativeResults = [ordered]@{}
$unlockRecoveryResults = [ordered]@{}
$limitation = $null
$testedFiles = @()
$testedDirs = @()

# --- Blocked check ---
if (-not $Strategy.implemented) {
    Write-Host "BLOCKED: $($Strategy.blockers -join ', ')"

    $evidence = New-AkashicLockEvidence `
        -Strategy $Strategy `
        -TestPath '(not created)' `
        -ProtectedFilesTested @() `
        -MutableDirsTested @() `
        -NegativeResults @{} `
        -UnlockRecoveryResults @{} `
        -OverallResult 'BLOCKED' `
        -RemainingLimitation ($Strategy.blockers -join '; ')

    $adapterRoot = Split-Path $PSScriptRoot -Parent
    if (-not $EvidenceOutputDir) {
        $EvidenceOutputDir = Join-Path $adapterRoot 'evidence/phase41/os-lock-validation'
    }
    $evidenceDir = $EvidenceOutputDir.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }
    $evidencePath = Join-Path $evidenceDir "$platformTag.json"
    $evidenceJson = $evidence | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($evidencePath, $evidenceJson, $Utf8NoBom)
    Write-Host "Evidence written: $evidencePath"
    Write-Host ''
    Write-Host '=== Result: BLOCKED ==='
    return $evidence
}

# --- Create fixture ---
if (-not $FixtureRoot) {
    $tempBase = if ($env:TEMP) { $env:TEMP } elseif (Test-Path '/tmp') { '/tmp' } else { $env:HOME }
    $FixtureRoot = Join-Path $tempBase "akashic-lock-fixture-$(Get-Random)"
}

Write-Host "Fixture root: $FixtureRoot"
New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null

foreach ($relPath in $AkashicProtectedFiles) {
    $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
    $parentDir = Split-Path $fullPath -Parent
    if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($fullPath, "# fixture: $relPath`n", $Utf8NoBom)
}

foreach ($dir in $AkashicMutableDirs) {
    $dirPath = Join-Path $FixtureRoot $dir
    if (-not (Test-Path $dirPath)) { New-Item -ItemType Directory -Path $dirPath -Force | Out-Null }
}

Write-Host "Fixture created with $($AkashicProtectedFiles.Count) protected files and $($AkashicMutableDirs.Count) mutable dirs"
Write-Host ''

# --- Test phases (labeled block for early exit on FILESYSTEM_UNSUPPORTED) ---
:phases do {

    # --- Phase 1: Lock ---
    Write-Host '--- Phase 1: Lock protected files ---'
    $lockFailed = $false
    foreach ($relPath in $AkashicProtectedFiles) {
        $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
        $r = Invoke-AkashicLockPath -Strategy $Strategy -Path $fullPath
        if ($r.ExitCode -ne 0) {
            Write-Host "  FAIL lock: $relPath - $($r.Output)"
            $lockFailed = $true
            $overallResult = 'FAIL'
            if ("$($r.Output)" -match 'Inappropriate ioctl|not supported|Operation not supported') {
                $overallResult = 'BLOCKED'
                $limitation = 'FILESYSTEM_UNSUPPORTED: filesystem does not support immutable attributes'
            }
        } else {
            Write-Host "  LOCKED: $relPath"
        }
        $testedFiles += $relPath
    }
    Write-Host ''

    if ($lockFailed -and $overallResult -eq 'BLOCKED') {
        Write-Host "Fixture filesystem does not support $($Strategy.backend). Aborting test."
        break phases
    }

    # --- Phase 2: Verify status locked ---
    Write-Host '--- Phase 2: Verify status = LOCKED ---'
    $statusFailCount = 0
    foreach ($relPath in $AkashicProtectedFiles) {
        $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
        $locked = Test-AkashicLockState -Strategy $Strategy -Path $fullPath
        if ($locked) {
            Write-Host "  [LOCKED] $relPath"
        } else {
            Write-Host "  [NOT LOCKED] $relPath"
            $statusFailCount++
            $overallResult = 'FAIL'
        }
    }
    if ($statusFailCount -gt 0) {
        Write-Host "  $statusFailCount file(s) not detected as locked"
    }
    Write-Host ''

    # --- Phase 3: Negative tests on protected files ---
    Write-Host '--- Phase 3: Negative write/delete/rename tests ---'
    foreach ($relPath in $AkashicProtectedFiles) {
        $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
        $fileResults = [ordered]@{}

        $appendBlocked = $false
        try {
            [System.IO.File]::AppendAllText($fullPath, 'SHOULD_FAIL')
            $appendBlocked = $false
        } catch {
            $appendBlocked = $true
        }
        $fileResults['append_blocked'] = $appendBlocked

        $writeBlocked = $false
        try {
            [System.IO.File]::WriteAllText($fullPath, 'OVERWRITE_SHOULD_FAIL')
            $writeBlocked = $false
        } catch {
            $writeBlocked = $true
        }
        $fileResults['write_blocked'] = $writeBlocked

        $deleteBlocked = $false
        try {
            Remove-Item $fullPath -Force -ErrorAction Stop
            $deleteBlocked = $false
        } catch {
            $deleteBlocked = $true
        }
        $fileResults['delete_blocked'] = $deleteBlocked

        $renameBlocked = $false
        $renameDest = "$fullPath.renamed"
        try {
            Rename-Item $fullPath $renameDest -ErrorAction Stop
            Rename-Item $renameDest $fullPath -ErrorAction SilentlyContinue
            $renameBlocked = $false
        } catch {
            $renameBlocked = $true
        }
        $fileResults['rename_blocked'] = $renameBlocked

        $allBlocked = $appendBlocked -and $writeBlocked -and $deleteBlocked -and $renameBlocked
        $icon = if ($allBlocked) { 'PASS' } else { 'FAIL' }
        Write-Host "  [$icon] $relPath - append=$appendBlocked write=$writeBlocked delete=$deleteBlocked rename=$renameBlocked"
        if (-not $allBlocked) { $overallResult = 'FAIL' }

        $negativeResults[$relPath] = $fileResults
    }
    Write-Host ''

    # --- Phase 4: Mutable dirs still writable ---
    Write-Host '--- Phase 4: Mutable directories remain writable ---'
    foreach ($dir in $AkashicMutableDirs) {
        $dirPath = Join-Path $FixtureRoot $dir
        $testFile = Join-Path $dirPath ".fixture-write-test-$(Get-Random)"
        $writable = $false
        try {
            [System.IO.File]::WriteAllText($testFile, 'mutable-test')
            Remove-Item $testFile -Force
            $writable = $true
        } catch {}

        $icon = if ($writable) { 'WRITABLE' } else { 'BLOCKED' }
        Write-Host "  [$icon] $dir/"
        if (-not $writable) { $overallResult = 'FAIL' }
        $testedDirs += $dir
    }
    Write-Host ''

    # --- Phase 5: Unlock ---
    Write-Host '--- Phase 5: Unlock protected files ---'
    foreach ($relPath in $AkashicProtectedFiles) {
        $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
        if (-not (Test-Path $fullPath)) { continue }
        $r = Invoke-AkashicUnlockPath -Strategy $Strategy -Path $fullPath
        if ($r.ExitCode -ne 0) {
            Write-Host "  FAIL unlock: $relPath - $($r.Output)"
            $overallResult = 'FAIL'
        } else {
            Write-Host "  UNLOCKED: $relPath"
        }
    }
    Write-Host ''

    # --- Phase 6: Verify status unlocked ---
    Write-Host '--- Phase 6: Verify status = UNLOCKED ---'
    foreach ($relPath in $AkashicProtectedFiles) {
        $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
        if (-not (Test-Path $fullPath)) { continue }
        $locked = Test-AkashicLockState -Strategy $Strategy -Path $fullPath
        $icon = if (-not $locked) { 'UNLOCKED' } else { 'STILL LOCKED' }
        Write-Host "  [$icon] $relPath"
        if ($locked) { $overallResult = 'FAIL' }
    }
    Write-Host ''

    # --- Phase 7: Verify files writable after unlock ---
    Write-Host '--- Phase 7: Protected files writable after unlock ---'
    foreach ($relPath in $AkashicProtectedFiles) {
        $fullPath = Resolve-AkashicPath $FixtureRoot $relPath
        if (-not (Test-Path $fullPath)) { continue }

        $canWrite = $false
        try {
            [System.IO.File]::AppendAllText($fullPath, "`n# unlock-recovery-test")
            $canWrite = $true
        } catch {}

        $icon = if ($canWrite) { 'WRITABLE' } else { 'STILL BLOCKED' }
        Write-Host "  [$icon] $relPath"
        if (-not $canWrite) { $overallResult = 'FAIL' }
        $unlockRecoveryResults[$relPath] = $canWrite
    }
    Write-Host ''

} while ($false)

# --- Write evidence (runs for all outcomes including early break) ---
if (-not $limitation -and $overallResult -eq 'PASS' -and $Strategy.strength -eq 'weak_fallback') {
    $limitation = 'chmod a-w is a weak fallback; owner can restore write permission'
}

$evidence = New-AkashicLockEvidence `
    -Strategy $Strategy `
    -TestPath $FixtureRoot `
    -ProtectedFilesTested $testedFiles `
    -MutableDirsTested $testedDirs `
    -NegativeResults $negativeResults `
    -UnlockRecoveryResults $unlockRecoveryResults `
    -OverallResult $overallResult `
    -RemainingLimitation $limitation

$adapterRoot = Split-Path $PSScriptRoot -Parent
if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $adapterRoot 'evidence/phase41/os-lock-validation'
}
$evidenceDir = $EvidenceOutputDir.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }
$evidencePath = Join-Path $evidenceDir "$platformTag.json"
$evidenceJson = $evidence | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($evidencePath, $evidenceJson, $Utf8NoBom)
Write-Host "Evidence written: $evidencePath"

# --- Cleanup ---
if (-not $KeepFixture) {
    try {
        Remove-Item $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Fixture cleaned up: $FixtureRoot"
    } catch {
        Write-Warning "Could not fully clean fixture: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host "=== Result: $overallResult ==="

$evidence
