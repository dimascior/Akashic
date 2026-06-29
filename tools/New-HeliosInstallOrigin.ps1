[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$RuntimeBundleRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [ValidateSet('Windows', 'macOS', 'Linux')]
    [string]$Platform,

    [ValidateSet('Prepare', 'Reset', 'Restore')]
    [string]$InstallMode = 'Prepare',

    [string]$InstalledBy = 'installer'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$sep = [System.IO.Path]::DirectorySeparatorChar

function Get-FileHash256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-GitHead([string]$Dir) {
    try {
        $prev = $PWD
        Set-Location $Dir
        $result = git rev-parse HEAD 2>$null
        Set-Location $prev
        if ($LASTEXITCODE -eq 0 -and $result) { return $result.Trim() }
    } catch {
        try { Set-Location $prev } catch {}
    }
    return $null
}

function Get-GitRepoRoot([string]$Dir) {
    try {
        $prev = $PWD
        Set-Location $Dir
        $result = git rev-parse --show-toplevel 2>$null
        Set-Location $prev
        if ($LASTEXITCODE -eq 0 -and $result) { return $result.Trim() }
    } catch {
        try { Set-Location $prev } catch {}
    }
    return $null
}

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath -and $Platform -eq 'Windows') {
    $pwshPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
}

$claudeSettingsPath = switch ($Platform) {
    'Windows' { Join-Path $env:USERPROFILE '.claude\settings.json' }
    default   { Join-Path $env:HOME '.claude/settings.json' }
}

$akashicHead = Get-GitHead $AkashicRoot
$heliosRepoRoot = Get-GitRepoRoot $RuntimeBundleRoot
$heliosHead = if ($heliosRepoRoot) { Get-GitHead $heliosRepoRoot } else { $null }

$runtimeProtectedSources = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'policy/command-policy.json'
)

$sourceHashes = [ordered]@{}
foreach ($rel in $runtimeProtectedSources) {
    $fullPath = Join-Path $RuntimeBundleRoot ($rel.Replace('/', $sep))
    if (Test-Path $fullPath) {
        $sourceHashes[$rel] = Get-FileHash256 $fullPath
    }
}

$installedProtectedPaths = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1',
    'policy/command-policy.json'
)

$installedHashes = [ordered]@{}
foreach ($rel in $installedProtectedPaths) {
    $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    if (Test-Path $fullPath) {
        $installedHashes[$rel] = Get-FileHash256 $fullPath
    }
}

$bridgeSource = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
$bridgeInstalled = Join-Path $HeliosGateRoot ('hooks\lib\HeliosIntegrityBridge.ps1'.Replace('\', $sep))
$bridgeSourceHash = if (Test-Path $bridgeSource) { Get-FileHash256 $bridgeSource } else { $null }
$bridgeInstalledHash = if (Test-Path $bridgeInstalled) { Get-FileHash256 $bridgeInstalled } else { $null }

$manifestPath = Join-Path $HeliosGateRoot ('manifest\helios-envelope.json'.Replace('\', $sep))
$sidecarPath = Join-Path $HeliosGateRoot ('manifest\helios-envelope.sha256'.Replace('\', $sep))
$manifestHash = if (Test-Path $manifestPath) { Get-FileHash256 $manifestPath } else { $null }
$sidecarValue = if (Test-Path $sidecarPath) { ([System.IO.File]::ReadAllText($sidecarPath, $Utf8NoBom)).Trim() } else { $null }

$installerToolPaths = @(
    'tools/Install-AkashicHeliosRuntime.ps1',
    'tools/AkashicHeliosInstallPlan.ps1',
    'tools/AkashicEnvelopeManifest.ps1',
    'tools/Sync-AkashicBridge.ps1',
    'tools/Assert-AkashicTrusted.ps1',
    'tools/New-HeliosInstallOrigin.ps1'
)
$installerHashes = [ordered]@{}
foreach ($rel in $installerToolPaths) {
    $fullPath = Join-Path $AkashicRoot ($rel.Replace('/', $sep))
    if (Test-Path $fullPath) {
        $installerHashes[$rel] = Get-FileHash256 $fullPath
    }
}

$originVerified = $true
foreach ($rel in $runtimeProtectedSources) {
    if ($sourceHashes.Contains($rel) -and $installedHashes.Contains($rel)) {
        if ($sourceHashes[$rel] -ne $installedHashes[$rel]) {
            $originVerified = $false
            Write-Host "  DRIFT: $rel (source != installed)"
        }
    } elseif ($sourceHashes.Contains($rel) -and -not $installedHashes.Contains($rel)) {
        $originVerified = $false
        Write-Host "  MISSING: $rel (source present, installed missing)"
    }
}
if ($bridgeSourceHash -and $bridgeInstalledHash -and ($bridgeSourceHash -ne $bridgeInstalledHash)) {
    $originVerified = $false
    Write-Host '  DRIFT: bridge (AkashicIntegrityBridge != HeliosIntegrityBridge)'
}

if (-not $manifestHash) {
    $originVerified = $false
    Write-Host '  MISSING: helios-envelope.json not found'
}
if (-not $sidecarValue) {
    $originVerified = $false
    Write-Host '  MISSING: helios-envelope.sha256 not found'
}

$origin = [ordered]@{
    schema_version           = 'helios-install-origin.v1'
    created_utc              = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    installed_by             = $InstalledBy
    install_mode             = $InstallMode
    platform                 = $Platform
    pwsh_path                = $pwshPath
    claude_settings_path     = $claudeSettingsPath
    akashic_root             = $AkashicRoot
    akashic_head             = $akashicHead
    helios_repo_root         = $heliosRepoRoot
    helios_head              = $heliosHead
    runtime_bundle_root      = $RuntimeBundleRoot
    helios_gate_root         = $HeliosGateRoot
    source_protected_hashes  = $sourceHashes
    installed_runtime_hashes = $installedHashes
    bridge_source_hash       = $bridgeSourceHash
    bridge_installed_hash    = $bridgeInstalledHash
    initial_manifest_hash    = $manifestHash
    initial_sidecar_hash     = $sidecarValue
    akashic_installer_hashes = $installerHashes
    origin_verified          = $originVerified
}

$originPath = Join-Path $HeliosGateRoot ('manifest\helios-install-origin.json'.Replace('\', $sep))
$originJson = $origin | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText($originPath, $originJson, $Utf8NoBom)

Write-Host "Install origin generated: $originPath"
Write-Host "  Akashic HEAD:    $akashicHead"
Write-Host "  Helios HEAD:     $heliosHead"
Write-Host "  Source files:    $($sourceHashes.Count)"
Write-Host "  Installed files: $($installedHashes.Count)"
Write-Host "  Origin verified: $originVerified"

return [ordered]@{
    origin_path     = $originPath
    akashic_head    = $akashicHead
    helios_head     = $heliosHead
    source_count    = $sourceHashes.Count
    installed_count = $installedHashes.Count
    origin_verified = $originVerified
    manifest_hash   = $manifestHash
    sidecar_hash    = $sidecarValue
}
