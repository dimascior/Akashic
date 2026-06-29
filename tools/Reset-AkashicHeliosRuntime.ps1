[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$RuntimeBundleRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [ValidateSet('Auto', 'Windows', 'macOS', 'Linux')]
    [string]$Platform = 'Auto',

    [switch]$DisableHooksDuringReset,
    [switch]$ReactivateHooksAfterReset,
    [switch]$RelockAfterReset,

    [string]$ResetBy = 'reset-tool',
    [string]$ClaudeSettingsPath,
    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$sep = [System.IO.Path]::DirectorySeparatorChar
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

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

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $AkashicRoot 'evidence\phase432c'
}

function Get-FileHash256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-GitHead([string]$Dir) {
    try {
        $prev = $PWD; Set-Location $Dir
        $result = git rev-parse HEAD 2>$null
        Set-Location $prev
        if ($LASTEXITCODE -eq 0 -and $result) { return $result.Trim() }
    } catch { try { Set-Location $prev } catch {} }
    return $null
}

function Normalize-RelPath([string]$Path) { $Path.Replace('\', '/') }

$protectedRelPaths = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1',
    'policy/command-policy.json'
)

$sourceProtectedRelPaths = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'policy/command-policy.json'
)

$mutableDirs = @('pending', 'inflight', 'evidence', 'blocked')

$steps = [System.Collections.Generic.List[object]]::new()
$ts = (Get-Date).ToUniversalTime()
$tsString = $ts.ToString('yyyy-MM-ddTHH:mm:ssZ')
$tsFileSafe = $ts.ToString('yyyyMMdd-HHmmss')
$hooksDeactivated = $false
$hooksReactivated = $false
$filesUnlocked = $false
$filesRelocked = $false

function Add-Step([string]$Name, [string]$Status, $Detail) {
    $steps.Add([ordered]@{ step = $Name; status = $Status; detail = $Detail })
    $mark = switch ($Status) {
        'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }
        'SKIP' { '[SKIP]' }; 'WARN' { '[WARN]' }
        default { "[$Status]" }
    }
    Write-Host "$mark $Name"
}

Write-Host '=== Helios Runtime Reset ==='
Write-Host "Platform:          $Platform"
Write-Host "AkashicRoot:       $AkashicRoot"
Write-Host "RuntimeBundleRoot: $RuntimeBundleRoot"
Write-Host "HeliosGateRoot:    $HeliosGateRoot"
Write-Host ''

$manifestPath = Join-Path $HeliosGateRoot ('manifest\helios-envelope.json'.Replace('\', $sep))
$sidecarPath  = Join-Path $HeliosGateRoot ('manifest\helios-envelope.sha256'.Replace('\', $sep))
$originPath   = Join-Path $HeliosGateRoot ('manifest\helios-install-origin.json'.Replace('\', $sep))

# ============================================================
# Collect pre-reset state
# ============================================================
$preResetManifestHash = if (Test-Path $manifestPath) { Get-FileHash256 $manifestPath } else { $null }
$preResetSidecarHash  = if (Test-Path $sidecarPath)  { ([System.IO.File]::ReadAllText($sidecarPath, $Utf8NoBom)).Trim() } else { $null }
$preResetOriginHash   = if (Test-Path $originPath)   { Get-FileHash256 $originPath } else { $null }

$oldRuntimeHashes = [ordered]@{}
foreach ($rel in $protectedRelPaths) {
    $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    $oldRuntimeHashes[$rel] = if (Test-Path $fullPath) { Get-FileHash256 $fullPath } else { $null }
}

$oldOriginRBR = $null
$oldAkashicHead = $null
$oldHeliosHead = $null
if (Test-Path $originPath) {
    $oldOriginData = Get-Content -LiteralPath $originPath -Raw | ConvertFrom-Json
    $oldOriginRBR   = $oldOriginData.runtime_bundle_root
    $oldAkashicHead = $oldOriginData.akashic_head
    $oldHeliosHead  = $oldOriginData.helios_head
}

# ============================================================
# Step 1: Assert Akashic trusted
# ============================================================
& (Join-Path $ScriptDir 'Assert-AkashicTrusted.ps1')
Add-Step 'Assert Akashic trusted' 'PASS' 'Self-integrity verified'

# ============================================================
# Step 2: Pre-reset detection
# ============================================================
$preDetection = $null
try {
    $preDetection = & (Join-Path $ScriptDir 'Test-HeliosRuntimeOrigin.ps1') `
        -AkashicRoot $AkashicRoot `
        -HeliosGateRoot $HeliosGateRoot `
        -RuntimeBundleRoot $RuntimeBundleRoot `
        -Platform $Platform `
        -AutomationMode 'DetectOnly'
    Add-Step 'Pre-reset detection' 'PASS' ([ordered]@{
        detection_type     = $preDetection.detection_type
        severity           = $preDetection.severity
        recommended_action = $preDetection.recommended_action
    })
} catch {
    Add-Step 'Pre-reset detection' 'WARN' "Detection failed: $_"
}

# ============================================================
# Step 3: Write pre-reset detection event
# ============================================================
if ($preDetection -and $preDetection.detection_type -ne 'CURRENT_MANIFEST_CLEAN' -and $preDetection.detection_type -ne 'ORIGIN_MATCH') {
    try {
        & (Join-Path $ScriptDir 'Write-HeliosRuntimeDetection.ps1') `
            -Detection $preDetection `
            -HeliosGateRoot $HeliosGateRoot `
            -AkashicEvidenceDir $EvidenceOutputDir
        Add-Step 'Write pre-reset detection' 'PASS' $preDetection.detection_type
    } catch {
        Add-Step 'Write pre-reset detection' 'WARN' "Write failed: $_"
    }
} else {
    Add-Step 'Write pre-reset detection' 'SKIP' 'Runtime clean or detection unavailable'
}

# ============================================================
# Step 4: Check/deactivate hooks
# ============================================================
if ($DisableHooksDuringReset) {
    try {
        $hookResult = & (Join-Path $ScriptDir 'Remove-AkashicClaudeHooks.ps1') `
            -ClaudeSettingsPath $ClaudeSettingsPath -Platform $Platform
        if ($hookResult.status -eq 'DEACTIVATED') {
            $hooksDeactivated = $true
            Add-Step 'Deactivate hooks' 'PASS' 'Helios hooks removed from Claude settings'
        } elseif ($hookResult.status -match 'NO.*HOOKS') {
            Add-Step 'Deactivate hooks' 'SKIP' 'No Helios hooks found'
        } else {
            Add-Step 'Deactivate hooks' 'WARN' "Status: $($hookResult.status)"
        }
    } catch {
        Add-Step 'Deactivate hooks' 'FAIL' "Hook deactivation failed: $_"
    }
} else {
    Add-Step 'Deactivate hooks' 'SKIP' 'Not requested (pass -DisableHooksDuringReset)'
}

# ============================================================
# Step 5: Unlock runtime files if locked
# ============================================================
$testLockFile = Join-Path $HeliosGateRoot ('hooks\gate_check.ps1'.Replace('\', $sep))
if (Test-Path $testLockFile) {
    $isLocked = $false
    try { [System.IO.File]::OpenWrite($testLockFile).Close() } catch { $isLocked = $true }
    if ($isLocked) {
        $unlockScript = Join-Path $ScriptDir 'Unlock-AkashicProtectedFiles.ps1'
        if (Test-Path $unlockScript) {
            & $unlockScript -HeliosGateRoot $HeliosGateRoot
            $filesUnlocked = $true
            Add-Step 'Unlock runtime files' 'PASS' 'Protected files unlocked'
        } else {
            Add-Step 'Unlock runtime files' 'FAIL' 'Unlock tool not found'
            throw 'Cannot reset: files locked and unlock tool unavailable.'
        }
    } else {
        Add-Step 'Unlock runtime files' 'SKIP' 'Files already writable'
    }
} else {
    Add-Step 'Unlock runtime files' 'SKIP' 'No existing runtime files to unlock'
}

# ============================================================
# Step 6: Archive active baseline
# ============================================================
$archiveDir = Join-Path $HeliosGateRoot "maintenance\archives\$tsFileSafe-reset"
$archiveSubDirs = @(
    '', 'manifest', 'protected', 'protected\hooks', 'protected\hooks\lib',
    'protected\policy', 'evidence', 'metadata'
)
foreach ($d in $archiveSubDirs) {
    $p = if ($d) { Join-Path $archiveDir $d } else { $archiveDir }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$archivedFiles = [System.Collections.Generic.List[string]]::new()
$archiveIndex = [ordered]@{
    archive_utc         = $tsString
    operation           = 'reset'
    source_authority    = 'CurrentRuntimeBundleRoot'
    runtime_bundle_root = $RuntimeBundleRoot
    helios_gate_root    = $HeliosGateRoot
    files               = [System.Collections.Generic.List[object]]::new()
}

foreach ($mf in @('helios-envelope.json', 'helios-envelope.sha256', 'helios-install-origin.json')) {
    $src = Join-Path $HeliosGateRoot "manifest\$mf"
    if (Test-Path $src) {
        $dest = Join-Path $archiveDir "manifest\$mf"
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $h = Get-FileHash256 $src
        $archivedFiles.Add("manifest/$mf")
        $archiveIndex.files.Add([ordered]@{ path = "manifest/$mf"; hash = $h; size = (Get-Item $src).Length })
    }
}

foreach ($rel in $protectedRelPaths) {
    $src = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    if (Test-Path $src) {
        $dest = Join-Path $archiveDir "protected\$($rel.Replace('/', $sep))"
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $h = Get-FileHash256 $src
        $archivedFiles.Add("protected/$rel")
        $archiveIndex.files.Add([ordered]@{ path = "protected/$rel"; hash = $h; size = (Get-Item $src).Length })
    }
}

if ($preDetection) {
    $preDetPath = Join-Path $archiveDir 'evidence\pre-reset-detection.json'
    [System.IO.File]::WriteAllText($preDetPath, ($preDetection | ConvertTo-Json -Depth 10), $Utf8NoBom)
}

$archiveIndexPath = Join-Path $archiveDir 'metadata\archive-index.json'
[System.IO.File]::WriteAllText($archiveIndexPath, ($archiveIndex | ConvertTo-Json -Depth 10), $Utf8NoBom)

Add-Step 'Archive active baseline' 'PASS' ([ordered]@{
    archive_path   = $archiveDir
    files_archived = $archivedFiles.Count
})

# ============================================================
# Step 7: Verify mutable dirs preserved
# ============================================================
$preservedDirs = [System.Collections.Generic.List[string]]::new()
foreach ($d in $mutableDirs) {
    $dp = Join-Path $HeliosGateRoot $d
    if (Test-Path $dp) { $preservedDirs.Add($d) }
    else {
        New-Item -ItemType Directory -Path $dp -Force | Out-Null
        $preservedDirs.Add($d)
    }
}
Add-Step 'Verify mutable dirs preserved' 'PASS' ([ordered]@{
    preserved = [string[]]$preservedDirs
    count     = $preservedDirs.Count
})

# ============================================================
# Step 8: Copy protected files from RuntimeBundleRoot
# ============================================================
$copiedCount = 0
foreach ($rel in $sourceProtectedRelPaths) {
    $src  = Join-Path $RuntimeBundleRoot ($rel.Replace('/', $sep))
    $dest = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if (-not (Test-Path $src)) {
        Add-Step 'Copy protected files from RuntimeBundleRoot' 'FAIL' "Missing source: $rel"
        throw "Source file missing in RuntimeBundleRoot: $rel ($src)"
    }
    Copy-Item -LiteralPath $src -Destination $dest -Force
    $copiedCount++
}
Add-Step 'Copy protected files from RuntimeBundleRoot' 'PASS' "$copiedCount files copied"

# ============================================================
# Step 9: Sync Akashic bridge
# ============================================================
$syncScript = Join-Path $ScriptDir 'Sync-AkashicBridge.ps1'
if (Test-Path $syncScript) {
    & $syncScript -AdapterRoot $AkashicRoot -HeliosGateRoot $HeliosGateRoot
    Add-Step 'Sync Akashic bridge' 'PASS' 'Bridge synced from Akashic source'
} else {
    $bridgeSrc  = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
    $bridgeDest = Join-Path $HeliosGateRoot ('hooks\lib\HeliosIntegrityBridge.ps1'.Replace('\', $sep))
    if (Test-Path $bridgeSrc) {
        Copy-Item -LiteralPath $bridgeSrc -Destination $bridgeDest -Force
        Add-Step 'Sync Akashic bridge' 'PASS' 'Bridge copied (sync tool not found)'
    } else {
        Add-Step 'Sync Akashic bridge' 'FAIL' 'Bridge source not found'
        throw "Bridge source not found: $bridgeSrc"
    }
}

# ============================================================
# Step 10: Generate fresh manifest
# ============================================================
& (Join-Path $ScriptDir 'AkashicEnvelopeManifest.ps1') `
    -HeliosGateRoot $HeliosGateRoot `
    -RebaselinedBy $ResetBy `
    -Note 'Reset from RuntimeBundleRoot'
Add-Step 'Generate fresh manifest' 'PASS' 'helios-envelope.json + sha256 generated'

# ============================================================
# Step 11: Verify manifest CLEAN
# ============================================================
$postResetManifestVerdict = 'UNKNOWN'
$verifyResult = & (Join-Path $ScriptDir 'AkashicEnvelopeIntegrityValidation.ps1') `
    -HeliosGateRoot $HeliosGateRoot
if ($verifyResult -and $verifyResult.verdict -eq 'CLEAN') {
    $postResetManifestVerdict = 'CLEAN'
    Add-Step 'Verify manifest CLEAN' 'PASS' 'Envelope integrity: CLEAN'
} else {
    $postResetManifestVerdict = if ($verifyResult) { $verifyResult.verdict } else { 'UNKNOWN' }
    Add-Step 'Verify manifest CLEAN' 'FAIL' "Envelope integrity: $postResetManifestVerdict"
}

# ============================================================
# Step 12: Generate fresh install-origin
# ============================================================
$originResult = & (Join-Path $ScriptDir 'New-HeliosInstallOrigin.ps1') `
    -AkashicRoot $AkashicRoot `
    -RuntimeBundleRoot $RuntimeBundleRoot `
    -HeliosGateRoot $HeliosGateRoot `
    -Platform $Platform `
    -InstallMode 'Reset' `
    -InstalledBy $ResetBy
if ($originResult -and $originResult.origin_verified) {
    Add-Step 'Generate fresh install-origin' 'PASS' ([ordered]@{
        source_count    = $originResult.source_count
        installed_count = $originResult.installed_count
        origin_verified = $true
    })
} else {
    Add-Step 'Generate fresh install-origin' 'WARN' 'Origin generated but not fully verified'
}

# ============================================================
# Step 13: Verify origin MATCH (post-reset detection)
# ============================================================
$postResetOriginVerdict = 'UNKNOWN'
$finalDetection = $null
try {
    $finalDetection = & (Join-Path $ScriptDir 'Test-HeliosRuntimeOrigin.ps1') `
        -AkashicRoot $AkashicRoot `
        -HeliosGateRoot $HeliosGateRoot `
        -RuntimeBundleRoot $RuntimeBundleRoot `
        -Platform $Platform `
        -AutomationMode 'DetectOnly'
    $postResetOriginVerdict = $finalDetection.origin_verdict
    if ($finalDetection.origin_verdict -eq 'MATCH') {
        Add-Step 'Verify origin MATCH' 'PASS' "Origin: MATCH | Detection: $($finalDetection.detection_type)"
    } else {
        Add-Step 'Verify origin MATCH' 'FAIL' "Origin: $($finalDetection.origin_verdict) | Detection: $($finalDetection.detection_type)"
    }
} catch {
    Add-Step 'Verify origin MATCH' 'FAIL' "Post-reset verification failed: $_"
}

# ============================================================
# Step 14: Reactivate hooks (if requested)
# ============================================================
if ($ReactivateHooksAfterReset) {
    try {
        $applyResult = & (Join-Path $ScriptDir 'Apply-AkashicClaudeHooks.ps1') `
            -HeliosGateRoot $HeliosGateRoot `
            -ClaudeSettingsPath $ClaudeSettingsPath `
            -Platform $Platform
        if ($applyResult.status -eq 'ACTIVATED' -or $applyResult.status -eq 'ALREADY_ACTIVE') {
            $hooksReactivated = $true
            Add-Step 'Reactivate hooks' 'PASS' $applyResult.status
        } else {
            Add-Step 'Reactivate hooks' 'WARN' "Status: $($applyResult.status)"
        }
    } catch {
        Add-Step 'Reactivate hooks' 'FAIL' "Reactivation failed: $_"
    }
} else {
    Add-Step 'Reactivate hooks' 'SKIP' 'Not requested (pass -ReactivateHooksAfterReset)'
}

# ============================================================
# Step 15: Relock (if requested)
# ============================================================
if ($RelockAfterReset) {
    $lockScript = Join-Path $ScriptDir 'Lock-AkashicProtectedFiles.ps1'
    if (Test-Path $lockScript) {
        & $lockScript -HeliosGateRoot $HeliosGateRoot
        $filesRelocked = $true
        Add-Step 'Relock runtime files' 'PASS' 'Protected files re-locked'
    } else {
        Add-Step 'Relock runtime files' 'FAIL' 'Lock tool not found'
    }
} else {
    Add-Step 'Relock runtime files' 'SKIP' 'Not requested (pass -RelockAfterReset)'
}

# ============================================================
# Collect post-reset hashes
# ============================================================
$postResetManifestHash = if (Test-Path $manifestPath) { Get-FileHash256 $manifestPath } else { $null }
$postResetSidecarHash  = if (Test-Path $sidecarPath)  { ([System.IO.File]::ReadAllText($sidecarPath, $Utf8NoBom)).Trim() } else { $null }
$postResetOriginHash   = if (Test-Path $originPath)   { Get-FileHash256 $originPath } else { $null }

$newRuntimeHashes = [ordered]@{}
foreach ($rel in $protectedRelPaths) {
    $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    $newRuntimeHashes[$rel] = if (Test-Path $fullPath) { Get-FileHash256 $fullPath } else { $null }
}

$newAkashicHead = Get-GitHead $AkashicRoot
$newHeliosHead = $null
try {
    $prev = $PWD; Set-Location $RuntimeBundleRoot
    $heliosRepoRoot = (git rev-parse --show-toplevel 2>$null)
    Set-Location $prev
    if ($heliosRepoRoot) { $newHeliosHead = Get-GitHead $heliosRepoRoot }
} catch { try { Set-Location $prev } catch {} }

$finalDetectionType     = if ($finalDetection) { $finalDetection.detection_type } else { 'UNKNOWN' }
$finalDetectionSeverity = if ($finalDetection) { $finalDetection.severity } else { $null }
$finalOriginMatch       = ($postResetOriginVerdict -eq 'MATCH')

# ============================================================
# Determine overall result
# ============================================================
$anyFail = $steps | Where-Object { $_.status -eq 'FAIL' }
$overall = if ($anyFail) { 'PARTIAL' } else { 'COMPLETE' }
if ($overall -eq 'PARTIAL' -and $hooksDeactivated -and -not $hooksReactivated) {
    Write-Host ''
    Write-Host '[WARN] Hooks were deactivated but reset did not fully complete.' -ForegroundColor Yellow
    Write-Host '       Claude commands will run without Helios gating until hooks are reactivated.' -ForegroundColor Yellow
    Write-Host '       Reactivate manually: Apply-AkashicClaudeHooks.ps1 -HeliosGateRoot ...' -ForegroundColor Yellow
}

# ============================================================
# Step 16-17: Write reset evidence
# ============================================================
$resetEvidence = [ordered]@{
    schema_version              = 'helios-runtime-reset-evidence.v1'
    timestamp_utc               = $tsString
    platform                    = $Platform
    reset_by                    = $ResetBy
    operation_type              = 'Reset'
    source_authority            = 'CurrentRuntimeBundleRoot'
    akashic_root                = $AkashicRoot
    runtime_bundle_root         = $RuntimeBundleRoot
    helios_gate_root            = $HeliosGateRoot

    pre_reset_detection_type    = if ($preDetection) { $preDetection.detection_type } else { $null }
    pre_reset_severity          = if ($preDetection) { $preDetection.severity } else { $null }
    pre_reset_recommended_action = if ($preDetection) { $preDetection.recommended_action } else { $null }
    pre_reset_manifest_hash     = $preResetManifestHash
    pre_reset_sidecar_hash      = $preResetSidecarHash
    pre_reset_origin_hash       = $preResetOriginHash
    pre_reset_detection         = $preDetection
    old_runtime_hashes          = $oldRuntimeHashes
    old_origin_runtime_bundle_root = $oldOriginRBR
    old_helios_head             = $oldHeliosHead
    old_akashic_head            = $oldAkashicHead

    post_reset_manifest_hash    = $postResetManifestHash
    post_reset_sidecar_hash     = $postResetSidecarHash
    post_reset_origin_hash      = $postResetOriginHash
    post_reset_manifest_verdict = $postResetManifestVerdict
    post_reset_origin_verdict   = $postResetOriginVerdict
    new_runtime_hashes          = $newRuntimeHashes
    new_runtime_bundle_root     = $RuntimeBundleRoot
    new_helios_head             = $newHeliosHead
    new_akashic_head            = $newAkashicHead

    final_detection_type        = $finalDetectionType
    final_detection_severity    = $finalDetectionSeverity
    final_origin_match          = $finalOriginMatch

    archive_path                = $archiveDir
    archived_files              = [string[]]$archivedFiles
    preserved_dirs              = [string[]]$preservedDirs

    hooks_deactivated           = $hooksDeactivated
    hooks_reactivated           = $hooksReactivated
    files_unlocked              = $filesUnlocked
    files_relocked              = $filesRelocked
    destructive_removal         = $false
    reactivation_requested      = [bool]$ReactivateHooksAfterReset
    relock_requested            = [bool]$RelockAfterReset

    steps                       = [object[]]$steps
    overall                     = $overall
}

$resetJson = $resetEvidence | ConvertTo-Json -Depth 10

$archiveEvidencePath = Join-Path $archiveDir 'evidence\reset-evidence.json'
[System.IO.File]::WriteAllText($archiveEvidencePath, $resetJson, $Utf8NoBom)

if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
$phasePath = Join-Path $EvidenceOutputDir "reset-evidence-$tsFileSafe.json"
[System.IO.File]::WriteAllText($phasePath, $resetJson, $Utf8NoBom)

Add-Step 'Write reset evidence' 'PASS' ([ordered]@{
    archive_evidence = $archiveEvidencePath
    phase_evidence   = $phasePath
})

Write-Host ''
Write-Host "=== Reset $overall ==="
$preType = if ($preDetection) { $preDetection.detection_type } else { 'N/A' }
$preSev  = if ($preDetection) { $preDetection.severity } else { 'N/A' }
Write-Host "  Pre-reset:  $preType ($preSev)"
Write-Host "  Post-reset: $finalDetectionType ($finalDetectionSeverity)"
Write-Host "  Origin:     $postResetOriginVerdict"
Write-Host "  Archive:    $archiveDir"
Write-Host ''

return $resetEvidence
