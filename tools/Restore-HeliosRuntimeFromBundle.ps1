[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [ValidateSet('Auto', 'Windows', 'macOS', 'Linux')]
    [string]$Platform = 'Auto',

    [string]$RestoredBy = 'restore-tool',
    [string]$ClaudeSettingsPath,
    [string]$EvidenceOutputDir,

    [switch]$Force,
    [string]$ForceReason
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

$steps = [System.Collections.Generic.List[object]]::new()
$ts = (Get-Date).ToUniversalTime()
$tsString = $ts.ToString('yyyy-MM-ddTHH:mm:ssZ')
$tsFileSafe = $ts.ToString('yyyyMMdd-HHmmss')

function Add-Step([string]$Name, [string]$Status, $Detail) {
    $steps.Add([ordered]@{ step = $Name; status = $Status; detail = $Detail })
    $mark = switch ($Status) {
        'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }
        'SKIP' { '[SKIP]' }; 'WARN' { '[WARN]' }
        default { "[$Status]" }
    }
    Write-Host "$mark $Name"
}

Write-Host '=== Helios Runtime Restore ==='
Write-Host "Platform:      $Platform"
Write-Host "AkashicRoot:   $AkashicRoot"
Write-Host "HeliosGateRoot: $HeliosGateRoot"
Write-Host ''

$manifestPath = Join-Path $HeliosGateRoot ('manifest\helios-envelope.json'.Replace('\', $sep))
$sidecarPath  = Join-Path $HeliosGateRoot ('manifest\helios-envelope.sha256'.Replace('\', $sep))
$originPath   = Join-Path $HeliosGateRoot ('manifest\helios-install-origin.json'.Replace('\', $sep))

# ============================================================
# Step 1: Assert Akashic trusted
# ============================================================
& (Join-Path $ScriptDir 'Assert-AkashicTrusted.ps1')
Add-Step 'Assert Akashic trusted' 'PASS' 'Self-integrity verified'

# ============================================================
# Step 2: Read helios-install-origin.json
# ============================================================
if (-not (Test-Path $originPath)) {
    Add-Step 'Read install-origin' 'FAIL' 'helios-install-origin.json not found; cannot restore without origin record'
    throw 'Cannot restore: helios-install-origin.json does not exist. Use Reset instead.'
}

$originData = Get-Content -LiteralPath $originPath -Raw | ConvertFrom-Json
$originFileHash = Get-FileHash256 $originPath
$originCreatedUtc = $originData.created_utc
$recordedRBR = $originData.runtime_bundle_root
$recordedAkashicHead = $originData.akashic_head
$recordedHeliosHead = $originData.helios_head

Add-Step 'Read install-origin' 'PASS' ([ordered]@{
    origin_created_utc          = $originCreatedUtc
    recorded_runtime_bundle_root = $recordedRBR
    recorded_akashic_head       = $recordedAkashicHead
    recorded_helios_head        = $recordedHeliosHead
})

# ============================================================
# Step 3: Resolve recorded source repo state
# ============================================================
$sourceRepoPresent = $false
$sourceHeadMatchesRecorded = $null
$sourceHashesMatchRecorded = $null
$rbrStatus = 'MISSING'
$sourceMismatchFiles = [System.Collections.Generic.List[string]]::new()

if ($recordedRBR -and (Test-Path $recordedRBR)) {
    $sourceRepoPresent = $true
    $rbrStatus = 'PRESENT'

    $currentHeliosHead = $null
    try {
        $prev = $PWD; Set-Location $recordedRBR
        $heliosRepoRoot = (git rev-parse --show-toplevel 2>$null)
        Set-Location $prev
        if ($heliosRepoRoot) { $currentHeliosHead = Get-GitHead $heliosRepoRoot }
    } catch { try { Set-Location $prev } catch {} }

    $sourceHeadMatchesRecorded = $true
    if ($recordedHeliosHead -and $currentHeliosHead -and $currentHeliosHead -ne $recordedHeliosHead) {
        $sourceHeadMatchesRecorded = $false
        $rbrStatus = 'HEAD_CHANGED'
    }
    $currentAkashicHead = Get-GitHead $AkashicRoot
    if ($recordedAkashicHead -and $currentAkashicHead -and $currentAkashicHead -ne $recordedAkashicHead) {
        $sourceHeadMatchesRecorded = $false
    }

    $sourceHashesMatchRecorded = $true
    if ($originData.source_protected_hashes) {
        foreach ($prop in $originData.source_protected_hashes.PSObject.Properties) {
            $rel = Normalize-RelPath $prop.Name
            $fullPath = Join-Path $recordedRBR ($rel.Replace('/', $sep))
            if (Test-Path $fullPath) {
                $currentHash = Get-FileHash256 $fullPath
                if ($currentHash -ne $prop.Value) {
                    $sourceHashesMatchRecorded = $false
                    $sourceMismatchFiles.Add($rel)
                }
            } else {
                $sourceHashesMatchRecorded = $false
                $sourceMismatchFiles.Add($rel)
            }
        }
    }

    if (-not $sourceHeadMatchesRecorded -or -not $sourceHashesMatchRecorded) {
        $rbrStatus = 'SOURCE_CHANGED'
    }

    Add-Step 'Resolve recorded source state' 'PASS' ([ordered]@{
        status              = $rbrStatus
        head_matches        = $sourceHeadMatchesRecorded
        hashes_match        = $sourceHashesMatchRecorded
        mismatch_file_count = $sourceMismatchFiles.Count
    })
} else {
    Add-Step 'Resolve recorded source state' 'FAIL' "Recorded RuntimeBundleRoot not found: $recordedRBR"
}

# ============================================================
# Step 4: Confirm source still available
# ============================================================
$restorePolicy = $null
$overrideUsed = $false
$overrideReason = $null

if (-not $sourceRepoPresent) {
    Add-Step 'Confirm source available' 'FAIL' 'Recorded source path does not exist; restore blocked'
    throw "Cannot restore: recorded RuntimeBundleRoot not found at $recordedRBR. Source must exist to restore."
} elseif ($rbrStatus -eq 'SOURCE_CHANGED' -and -not $Force) {
    Add-Step 'Confirm source available' 'FAIL' ([ordered]@{
        status   = $rbrStatus
        message  = 'Source changed since install; pass -Force to proceed'
        mismatch = [string[]]$sourceMismatchFiles
    })
    throw "Source has changed since install. Use -Force -ForceReason '...' to override, or use Reset-AkashicHeliosRuntime with the current source."
} elseif ($rbrStatus -eq 'SOURCE_CHANGED' -and $Force) {
    $overrideUsed = $true
    $overrideReason = if ($ForceReason) { $ForceReason } else { 'Forced by operator' }
    $restorePolicy = 'source_changed_forced'
    Add-Step 'Confirm source available' 'WARN' "Source changed; proceeding with -Force ($overrideReason)"
} else {
    $restorePolicy = 'exact_match'
    Add-Step 'Confirm source available' 'PASS' 'Source matches recorded state'
}

# ============================================================
# Step 5: Compare current runtime to recorded origin
# ============================================================
$originDriftFiles = [System.Collections.Generic.List[string]]::new()
if ($originData.installed_runtime_hashes) {
    foreach ($prop in $originData.installed_runtime_hashes.PSObject.Properties) {
        $rel = Normalize-RelPath $prop.Name
        $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
        if (Test-Path $fullPath) {
            $currentHash = Get-FileHash256 $fullPath
            if ($currentHash -ne $prop.Value) { $originDriftFiles.Add($rel) }
        } else {
            $originDriftFiles.Add($rel)
        }
    }
}

if ($originDriftFiles.Count -eq 0) {
    Add-Step 'Compare runtime to recorded origin' 'PASS' 'All installed files match recorded origin'
} else {
    Add-Step 'Compare runtime to recorded origin' 'WARN' ([ordered]@{
        drift_count = $originDriftFiles.Count
        drifted     = [string[]]$originDriftFiles
    })
}

# ============================================================
# Step 6: Archive current runtime baseline
# ============================================================
$archiveDir = Join-Path $HeliosGateRoot "maintenance\archives\$tsFileSafe-restore"
$archiveSubDirs = @('', 'manifest', 'protected', 'protected\hooks', 'protected\hooks\lib', 'protected\policy', 'metadata')
foreach ($d in $archiveSubDirs) {
    $p = if ($d) { Join-Path $archiveDir $d } else { $archiveDir }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$archivedFiles = [System.Collections.Generic.List[string]]::new()
$archiveIndex = [ordered]@{
    archive_utc      = $tsString
    operation        = 'restore'
    source_authority = 'RecordedInstallOrigin'
    recorded_runtime_bundle_root = $recordedRBR
    helios_gate_root = $HeliosGateRoot
    files            = [System.Collections.Generic.List[object]]::new()
}

foreach ($mf in @('helios-envelope.json', 'helios-envelope.sha256', 'helios-install-origin.json')) {
    $src = Join-Path $HeliosGateRoot "manifest\$mf"
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $archiveDir "manifest\$mf") -Force
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

$archiveIndexPath = Join-Path $archiveDir 'metadata\archive-index.json'
[System.IO.File]::WriteAllText($archiveIndexPath, ($archiveIndex | ConvertTo-Json -Depth 10), $Utf8NoBom)

Add-Step 'Archive current baseline' 'PASS' ([ordered]@{
    archive_path   = $archiveDir
    files_archived = $archivedFiles.Count
})

# ============================================================
# Step 7: Restore protected files from recorded source
# ============================================================
$restoredCount = 0
foreach ($rel in $sourceProtectedRelPaths) {
    $src  = Join-Path $recordedRBR ($rel.Replace('/', $sep))
    $dest = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $restoredCount++
    } else {
        Add-Step 'Restore protected files' 'FAIL' "Source missing: $rel"
        throw "Recorded source file missing: $rel ($src)"
    }
}
Add-Step 'Restore protected files' 'PASS' "$restoredCount files restored from recorded source"

# ============================================================
# Step 8: Restore/sync bridge
# ============================================================
$syncScript = Join-Path $ScriptDir 'Sync-AkashicBridge.ps1'
if (Test-Path $syncScript) {
    & $syncScript -AdapterRoot $AkashicRoot -HeliosGateRoot $HeliosGateRoot
    Add-Step 'Sync bridge' 'PASS' 'Bridge synced from current Akashic source'
} else {
    $bridgeSrc  = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
    $bridgeDest = Join-Path $HeliosGateRoot ('hooks\lib\HeliosIntegrityBridge.ps1'.Replace('\', $sep))
    if (Test-Path $bridgeSrc) {
        Copy-Item -LiteralPath $bridgeSrc -Destination $bridgeDest -Force
        Add-Step 'Sync bridge' 'PASS' 'Bridge copied from Akashic source'
    } else {
        Add-Step 'Sync bridge' 'WARN' 'Bridge source not found; bridge may be stale'
    }
}

# ============================================================
# Step 9: Regenerate manifest
# ============================================================
& (Join-Path $ScriptDir 'AkashicEnvelopeManifest.ps1') `
    -HeliosGateRoot $HeliosGateRoot `
    -RebaselinedBy $RestoredBy `
    -Note 'Restored from recorded install-origin'
Add-Step 'Regenerate manifest' 'PASS' 'helios-envelope.json + sha256 generated'

# ============================================================
# Step 10: Handle install-origin per restore policy
# ============================================================
if ($restorePolicy -eq 'exact_match') {
    Add-Step 'Preserve install-origin' 'SKIP' 'Source matches recorded state; origin unchanged'
} else {
    & (Join-Path $ScriptDir 'New-HeliosInstallOrigin.ps1') `
        -AkashicRoot $AkashicRoot `
        -RuntimeBundleRoot $recordedRBR `
        -HeliosGateRoot $HeliosGateRoot `
        -Platform $Platform `
        -InstallMode 'Restore' `
        -InstalledBy $RestoredBy
    Add-Step 'Regenerate install-origin' 'PASS' 'Origin regenerated for changed source state'
}

# ============================================================
# Step 11-12: Verify manifest CLEAN
# ============================================================
$postRestoreManifestVerdict = 'UNKNOWN'
$verifyResult = & (Join-Path $ScriptDir 'AkashicEnvelopeIntegrityValidation.ps1') `
    -HeliosGateRoot $HeliosGateRoot
if ($verifyResult -and $verifyResult.verdict -eq 'CLEAN') {
    $postRestoreManifestVerdict = 'CLEAN'
    Add-Step 'Verify manifest CLEAN' 'PASS' 'Envelope integrity: CLEAN'
} else {
    $postRestoreManifestVerdict = if ($verifyResult) { $verifyResult.verdict } else { 'UNKNOWN' }
    Add-Step 'Verify manifest CLEAN' 'FAIL' "Envelope integrity: $postRestoreManifestVerdict"
}

# ============================================================
# Step 13: Verify origin MATCH
# ============================================================
$postRestoreOriginVerdict = 'UNKNOWN'
try {
    $finalDetection = & (Join-Path $ScriptDir 'Test-HeliosRuntimeOrigin.ps1') `
        -AkashicRoot $AkashicRoot `
        -HeliosGateRoot $HeliosGateRoot `
        -RuntimeBundleRoot $recordedRBR `
        -Platform $Platform `
        -AutomationMode 'DetectOnly'
    $postRestoreOriginVerdict = $finalDetection.origin_verdict
    if ($finalDetection.origin_verdict -eq 'MATCH') {
        Add-Step 'Verify origin MATCH' 'PASS' "Origin: MATCH | Detection: $($finalDetection.detection_type)"
    } else {
        Add-Step 'Verify origin MATCH' 'WARN' "Origin: $($finalDetection.origin_verdict) | Detection: $($finalDetection.detection_type)"
    }
} catch {
    Add-Step 'Verify origin MATCH' 'FAIL' "Verification failed: $_"
}

# ============================================================
# Collect post-restore hashes
# ============================================================
$postRestoreManifestHash = if (Test-Path $manifestPath) { Get-FileHash256 $manifestPath } else { $null }
$postRestoreSidecarHash  = if (Test-Path $sidecarPath)  { ([System.IO.File]::ReadAllText($sidecarPath, $Utf8NoBom)).Trim() } else { $null }
$postRestoreOriginHash   = if (Test-Path $originPath)   { Get-FileHash256 $originPath } else { $null }

$restoredHashes = [ordered]@{}
foreach ($rel in $protectedRelPaths) {
    $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    $restoredHashes[$rel] = if (Test-Path $fullPath) { Get-FileHash256 $fullPath } else { $null }
}

$anyFail = $steps | Where-Object { $_.status -eq 'FAIL' }
$overall = if ($anyFail) { 'PARTIAL' } else { 'COMPLETE' }

# ============================================================
# Step 14: Write restore evidence
# ============================================================
$restoreEvidence = [ordered]@{
    schema_version                  = 'helios-runtime-restore-evidence.v1'
    timestamp_utc                   = $tsString
    platform                        = $Platform
    restored_by                     = $RestoredBy
    operation_type                  = 'Restore'
    source_authority                = 'RecordedInstallOrigin'
    akashic_root                    = $AkashicRoot
    helios_gate_root                = $HeliosGateRoot

    origin_file_hash                = $originFileHash
    origin_created_utc              = $originCreatedUtc
    recorded_runtime_bundle_root    = $recordedRBR
    recorded_helios_head            = $recordedHeliosHead
    recorded_akashic_head           = $recordedAkashicHead

    current_runtime_bundle_root_status = $rbrStatus
    source_repo_present             = $sourceRepoPresent
    source_repo_head_matches_recorded = $sourceHeadMatchesRecorded
    source_hashes_match_recorded    = $sourceHashesMatchRecorded

    restored_runtime_hashes         = $restoredHashes
    post_restore_manifest_hash      = $postRestoreManifestHash
    post_restore_sidecar_hash       = $postRestoreSidecarHash
    post_restore_origin_hash        = $postRestoreOriginHash
    post_restore_manifest_verdict   = $postRestoreManifestVerdict
    post_restore_origin_verdict     = $postRestoreOriginVerdict

    restore_policy                  = $restorePolicy
    override_used                   = $overrideUsed
    override_reason                 = $overrideReason

    archive_path                    = $archiveDir
    archived_files                  = [string[]]$archivedFiles
    source_mismatch_files           = [string[]]$sourceMismatchFiles

    steps                           = [object[]]$steps
    overall                         = $overall
}

$restoreJson = $restoreEvidence | ConvertTo-Json -Depth 10

$archiveEvidencePath = Join-Path $archiveDir 'metadata\restore-evidence.json'
[System.IO.File]::WriteAllText($archiveEvidencePath, $restoreJson, $Utf8NoBom)

if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
$phasePath = Join-Path $EvidenceOutputDir "restore-evidence-$tsFileSafe.json"
[System.IO.File]::WriteAllText($phasePath, $restoreJson, $Utf8NoBom)

Add-Step 'Write restore evidence' 'PASS' ([ordered]@{
    archive_evidence = $archiveEvidencePath
    phase_evidence   = $phasePath
})

Write-Host ''
Write-Host "=== Restore $overall ==="
Write-Host "  Source:    $recordedRBR ($rbrStatus)"
Write-Host "  Policy:    $restorePolicy"
Write-Host "  Manifest:  $postRestoreManifestVerdict"
Write-Host "  Origin:    $postRestoreOriginVerdict"
Write-Host "  Archive:   $archiveDir"
Write-Host ''

return $restoreEvidence
