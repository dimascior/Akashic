# Test-AkashicSelfIntegrity.ps1 - Verify Akashic files against its self-manifest
# Checks: file drift, missing files, unmanifested protected-pattern files,
# sidecar mismatch, and unsigned manifest state.
# Hash-only self-integrity detects drift. Signed or external authority is
# required to prevent an agent from rewriting both files and manifests.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha = [System.Security.Cryptography.SHA256]::Create()

function Get-Hash([string]$FilePath) {
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

$sep = [System.IO.Path]::DirectorySeparatorChar
$manifestPath = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.json"
$sidecarPath  = Join-Path $AkashicRoot "manifest${sep}akashic-envelope.sha256"

Write-Host '=== Akashic Self-Integrity Check ==='
Write-Host ''

if (-not (Test-Path $manifestPath)) {
    Write-Host '[FAIL] Manifest not found'
    $result = [ordered]@{
        schema_version     = 'akashic-self-integrity-evidence.v1'
        timestamp_utc      = (Get-Date).ToUniversalTime().ToString('o')
        akashic_root       = $AkashicRoot
        verdict            = 'NO_MANIFEST'
        signature_status   = 'SIGNATURE_NOT_IMPLEMENTED'
        sidecar_valid      = $false
        manifest_hash      = $null
        file_results       = @()
        unmanifested_files = @()
        protected_file_count = 0
        clean_count        = 0
        drift_count        = 0
        missing_count      = 0
    }
    if ($EvidenceOutputDir) {
        if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
        $evPath = Join-Path $EvidenceOutputDir 'akashic-self-integrity-evidence.json'
        [System.IO.File]::WriteAllText($evPath, ($result | ConvertTo-Json -Depth 10), $Utf8NoBom)
    }
    return $result
}

# Sidecar check
$sidecarValid = $false
$manifestHash = $null
$verdict = 'CLEAN'

$manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$manifestHash = ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''

$bomCheck = [ordered]@{ manifest_bom_free = $true; sidecar_bom_free = $true }
if ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF) {
    $bomCheck.manifest_bom_free = $false
    $verdict = 'DRIFT'
}

if (-not (Test-Path $sidecarPath)) {
    Write-Host '[FAIL] Sidecar not found'
    $verdict = 'SIDECAR_MISMATCH'
} else {
    $sidecarRaw = [System.IO.File]::ReadAllBytes($sidecarPath)
    if ($sidecarRaw.Length -ge 3 -and $sidecarRaw[0] -eq 0xEF -and $sidecarRaw[1] -eq 0xBB -and $sidecarRaw[2] -eq 0xBF) {
        $bomCheck.sidecar_bom_free = $false
        $verdict = 'DRIFT'
    }
    $sidecarHash = [System.Text.Encoding]::UTF8.GetString($sidecarRaw).Trim()
    if ($sidecarHash -eq $manifestHash) {
        $sidecarValid = $true
        Write-Host '[PASS] Sidecar matches manifest hash'
    } else {
        Write-Host '[FAIL] Sidecar mismatch'
        $verdict = 'SIDECAR_MISMATCH'
    }
}

# Parse manifest
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

# Signature status
$sigStatus = $manifest.signature_status
if (-not $sigStatus) { $sigStatus = 'SIGNATURE_NOT_IMPLEMENTED' }
Write-Host "[INFO] Signature status: $sigStatus"

# File-by-file verification
$fileResults = @()
$cleanCount = 0
$driftCount = 0
$missingCount = 0

foreach ($entry in $manifest.protected.files) {
    $relPath = $entry.path
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
        $verdict = 'DRIFT'
        Write-Host "[FAIL] MISSING: $relPath"
    } else {
        $fr.exists = $true
        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $fr.actual_sha256 = ($sha.ComputeHash($fileBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $fr.actual_size = $fileBytes.Length

        if ($fr.actual_sha256 -ne $entry.sha256) {
            $fr.status = 'HASH_MISMATCH'
            $driftCount++
            $verdict = 'DRIFT'
            Write-Host "[FAIL] HASH_MISMATCH: $relPath"
        } elseif ($fr.actual_size -ne $entry.size) {
            $fr.status = 'SIZE_MISMATCH'
            $driftCount++
            $verdict = 'DRIFT'
            Write-Host "[FAIL] SIZE_MISMATCH: $relPath"
        } else {
            $cleanCount++
            Write-Host "[PASS] $relPath"
        }
    }

    $fileResults += $fr
}

# Scan for unmanifested files matching protected patterns
$protectedPatterns = @(
    @{ Dir = ''; Pattern = 'AkashicIntegrityBridge.ps1' },
    @{ Dir = 'tools'; Pattern = '*.ps1' },
    @{ Dir = 'tools/lib'; Pattern = '*.ps1' },
    @{ Dir = 'schemas'; Pattern = '*.json' },
    @{ Dir = 'docs'; Pattern = '*.md' },
    @{ Dir = 'Tests'; Pattern = '*.ps1' }
)

$manifestedPaths = @{}
foreach ($entry in $manifest.protected.files) {
    $manifestedPaths[$entry.path] = $true
}

$unmanifestedFiles = @()
foreach ($p in $protectedPatterns) {
    $searchDir = if ($p.Dir) { Join-Path $AkashicRoot ($p.Dir -replace '/', $sep) } else { $AkashicRoot }
    if (-not (Test-Path $searchDir)) { continue }
    $found = Get-ChildItem -Path $searchDir -Filter $p.Pattern -File
    foreach ($f in $found) {
        $relPath = $f.FullName.Substring($AkashicRoot.Length + 1).Replace('\', '/')
        if (-not $manifestedPaths.ContainsKey($relPath)) {
            $unmanifestedFiles += $relPath
            Write-Host "[WARN] UNMANIFESTED: $relPath"
        }
    }
}

if ($unmanifestedFiles.Count -gt 0) {
    $verdict = 'DRIFT'
}

Write-Host ''
Write-Host "Verdict: $verdict"
Write-Host "  Protected: $($fileResults.Count) files"
Write-Host "  Clean:     $cleanCount"
Write-Host "  Drift:     $driftCount"
Write-Host "  Missing:   $missingCount"
Write-Host "  Unmanifested: $($unmanifestedFiles.Count)"

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
    unmanifested_files   = [string[]]$unmanifestedFiles
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
