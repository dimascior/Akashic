# Verify Helios envelope integrity.
# Checks sidecar, manifest hashes, and optionally session baseline.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GateRoot,

    [string]$SessionId
)

$ErrorActionPreference = 'Stop'

$sha = [System.Security.Cryptography.SHA256]::Create()

$manifestPath = Join-Path $GateRoot 'manifest\helios-envelope.json'
$sidecarPath  = Join-Path $GateRoot 'manifest\helios-envelope.sha256'

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
    $fullPath = Join-Path $GateRoot ($relPath -replace '/', '\')

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
    $baselinePath = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\baseline.json"
    if (Test-Path $baselinePath) {
        $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
        $baselineDetails = @()
        foreach ($prop in $baseline.protected_hashes.PSObject.Properties) {
            $relPath = $prop.Name
            $baselineHash = $prop.Value
            $fullPath = Join-Path $GateRoot ($relPath -replace '/', '\')
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

$result = @{
    timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
    verdict        = $verdict
    sidecar_valid  = $true
    manifest_hash  = $computedManifestHash
    file_details   = $details
}

if ($baselineCheck) {
    $result['baseline_check'] = $baselineCheck
}

$result | ConvertTo-Json -Depth 4
return $result
