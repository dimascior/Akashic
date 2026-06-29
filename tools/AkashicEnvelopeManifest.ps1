# AkashicEnvelopeManifest.ps1 — Rebaseline the Helios durable manifest
# Computes SHA256 hashes for all protected files, writes helios-envelope.json
# and the helios-envelope.sha256 sidecar.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [string]$RebaselinedBy,

    [string]$Note
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

$protectedFiles = @(
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'hooks/helios_pretooluse.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1',
    'policy/command-policy.json'
)

$protectedPaths = @(
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'hooks/helios_pretooluse.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1',
    'policy/command-policy.json',
    'manifest/helios-envelope.json',
    'manifest/helios-envelope.sha256'
)

$sha = [System.Security.Cryptography.SHA256]::Create()
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$hashes = @{}
foreach ($relPath in $protectedFiles) {
    $fullPath = Join-Path $HeliosGateRoot ($relPath -replace '/', '\')
    if (-not (Test-Path $fullPath)) {
        throw "Protected file not found: $fullPath"
    }
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $hashes[$relPath] = $hash
}

$manifest = [ordered]@{
    schema_version = 'helios-envelope.v1'
    created_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    rebaselined_by = $RebaselinedBy
    protected      = [ordered]@{
        description = 'Must not change during gated execution'
        paths       = $protectedPaths
        hashes      = [ordered]@{}
    }
    mutable        = [ordered]@{
        description = 'Must change as part of gate lifecycle'
        dirs        = @('pending/', 'inflight/', 'evidence/', 'blocked/')
    }
}

if ($Note) {
    $manifest['note'] = $Note
}

foreach ($relPath in $protectedFiles) {
    $manifest.protected.hashes[$relPath] = $hashes[$relPath]
}

$manifestDir = Join-Path $HeliosGateRoot 'manifest'
if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
}

$manifestPath = Join-Path $manifestDir 'helios-envelope.json'
$manifestJson = $manifest | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $Utf8NoBom)

$manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$manifestHash = ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''

$sidecarPath = Join-Path $manifestDir 'helios-envelope.sha256'
[System.IO.File]::WriteAllText($sidecarPath, $manifestHash, $Utf8NoBom)

$result = @{
    timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
    manifest_path    = $manifestPath
    sidecar_path     = $sidecarPath
    manifest_hash    = $manifestHash
    rebaselined_by   = $RebaselinedBy
    protected_hashes = $hashes
}

$result | ConvertTo-Json -Depth 3
return $result
