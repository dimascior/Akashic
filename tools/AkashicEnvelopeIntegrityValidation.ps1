# AkashicEnvelopeIntegrityValidation.ps1 — Verify Helios envelope integrity
# Checks sidecar, manifest hashes, and optionally session baseline.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$SessionId
)

$ErrorActionPreference = 'Stop'

$sha = [System.Security.Cryptography.SHA256]::Create()

$manifestPath = Join-Path $HeliosGateRoot 'manifest\helios-envelope.json'
$sidecarPath  = Join-Path $HeliosGateRoot 'manifest\helios-envelope.sha256'

if (-not (Test-Path $manifestPath)) {
    $result = @{ verdict = 'DRIFT'; reason = 'Manifest not found'; details = @() }
    $result | ConvertTo-Json -Depth 3
    return $result
}
if (-not (Test-Path $sidecarPath)) {
    $result = @{ verdict = 'DRIFT'; reason = 'Sidecar not found'; details = @() }
    $result | ConvertTo-Json -Depth 3
    return $result
}

$manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$computedManifestHash = ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$sidecarHash = (Get-Content -LiteralPath $sidecarPath -Raw).Trim()

if ($computedManifestHash -ne $sidecarHash) {
    $result = @{
        verdict = 'DRIFT'
        reason  = 'Sidecar hash does not match computed manifest hash'
        details = @(@{
            check    = 'sidecar'
            expected = $sidecarHash
            actual   = $computedManifestHash
        })
    }
    $result | ConvertTo-Json -Depth 3
    return $result
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$details = @()
$verdict = 'CLEAN'

foreach ($prop in $manifest.protected.hashes.PSObject.Properties) {
    $relPath  = $prop.Name
    $expected = $prop.Value
    $fullPath = Join-Path $HeliosGateRoot ($relPath -replace '/', '\')

    $detail = @{
        path     = $relPath
        expected = $expected
        actual   = $null
        exists   = $false
        status   = 'CLEAN'
    }

    if (-not (Test-Path $fullPath)) {
        $detail.status = 'MISSING'
        $verdict = 'DRIFT'
    } else {
        $detail.exists = $true
        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $detail.actual = ($sha.ComputeHash($fileBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($detail.actual -ne $expected) {
            $detail.status = 'HASH_MISMATCH'
            $verdict = 'DRIFT'
        }
    }

    $details += $detail
}

$baselineCheck = $null
if ($SessionId) {
    $baselinePath = Join-Path $HeliosGateRoot "evidence\integrity\sessions\$SessionId\baseline.json"
    if (Test-Path $baselinePath) {
        $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        $baselineDetails = @()
        foreach ($prop in $baseline.protected_hashes.PSObject.Properties) {
            $relPath = $prop.Name
            $baselineHash = $prop.Value
            $fullPath = Join-Path $HeliosGateRoot ($relPath -replace '/', '\')
            $bDetail = @{
                path              = $relPath
                expected_baseline = $baselineHash
                actual            = $null
                status            = 'CLEAN'
            }
            if (Test-Path $fullPath) {
                $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
                $bDetail.actual = ($sha.ComputeHash($fileBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
                if ($bDetail.actual -ne $baselineHash) {
                    $bDetail.status = 'BASELINE_DRIFT'
                    $verdict = 'DRIFT'
                }
            } else {
                $bDetail.status = 'MISSING'
                $verdict = 'DRIFT'
            }
            $baselineDetails += $bDetail
        }
        $baselineCheck = @{
            session_id = $SessionId
            baseline_path = $baselinePath
            details = $baselineDetails
        }
    } else {
        $baselineCheck = @{
            session_id = $SessionId
            baseline_path = $baselinePath
            details = @()
            note = 'Baseline not found for session'
        }
    }
}

$bomCheck = @{ manifest_bom_free = $true; sidecar_bom_free = $true }
$manifestRaw = [System.IO.File]::ReadAllBytes($manifestPath)
if ($manifestRaw.Length -ge 3 -and $manifestRaw[0] -eq 0xEF -and $manifestRaw[1] -eq 0xBB -and $manifestRaw[2] -eq 0xBF) {
    $bomCheck.manifest_bom_free = $false
    $verdict = 'DRIFT'
}
$sidecarRaw = [System.IO.File]::ReadAllBytes($sidecarPath)
if ($sidecarRaw.Length -ge 3 -and $sidecarRaw[0] -eq 0xEF -and $sidecarRaw[1] -eq 0xBB -and $sidecarRaw[2] -eq 0xBF) {
    $bomCheck.sidecar_bom_free = $false
    $verdict = 'DRIFT'
}

$result = @{
    timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
    verdict        = $verdict
    sidecar_valid  = $true
    manifest_hash  = $computedManifestHash
    bom_check      = $bomCheck
    file_details   = $details
}

if ($baselineCheck) {
    $result['baseline_check'] = $baselineCheck
}

$result | ConvertTo-Json -Depth 4
return $result
