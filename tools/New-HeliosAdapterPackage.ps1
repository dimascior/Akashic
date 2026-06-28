# New-HeliosAdapterPackage.ps1 — Build a distributable TCE Helios adapter package
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TceRoot,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [Parameter(Mandatory)]
    [string]$Version,

    [string]$SourceBranch = 'helios-integrity-adapter',

    [string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$AdapterRoot = Join-Path $TceRoot 'MyExporter\Adapters\Helios'
if (-not (Test-Path $AdapterRoot)) {
    throw "Adapter root not found: $AdapterRoot"
}

if (-not $SourceCommit) {
    try {
        $SourceCommit = (git -C $TceRoot rev-parse HEAD 2>&1).Trim()
    } catch {
        $SourceCommit = 'unknown'
    }
}

$PackageName = "helios-tce-adapter-v$Version"
$PackageDir = Join-Path $OutputDir $PackageName
if (Test-Path $PackageDir) {
    Remove-Item $PackageDir -Recurse -Force
}
New-Item -ItemType Directory -Path $PackageDir -Force | Out-Null

$AdapterFiles = @(
    @{ Source = 'HeliosIntegrityBridge.ps1'; Role = 'bridge_source'; Required = $true }
    @{ Source = 'README.md'; Role = 'readme'; Required = $true }
    @{ Source = 'docs\tce-helios-integrity-adapter-spec.md'; Role = 'doc'; Required = $true }
    @{ Source = 'docs\phase4-lock-requirements-from-gap-tests.md'; Role = 'doc'; Required = $true }
    @{ Source = 'docs\package-architecture.md'; Role = 'doc'; Required = $true }
    @{ Source = 'docs\package-options.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\install-sequence.md'; Role = 'doc'; Required = $true }
    @{ Source = 'docs\package-manifest-schema.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\phase398-packaging-decision.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\helios-runtime-bundle-contract.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\phase399-operational-enforcement-observations.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\phase3991-package-validation-results.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\phase40-lock-design-from-gap-evidence.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\phase41-lock-implementation.md'; Role = 'doc'; Required = $false }
    @{ Source = 'docs\standalone-repo-transition.md'; Role = 'doc'; Required = $false }
    @{ Source = 'schemas\helios-envelope.schema.json'; Role = 'schema'; Required = $true }
    @{ Source = 'schemas\helios-baseline.schema.json'; Role = 'schema'; Required = $true }
    @{ Source = 'schemas\helios-command-evidence.schema.json'; Role = 'schema'; Required = $true }
    @{ Source = 'schemas\helios-rebaseline.schema.json'; Role = 'schema'; Required = $false }
    @{ Source = 'tools\Sync-HeliosBridge.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\New-HeliosEnvelopeManifest.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\Test-HeliosEnvelopeIntegrity.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\Invoke-HeliosGapTest.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\ConvertFrom-HeliosEvidence.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\New-HeliosGapTestMatrix.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\New-HeliosAdapterPackage.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\Test-HeliosAdapterPackage.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\New-HeliosInstallPlan.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\New-HeliosRuntimeBundle.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\Test-HeliosRuntimeBundle.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\New-HeliosCombinedInstallPlan.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\Test-HeliosEndToEndInstallPlan.ps1'; Role = 'tool'; Required = $true }
    @{ Source = 'tools\Lock-HeliosProtectedFiles.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\Unlock-HeliosProtectedFiles.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\Test-HeliosLockStatus.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\Invoke-HeliosRebaseline.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\Move-HeliosStaleGateArtifacts.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'tools\Test-HeliosSettingsIntegrity.ps1'; Role = 'tool'; Required = $false }
    @{ Source = 'Tests\HeliosIntegrityBridge.Tests.ps1'; Role = 'test'; Required = $false }
)

$sha = [System.Security.Cryptography.SHA256]::Create()
$FileEntries = @()
$FileHashes = @{}
$ChecksumLines = @()
$CopiedCount = 0
$SkippedCount = 0

foreach ($entry in $AdapterFiles) {
    $sourcePath = Join-Path $AdapterRoot $entry.Source
    if (-not (Test-Path $sourcePath)) {
        if ($entry.Required) {
            throw "Required file not found: $sourcePath"
        }
        $SkippedCount++
        continue
    }

    $destPath = Join-Path $PackageDir $entry.Source
    $destDir = Split-Path $destPath -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force

    $bytes = [System.IO.File]::ReadAllBytes($destPath)
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $FileHashes[$entry.Source] = $hash
    $ChecksumLines += "$hash  $($entry.Source)"
    $FileEntries += @{
        path     = $entry.Source
        role     = $entry.Role
        required = $entry.Required
    }
    $CopiedCount++
}

$GapTestDir = Join-Path $AdapterRoot 'evidence\gap-tests'
if (Test-Path $GapTestDir) {
    $GapTestFiles = Get-ChildItem -Path $GapTestDir -Recurse -File
    foreach ($f in $GapTestFiles) {
        $relPath = $f.FullName.Substring($AdapterRoot.Length + 1)
        $destPath = Join-Path $PackageDir $relPath
        $destDir = Split-Path $destPath -Parent
        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force

        $bytes = [System.IO.File]::ReadAllBytes($destPath)
        $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $FileHashes[$relPath] = $hash
        $ChecksumLines += "$hash  $relPath"
        $FileEntries += @{
            path     = $relPath
            role     = 'evidence'
            required = $false
        }
        $CopiedCount++
    }
}

$Manifest = [ordered]@{
    schema_version              = 'helios-adapter-package.v1'
    package_name                = 'helios-tce-adapter'
    package_version             = $Version
    source_repo                 = 'TerminalContextExporter'
    source_branch               = $SourceBranch
    source_commit               = $SourceCommit
    build_timestamp_utc         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    files                       = $FileEntries
    file_hashes                 = $FileHashes
    required_helios_version     = '3.96+'
    required_tce_adapter_version = $Version
    supported_platforms         = @('windows', 'linux', 'macos')
    installer_entrypoints       = [ordered]@{
        package_verify  = 'tools/Test-HeliosAdapterPackage.ps1'
        bridge_sync     = 'tools/Sync-HeliosBridge.ps1'
        manifest_create = 'tools/New-HeliosEnvelopeManifest.ps1'
        integrity_verify = 'tools/Test-HeliosEnvelopeIntegrity.ps1'
        install_plan    = 'tools/New-HeliosInstallPlan.ps1'
    }
    smoke_tests                 = @(
        @{ name = 'no_gate_deny'; description = 'Shell command without matching gate should be denied'; expected_verdict = 'DENY' }
        @{ name = 'valid_gate_allow'; description = 'Shell command with valid matching gate should be allowed'; expected_verdict = 'ALLOW'; expected_evidence = @('before.json', 'decision.json', 'after.json', 'compare.json') }
    )
    trust_boundaries            = [ordered]@{
        bridge_source_of_truth = 'TCE adapter branch'
        bridge_vendor_copy     = 'Helios hooks/lib/HeliosIntegrityBridge.ps1'
        manifest_authority     = 'Generated locally on target machine'
        settings_activation    = 'Requires explicit human approval'
        package_integrity      = 'checksums.sha256 in package root'
    }
}

$ManifestPath = Join-Path $PackageDir 'package-manifest.json'
$ManifestJson = $Manifest | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($ManifestPath, $ManifestJson, $Utf8NoBom)

$ManifestBytes = [System.IO.File]::ReadAllBytes($ManifestPath)
$ManifestHash = ($sha.ComputeHash($ManifestBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$ChecksumLines += "$ManifestHash  package-manifest.json"

$ChecksumsPath = Join-Path $PackageDir 'checksums.sha256'
$ChecksumsContent = ($ChecksumLines | Sort-Object) -join "`n"
[System.IO.File]::WriteAllText($ChecksumsPath, $ChecksumsContent, $Utf8NoBom)

$Result = @{
    timestamp_utc   = (Get-Date).ToUniversalTime().ToString('o')
    package_name    = $PackageName
    package_dir     = $PackageDir
    manifest_path   = $ManifestPath
    checksums_path  = $ChecksumsPath
    source_branch   = $SourceBranch
    source_commit   = $SourceCommit
    version         = $Version
    files_copied    = $CopiedCount
    files_skipped   = $SkippedCount
    manifest_hash   = $ManifestHash
}

Write-Host "Package built: $PackageName ($CopiedCount files) at $PackageDir"
$Result | ConvertTo-Json -Depth 3
return $Result
