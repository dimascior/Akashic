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
$AkashicRoot = $AkashicRoot.TrimEnd('\', '/')
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha = [System.Security.Cryptography.SHA256]::Create()

$libDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'lib'
. (Join-Path $libDir 'AkashicCoveragePolicy.ps1')

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
    if ($RelPath -like '.github/workflows/*') { return 'ci-workflow' }
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
    if ($RelPath -like 'tools/*') { return 'tool' }
    $ext = [System.IO.Path]::GetExtension($RelPath).ToLower()
    if ($ext -in @('.psd1', '.psm1', '.ps1xml')) { return 'module' }
    if ($ext -in @('.sh', '.bash', '.zsh', '.bat', '.cmd', '.py')) { return 'script' }
    if ($ext -in @('.json', '.yml', '.yaml', '.toml', '.xml')) { return 'config' }
    if ($ext -eq '.md') { return 'contract-doc' }
    return 'tool'
}

$sep = [System.IO.Path]::DirectorySeparatorChar
$seen = @{}
$files = @()

foreach ($p in $script:AkashicProtectedDiscovery) {
    $searchDir = if ($p.Dir) { Join-Path $AkashicRoot ($p.Dir -replace '/', $sep) } else { $AkashicRoot }
    if (-not (Test-Path $searchDir)) { continue }

    $gcArgs = @{ Path = $searchDir; Filter = $p.Pattern; File = $true; Force = $true }
    if ($p.Recurse) { $gcArgs['Recurse'] = $true }

    $found = Get-ChildItem @gcArgs
    foreach ($f in $found) {
        $relPath = $f.FullName.Substring($AkashicRoot.Length + 1).Replace('\', '/')

        if ($seen.ContainsKey($relPath)) { continue }

        $class = Get-AkashicFileClassification $relPath
        if ($class -ne 'protected') { continue }

        $seen[$relPath] = $true
        $hash = Get-Hash $f.FullName
        $role = Get-Role $relPath
        $files += [ordered]@{
            path   = $relPath
            sha256 = $hash
            size   = [int]$f.Length
            role   = $role
        }
    }
}

$files = @($files | Sort-Object { $_.path })

$allProtectedPaths = @($files | ForEach-Object { $_.path })
$allProtectedPaths += 'manifest/akashic-envelope.json'
$allProtectedPaths += 'manifest/akashic-envelope.sha256'
$allProtectedPaths = @($allProtectedPaths | Sort-Object)

$manifest = [ordered]@{
    schema_version   = 'akashic-self-envelope.v1'
    created_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    rebaselined_by   = $RebaselinedBy
    signature_status = 'SIGNATURE_NOT_IMPLEMENTED'
    protected        = [ordered]@{
        description = 'Files that can alter Akashic behavior, trust, installation, verification, CI, schema interpretation, or documentation contracts. Must not change outside of explicit human rebaseline.'
        paths       = $allProtectedPaths
        files       = $files
    }
    mutable          = [ordered]@{
        description = 'Paths expected to change during normal Akashic operation.'
        paths       = [string[]]$script:AkashicMutablePatterns
    }
    ignored          = [ordered]@{
        description = 'Paths intentionally outside the trust boundary.'
        patterns    = [string[]]$script:AkashicIgnoredPatterns
    }
    classification   = [ordered]@{
        protected_file_count  = $files.Count
        mutable_pattern_count = $script:AkashicMutablePatterns.Count
        ignored_pattern_count = $script:AkashicIgnoredPatterns.Count
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

Write-Host 'Akashic self-manifest created.'
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
