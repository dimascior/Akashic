# New-AkashicSelfManifest.ps1 - Generate the Akashic self-integrity manifest
# Creates akashic-envelope.json and akashic-envelope.sha256 in manifest/.
# Hash-only self-integrity detects drift. Signed or external authority is
# required to prevent rewriting both files and manifests.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$RebaselinedBy,

    [string]$Note
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha = [System.Security.Cryptography.SHA256]::Create()

function Get-Hash([string]$FilePath) {
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-Role([string]$RelPath) {
    if ($RelPath -eq 'AkashicIntegrityBridge.ps1') { return 'bridge' }
    if ($RelPath -like 'tools/lib/*') { return 'library' }
    if ($RelPath -like 'Tests/*') { return 'test' }
    if ($RelPath -like 'schemas/*') { return 'schema' }
    if ($RelPath -like 'docs/*') { return 'contract-doc' }
    if ($RelPath -like 'tools/New-Helios*' -or
        $RelPath -like 'tools/Test-Helios*' -or
        $RelPath -like 'tools/Sync-Helios*' -or
        $RelPath -like 'tools/Lock-Helios*' -or
        $RelPath -like 'tools/Unlock-Helios*' -or
        $RelPath -like 'tools/Invoke-Helios*' -or
        $RelPath -like 'tools/Move-Helios*' -or
        $RelPath -like 'tools/Get-Helios*' -or
        $RelPath -like 'tools/Clear-Helios*') {
        return 'compatibility-wrapper'
    }
    return 'tool'
}

$protectedPatterns = @(
    @{ Dir = ''; Pattern = 'AkashicIntegrityBridge.ps1' },
    @{ Dir = 'tools'; Pattern = '*.ps1' },
    @{ Dir = 'tools/lib'; Pattern = '*.ps1' },
    @{ Dir = 'schemas'; Pattern = '*.json' },
    @{ Dir = 'docs'; Pattern = '*.md' },
    @{ Dir = 'Tests'; Pattern = '*.ps1' }
)

$sep = [System.IO.Path]::DirectorySeparatorChar
$files = @()

foreach ($p in $protectedPatterns) {
    $searchDir = if ($p.Dir) { Join-Path $AkashicRoot ($p.Dir -replace '/', $sep) } else { $AkashicRoot }
    if (-not (Test-Path $searchDir)) { continue }
    $found = Get-ChildItem -Path $searchDir -Filter $p.Pattern -File
    foreach ($f in $found) {
        $relPath = $f.FullName.Substring($AkashicRoot.Length + 1).Replace('\', '/')
        $hash = Get-Hash $f.FullName
        $size = $f.Length
        $role = Get-Role $relPath
        $files += [ordered]@{
            path   = $relPath
            sha256 = $hash
            size   = [int]$size
            role   = $role
        }
    }
}

$files = @($files | Sort-Object { $_.path })

$allProtectedPaths = @($files | ForEach-Object { $_.path })
$allProtectedPaths += 'manifest/akashic-envelope.json'
$allProtectedPaths += 'manifest/akashic-envelope.sha256'
$allProtectedPaths = @($allProtectedPaths | Sort-Object)

$mutablePaths = @(
    'evidence/',
    'manifest/akashic-envelope.sig',
    'manifest/akashic-public-key.asc'
)

$manifest = [ordered]@{
    schema_version   = 'akashic-self-envelope.v1'
    created_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    rebaselined_by   = $RebaselinedBy
    signature_status = 'SIGNATURE_NOT_IMPLEMENTED'
    protected        = [ordered]@{
        description = 'Akashic installer, integrity adapter, and activation tooling files. Must not change outside of explicit human rebaseline.'
        paths       = $allProtectedPaths
        files       = $files
    }
    mutable          = [ordered]@{
        description = 'Paths that change during normal Akashic operation.'
        paths       = $mutablePaths
    }
}

if ($Note) { $manifest['note'] = $Note }

$manifestDir = Join-Path $AkashicRoot 'manifest'
if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
}

$manifestPath = Join-Path $manifestDir 'akashic-envelope.json'
$manifestJson = $manifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $Utf8NoBom)

$manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
$manifestHash = ($sha.ComputeHash($manifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''

$sidecarPath = Join-Path $manifestDir 'akashic-envelope.sha256'
[System.IO.File]::WriteAllText($sidecarPath, $manifestHash, $Utf8NoBom)

Write-Host "Akashic self-manifest created."
Write-Host "  Manifest:  $manifestPath"
Write-Host "  Sidecar:   $sidecarPath"
Write-Host "  Hash:      $manifestHash"
Write-Host "  Protected: $($files.Count) files"
Write-Host "  Signature: SIGNATURE_NOT_IMPLEMENTED"

return [ordered]@{
    manifest_path    = $manifestPath
    sidecar_path     = $sidecarPath
    manifest_hash    = $manifestHash
    protected_count  = $files.Count
    signature_status = 'SIGNATURE_NOT_IMPLEMENTED'
    rebaselined_by   = $RebaselinedBy
}
