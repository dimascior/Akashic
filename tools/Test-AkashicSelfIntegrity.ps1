# Test-AkashicSelfIntegrity.ps1 - Verify Akashic files against its self-manifest
# Full classification audit: every repo file is protected, mutable, ignored, or unknown.
# Hash-only self-integrity detects drift. Signed or external authority is
# required to prevent an agent from rewriting both files and manifests.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [string]$EvidenceOutputDir,

    [switch]$AllowUnclassified
)

$ErrorActionPreference = 'Stop'
$AkashicRoot = $AkashicRoot.TrimEnd('\', '/')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha = [System.Security.Cryptography.SHA256]::Create()

$libDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'lib'
. (Join-Path $libDir 'AkashicCoveragePolicy.ps1')

function Get-Hash([string]$FilePath) {
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

$sep = [System.IO.Path]::DirectorySeparatorChar
$manifestPath = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.json"
$sidecarPath  = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.sha256"

Write-Host '=== Akashic Self-Integrity Check ==='
Write-Host ''

# --- No manifest ---
if (-not (Test-Path $manifestPath)) {
    Write-Host '[FAIL] Manifest not found'
    $result = [ordered]@{
        schema_version       = 'akashic-self-integrity-evidence.v1'
        timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
        akashic_root         = $AkashicRoot
        verdict              = 'NO_MANIFEST'
        signature_status     = 'SIGNATURE_NOT_IMPLEMENTED'
        sidecar_valid        = $false
        manifest_hash        = $null
        file_results         = @()
        unmanifested_files   = @()
        classification_audit = [ordered]@{
            protected_manifested_count   = 0
            protected_unmanifested_count = 0
            mutable_present_count        = 0
            ignored_present_count        = 0
            unknown_unclassified_count   = 0
            unknown_unclassified_files   = @()
        }
        allow_unclassified   = [bool]$AllowUnclassified
        protected_file_count = 0
        clean_count          = 0
        drift_count          = 0
        missing_count        = 0
    }
    if ($EvidenceOutputDir) {
        if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
        $evPath = Join-Path $EvidenceOutputDir 'akashic-self-integrity-evidence.json'
        [System.IO.File]::WriteAllText($evPath, ($result | ConvertTo-Json -Depth 10), $Utf8NoBom)
    }
    return $result
}

# --- Sidecar check ---
$hasSidecarIssue = $false
$hasBomIssue = $false
$sidecarValid = $false
$manifestHash = $null

$manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$manifestHash = ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''

$bomCheck = [ordered]@{ manifest_bom_free = $true; sidecar_bom_free = $true }
if ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF) {
    $bomCheck.manifest_bom_free = $false
    $hasBomIssue = $true
}

if (-not (Test-Path $sidecarPath)) {
    Write-Host '[FAIL] Sidecar not found'
    $hasSidecarIssue = $true
} else {
    $sidecarRaw = [System.IO.File]::ReadAllBytes($sidecarPath)
    if ($sidecarRaw.Length -ge 3 -and $sidecarRaw[0] -eq 0xEF -and $sidecarRaw[1] -eq 0xBB -and $sidecarRaw[2] -eq 0xBF) {
        $bomCheck.sidecar_bom_free = $false
        $hasBomIssue = $true
    }
    $sidecarHash = [System.Text.Encoding]::UTF8.GetString($sidecarRaw).Trim()
    if ($sidecarHash -eq $manifestHash) {
        $sidecarValid = $true
        Write-Host '[PASS] Sidecar matches manifest hash'
    } else {
        Write-Host '[FAIL] Sidecar mismatch'
        $hasSidecarIssue = $true
    }
}

# --- Parse manifest ---
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$sigStatus = $manifest.signature_status
if (-not $sigStatus) { $sigStatus = 'SIGNATURE_NOT_IMPLEMENTED' }
Write-Host "[INFO] Signature status: $sigStatus"

# --- File-by-file verification ---
$fileResults = @()
$cleanCount = 0
$driftCount = 0
$missingCount = 0
$hasFileDrift = $false

$manifestedPaths = @{}

foreach ($entry in $manifest.protected.files) {
    $relPath = $entry.path
    $manifestedPaths[$relPath] = $true
    $fullPath = Join-Path $AkashicRoot ($relPath -replace '/', $sep)

    $fr = [ordered]@{
        path            = $relPath
        role            = $entry.role
        expected_sha256 = $entry.sha256
        actual_sha256   = $null
        expected_size   = $entry.size
        actual_size     = $null
        exists          = $false
        status          = 'CLEAN'
    }

    if (-not (Test-Path $fullPath)) {
        $fr.status = 'MISSING'
        $fr.exists = $false
        $missingCount++
        $hasFileDrift = $true
        Write-Host "[FAIL] MISSING: $relPath"
    } else {
        $fr.exists = $true
        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $fr.actual_sha256 = ($sha.ComputeHash($fileBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $fr.actual_size = $fileBytes.Length

        if ($fr.actual_sha256 -ne $entry.sha256) {
            $fr.status = 'HASH_MISMATCH'
            $driftCount++
            $hasFileDrift = $true
            Write-Host "[FAIL] HASH_MISMATCH: $relPath"
        } elseif ($fr.actual_size -ne $entry.size) {
            $fr.status = 'SIZE_MISMATCH'
            $driftCount++
            $hasFileDrift = $true
            Write-Host "[FAIL] SIZE_MISMATCH: $relPath"
        } else {
            $cleanCount++
            Write-Host "[PASS] $relPath"
        }
    }

    $fileResults += $fr
}

# --- Classification audit: walk entire repo ---
Write-Host ''
Write-Host '=== Classification Audit ==='

$classAudit = [ordered]@{
    protected_manifested   = @()
    protected_unmanifested = @()
    mutable_present        = @()
    ignored_present        = @()
    unknown_unclassified   = @()
}

$repoFiles = @()
$topItems = Get-ChildItem -Path $AkashicRoot -Force
foreach ($item in $topItems) {
    if ($item.PSIsContainer) {
        if ($item.Name -eq '.git') { continue }
        $subFiles = Get-ChildItem -Path $item.FullName -File -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($sf in $subFiles) { $repoFiles += $sf }
    } else {
        $repoFiles += $item
    }
}

foreach ($f in $repoFiles) {
    $relPath = $f.FullName.Substring($AkashicRoot.Length + 1).Replace('\', '/')
    $class = Get-AkashicFileClassification $relPath

    switch ($class) {
        'protected' {
            if ($manifestedPaths.ContainsKey($relPath) -or
                $relPath -eq 'manifest/akashic-envelope.json' -or
                $relPath -eq 'manifest/akashic-envelope.sha256') {
                $classAudit.protected_manifested += $relPath
            } else {
                $classAudit.protected_unmanifested += $relPath
                Write-Host "[WARN] PROTECTED_UNMANIFESTED: $relPath"
            }
        }
        'mutable' {
            $classAudit.mutable_present += $relPath
        }
        'ignored' {
            $classAudit.ignored_present += $relPath
        }
        'unknown' {
            $classAudit.unknown_unclassified += $relPath
            Write-Host "[WARN] UNCLASSIFIED: $relPath"
        }
    }
}

$hasUnmanifested = $classAudit.protected_unmanifested.Count -gt 0
$hasUnclassified = $classAudit.unknown_unclassified.Count -gt 0

# --- Determine verdict (most severe wins) ---
if ($hasSidecarIssue) {
    $verdict = 'SIDECAR_MISMATCH'
} elseif ($hasBomIssue -or $hasFileDrift -or $hasUnmanifested) {
    $verdict = 'DRIFT'
} elseif ($hasUnclassified -and -not $AllowUnclassified) {
    $verdict = 'UNCLASSIFIED_FILES_FOUND'
} else {
    $verdict = 'CLEAN'
}

Write-Host ''
Write-Host "Verdict: $verdict"
Write-Host "  Protected manifested:   $($classAudit.protected_manifested.Count)"
Write-Host "  Protected unmanifested: $($classAudit.protected_unmanifested.Count)"
Write-Host "  Mutable present:        $($classAudit.mutable_present.Count)"
Write-Host "  Ignored present:        $($classAudit.ignored_present.Count)"
Write-Host "  Unknown unclassified:   $($classAudit.unknown_unclassified.Count)"
Write-Host "  File integrity:"
Write-Host "    Clean:   $cleanCount"
Write-Host "    Drift:   $driftCount"
Write-Host "    Missing: $missingCount"

$result = [ordered]@{
    schema_version       = 'akashic-self-integrity-evidence.v1'
    timestamp_utc        = (Get-Date).ToUniversalTime().ToString('o')
    akashic_root         = $AkashicRoot
    verdict              = $verdict
    signature_status     = $sigStatus
    sidecar_valid        = $sidecarValid
    manifest_hash        = $manifestHash
    bom_check            = $bomCheck
    file_results         = $fileResults
    unmanifested_files   = [string[]]$classAudit.protected_unmanifested
    classification_audit = [ordered]@{
        protected_manifested_count   = $classAudit.protected_manifested.Count
        protected_unmanifested_count = $classAudit.protected_unmanifested.Count
        mutable_present_count        = $classAudit.mutable_present.Count
        ignored_present_count        = $classAudit.ignored_present.Count
        unknown_unclassified_count   = $classAudit.unknown_unclassified.Count
        unknown_unclassified_files   = [string[]]$classAudit.unknown_unclassified
    }
    allow_unclassified   = [bool]$AllowUnclassified
    protected_file_count = $fileResults.Count
    clean_count          = $cleanCount
    drift_count          = $driftCount
    missing_count        = $missingCount
}

if ($EvidenceOutputDir) {
    if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
    $evPath = Join-Path $EvidenceOutputDir 'akashic-self-integrity-evidence.json'
    [System.IO.File]::WriteAllText($evPath, ($result | ConvertTo-Json -Depth 10), $Utf8NoBom)
    Write-Host "Evidence: $evPath"
}

return $result
