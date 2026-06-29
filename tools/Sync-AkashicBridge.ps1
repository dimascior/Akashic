# Sync-AkashicBridge.ps1 — Copy Akashic source bridge to Helios vendored location
# Akashic owns the source bridge. Helios consumes the vendored copy.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AdapterRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot
)

$ErrorActionPreference = 'Stop'

& (Join-Path $PSScriptRoot 'Assert-AkashicTrusted.ps1')

$SourcePath = Join-Path $AdapterRoot 'AkashicIntegrityBridge.ps1'
$DestPath   = Join-Path $HeliosGateRoot 'hooks\lib\HeliosIntegrityBridge.ps1'

if (-not (Test-Path $SourcePath)) {
    throw "Source bridge not found: $SourcePath"
}

$destDir = Split-Path $DestPath -Parent
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}

Copy-Item -LiteralPath $SourcePath -Destination $DestPath -Force

$sourceBytes = [System.IO.File]::ReadAllBytes($SourcePath)
$destBytes   = [System.IO.File]::ReadAllBytes($DestPath)

$sha = [System.Security.Cryptography.SHA256]::Create()
$sourceHash = ($sha.ComputeHash($sourceBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$destHash   = ($sha.ComputeHash($destBytes)   | ForEach-Object { $_.ToString('x2') }) -join ''

$byteIdentical = $sourceHash -eq $destHash

$result = @{
    timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
    source_path    = $SourcePath
    dest_path      = $DestPath
    source_hash    = $sourceHash
    dest_hash      = $destHash
    byte_identical = $byteIdentical
    source_size    = $sourceBytes.Length
    dest_size      = $destBytes.Length
}

if (-not $byteIdentical) {
    Write-Warning "Sync completed but files are NOT byte-identical. Source hash: $sourceHash, Dest hash: $destHash"
}

$result | ConvertTo-Json -Depth 3
return $result
