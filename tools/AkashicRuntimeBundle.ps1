# AkashicRuntimeBundle.ps1 — Build a distributable Helios runtime bundle
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosRepoRoot,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [Parameter(Mandatory)]
    [string]$Version,

    [string]$SourceBranch,

    [string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$GateRoot = Join-Path $HeliosRepoRoot '.command-gate'
if (-not (Test-Path $GateRoot)) {
    throw "Helios gate root not found: $GateRoot"
}

if (-not $SourceBranch) {
    try {
        $SourceBranch = (git -C $HeliosRepoRoot rev-parse --abbrev-ref HEAD 2>&1).Trim()
    } catch {
        $SourceBranch = 'unknown'
    }
}

if (-not $SourceCommit) {
    try {
        $SourceCommit = (git -C $HeliosRepoRoot rev-parse HEAD 2>&1).Trim()
    } catch {
        $SourceCommit = 'unknown'
    }
}

$BundleName = "helios-runtime-v$Version"
$BundleDir = Join-Path $OutputDir $BundleName
if (Test-Path $BundleDir) {
    Remove-Item $BundleDir -Recurse -Force
}
New-Item -ItemType Directory -Path $BundleDir -Force | Out-Null

$ProtectedFiles = @(
    'hooks\helios_pretooluse.ps1',
    'hooks\gate_check.ps1',
    'hooks\evidence_capture.ps1',
    'hooks\tier_classifier.ps1',
    'policy\command-policy.json'
)

$SupportDirs = @(
    @{ Source = 'schemas'; Pattern = '*.json' }
    @{ Source = 'tools'; Pattern = '*.ps1' }
    @{ Source = 'docs'; Pattern = '*.md' }
    @{ Source = 'tests'; Pattern = '*.ps1' }
)

$MutableDirs = @('pending', 'inflight', 'evidence', 'blocked')
$ScaffoldDirs = @('hooks\lib', 'templates', 'maintenance', 'manifest')

$sha = [System.Security.Cryptography.SHA256]::Create()
$FileHashes = @{}
$ChecksumLines = @()
$FileEntries = @()
$CopiedCount = 0

function Add-TrackedFile {
    param([string]$Path, [string]$RelPath, [string]$Role, [bool]$Required)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $script:FileHashes[$RelPath] = $hash
    $script:ChecksumLines += "$hash  $RelPath"
    $script:FileEntries += @{ path = $RelPath; role = $Role; required = $Required }
}

foreach ($relPath in $ProtectedFiles) {
    $sourcePath = Join-Path $GateRoot $relPath
    if (-not (Test-Path $sourcePath)) {
        throw "Required protected file not found: $sourcePath"
    }
    $destPath = Join-Path $BundleDir $relPath
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
    Add-TrackedFile -Path $destPath -RelPath $relPath -Role 'protected' -Required $true
    $CopiedCount++
}

foreach ($sd in $SupportDirs) {
    $sourceDir = Join-Path $GateRoot $sd.Source
    if (-not (Test-Path $sourceDir)) { continue }
    $files = @(Get-ChildItem -Path $sourceDir -Filter $sd.Pattern -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $relPath = "$($sd.Source)\$($f.Name)"
        $destPath = Join-Path $BundleDir $relPath
        $destDir = Split-Path $destPath -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force
        Add-TrackedFile -Path $destPath -RelPath $relPath -Role 'support' -Required $false
        $CopiedCount++
    }
}

foreach ($dir in $MutableDirs) {
    $path = Join-Path $BundleDir $dir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $gitkeep = Join-Path $path '.gitkeep'
    [System.IO.File]::WriteAllText($gitkeep, '', $Utf8NoBom)
    $relPath = "$dir\.gitkeep"
    Add-TrackedFile -Path $gitkeep -RelPath $relPath -Role 'mutable_scaffold' -Required $true
}

foreach ($dir in $ScaffoldDirs) {
    $path = Join-Path $BundleDir $dir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$templateGitkeep = Join-Path $BundleDir 'templates\.gitkeep'
if (-not (Test-Path $templateGitkeep)) {
    [System.IO.File]::WriteAllText($templateGitkeep, '', $Utf8NoBom)
}
Add-TrackedFile -Path $templateGitkeep -RelPath 'templates\.gitkeep' -Role 'mutable_scaffold' -Required $true

$Manifest = [ordered]@{
    schema_version      = 'helios-runtime-bundle.v1'
    package_name        = 'helios-runtime'
    package_version     = $Version
    source_repo         = 'MythosJustAFable'
    source_branch       = $SourceBranch
    source_commit       = $SourceCommit
    build_timestamp_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    files               = $FileEntries
    file_hashes         = $FileHashes
    protected_files     = $ProtectedFiles
    mutable_dirs        = $MutableDirs
    excluded            = @(
        'pending/*.gate.json', 'inflight/*.gate.json',
        'evidence/integrity/sessions/', 'evidence/*.result.json',
        'evidence/*.tool_response.json', 'evidence/stale/',
        'evidence/maintenance/', 'evidence/install-evidence.json',
        'blocked/*.json', 'hooks/lib/HeliosIntegrityBridge.ps1',
        'manifest/helios-envelope.json', 'manifest/helios-envelope.sha256'
    )
    adapter_source      = [ordered]@{
        repo   = 'dimascior/Akashic'
        note   = 'Bridge and adapter tools are sourced from the Akashic repo, not this bundle.'
    }
    notes               = @(
        'Bridge is installed from the Akashic adapter package, not bundled.',
        'Manifest and sidecar are generated locally during install.',
        'Mutable directories contain .gitkeep only.',
        'Runtime source is the Helios repo; adapter source is the Akashic repo.'
    )
}

$ManifestPath = Join-Path $BundleDir 'runtime-manifest.json'
$ManifestJson = $Manifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ManifestPath, $ManifestJson, $Utf8NoBom)

$ManifestBytes = [System.IO.File]::ReadAllBytes($ManifestPath)
$ManifestHash = ($sha.ComputeHash($ManifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$ChecksumLines += "$ManifestHash  runtime-manifest.json"

$ChecksumsPath = Join-Path $BundleDir 'runtime-checksums.sha256'
$ChecksumsContent = ($ChecksumLines | Sort-Object) -join "`n"
[System.IO.File]::WriteAllText($ChecksumsPath, $ChecksumsContent, $Utf8NoBom)

$Result = @{
    timestamp_utc   = (Get-Date).ToUniversalTime().ToString('o')
    bundle_name     = $BundleName
    bundle_dir      = $BundleDir
    manifest_path   = $ManifestPath
    checksums_path  = $ChecksumsPath
    source_branch   = $SourceBranch
    source_commit   = $SourceCommit
    version         = $Version
    files_copied    = $CopiedCount
    manifest_hash   = $ManifestHash
}

Write-Host "Runtime bundle built: $BundleName ($CopiedCount files) at $BundleDir"
$Result | ConvertTo-Json -Depth 3
return $Result
