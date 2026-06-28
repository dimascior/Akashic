# Test-HeliosRuntimeBundle.ps1 — Verify a Helios runtime bundle
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BundleRoot
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BundleRoot)) {
    throw "Bundle root not found: $BundleRoot"
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$Checks = @()
$Verdict = 'PASS'

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Checks += @{ check = $Name; passed = $Passed; detail = $Detail }
    if (-not $Passed) { $script:Verdict = 'FAIL' }
}

$ManifestPath = Join-Path $BundleRoot 'runtime-manifest.json'
if (Test-Path $ManifestPath) {
    Add-Check -Name 'manifest_exists' -Passed $true -Detail $ManifestPath
    try {
        $Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        Add-Check -Name 'manifest_parseable' -Passed $true -Detail "schema: $($Manifest.schema_version)"
    } catch {
        Add-Check -Name 'manifest_parseable' -Passed $false -Detail $_.Exception.Message
        $Manifest = $null
    }
} else {
    Add-Check -Name 'manifest_exists' -Passed $false -Detail 'runtime-manifest.json not found'
    $Manifest = $null
}

if ($Manifest -and $Manifest.source_branch) {
    Add-Check -Name 'source_branch' -Passed $true -Detail "branch: $($Manifest.source_branch)"
}

$RequiredHooks = @(
    'hooks\helios_pretooluse.ps1',
    'hooks\gate_check.ps1',
    'hooks\evidence_capture.ps1',
    'hooks\tier_classifier.ps1'
)
$MissingHooks = @()
foreach ($h in $RequiredHooks) {
    if (-not (Test-Path (Join-Path $BundleRoot $h))) { $MissingHooks += $h }
}
Add-Check -Name 'hooks_exist' -Passed ($MissingHooks.Count -eq 0) `
    -Detail $(if ($MissingHooks.Count -eq 0) { "$($RequiredHooks.Count) hooks present" } else { "Missing: $($MissingHooks -join ', ')" })

$PolicyPath = Join-Path $BundleRoot 'policy\command-policy.json'
if (Test-Path $PolicyPath) {
    try {
        Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json | Out-Null
        Add-Check -Name 'policy_valid' -Passed $true -Detail $PolicyPath
    } catch {
        Add-Check -Name 'policy_valid' -Passed $false -Detail "Invalid JSON: $($_.Exception.Message)"
    }
} else {
    Add-Check -Name 'policy_valid' -Passed $false -Detail 'policy/command-policy.json not found'
}

$TemplatesDir = Join-Path $BundleRoot 'templates'
Add-Check -Name 'templates_dir' -Passed (Test-Path $TemplatesDir) -Detail $TemplatesDir

$MutableDirs = @('pending', 'inflight', 'evidence', 'blocked')
$MutableClean = $true
$MutableDetail = @()
foreach ($dir in $MutableDirs) {
    $path = Join-Path $BundleRoot $dir
    if (-not (Test-Path $path)) {
        $MutableClean = $false
        $MutableDetail += "$dir missing"
        continue
    }
    $files = @(Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    if ($files.Count -gt 0) {
        $MutableClean = $false
        $MutableDetail += "$dir has $($files.Count) non-gitkeep files"
    }
}
Add-Check -Name 'mutable_dirs_clean' -Passed $MutableClean `
    -Detail $(if ($MutableClean) { '4 mutable dirs contain .gitkeep only' } else { $MutableDetail -join '; ' })

$EnvelopePath = Join-Path $BundleRoot 'manifest\helios-envelope.json'
$SidecarPath = Join-Path $BundleRoot 'manifest\helios-envelope.sha256'
$NoEnvelope = (-not (Test-Path $EnvelopePath)) -and (-not (Test-Path $SidecarPath))
Add-Check -Name 'no_bundled_manifest' -Passed $NoEnvelope `
    -Detail $(if ($NoEnvelope) { 'Manifest/sidecar correctly excluded (generated locally)' } else { 'Manifest or sidecar found in bundle — should be excluded' })

$BridgePath = Join-Path $BundleRoot 'hooks\lib\HeliosIntegrityBridge.ps1'
$NoBridge = -not (Test-Path $BridgePath)
Add-Check -Name 'no_bundled_bridge' -Passed $NoBridge `
    -Detail $(if ($NoBridge) { 'Bridge correctly excluded (installed from TCE adapter)' } else { 'Bridge found in bundle — should be installed from adapter package' })

if ($Manifest) {
    $filesEntries = @()
    if ($Manifest.files) { foreach ($f in $Manifest.files) { $filesEntries += $f.path } }
    $hashKeys = @()
    if ($Manifest.file_hashes) { foreach ($p in $Manifest.file_hashes.PSObject.Properties) { $hashKeys += $p.Name } }

    $MissingOnDisk = @()
    $MissingInHashes = @()
    foreach ($fp in $filesEntries) {
        $fullPath = Join-Path $BundleRoot ($fp -replace '/', '\')
        if (-not (Test-Path $fullPath)) { $MissingOnDisk += $fp }
        if ($hashKeys -notcontains $fp) { $MissingInHashes += $fp }
    }
    Add-Check -Name 'files_exist_on_disk' -Passed ($MissingOnDisk.Count -eq 0) `
        -Detail $(if ($MissingOnDisk.Count -eq 0) { "$($filesEntries.Count) files[] entries exist" } else { "Missing: $($MissingOnDisk -join ', ')" })
    Add-Check -Name 'files_have_hashes' -Passed ($MissingInHashes.Count -eq 0) `
        -Detail $(if ($MissingInHashes.Count -eq 0) { "$($filesEntries.Count) files[] entries have file_hashes" } else { "No hash: $($MissingInHashes -join ', ')" })

    $checksumPath = Join-Path $BundleRoot 'runtime-checksums.sha256'
    if (Test-Path $checksumPath) {
        $csLines = (Get-Content -LiteralPath $checksumPath) | Where-Object { $_.Trim() -ne '' }
        $csEntries = @()
        foreach ($ln in $csLines) { $p = $ln -split '  ', 2; if ($p.Count -eq 2) { $csEntries += $p[1].Trim() } }
        $MissingInChecksums = @()
        foreach ($hk in $hashKeys) {
            if ($csEntries -notcontains $hk) { $MissingInChecksums += $hk }
        }
        Add-Check -Name 'hashes_in_checksums' -Passed ($MissingInChecksums.Count -eq 0) `
            -Detail $(if ($MissingInChecksums.Count -eq 0) { "$($hashKeys.Count) file_hashes entries in checksums" } else { "Missing from checksums: $($MissingInChecksums -join ', ')" })
    }
}

$ManifestBomFree = $true
$ChecksumsBomFree = $true
if (Test-Path $ManifestPath) {
    $mRaw = [System.IO.File]::ReadAllBytes($ManifestPath)
    if ($mRaw.Length -ge 3 -and $mRaw[0] -eq 0xEF -and $mRaw[1] -eq 0xBB -and $mRaw[2] -eq 0xBF) {
        $ManifestBomFree = $false
    }
}
Add-Check -Name 'manifest_bom_free' -Passed $ManifestBomFree -Detail $(if ($ManifestBomFree) { 'No BOM' } else { 'BOM DETECTED in runtime-manifest.json' })
$csFile = Join-Path $BundleRoot 'runtime-checksums.sha256'
if (Test-Path $csFile) {
    $csRaw = [System.IO.File]::ReadAllBytes($csFile)
    if ($csRaw.Length -ge 3 -and $csRaw[0] -eq 0xEF -and $csRaw[1] -eq 0xBB -and $csRaw[2] -eq 0xBF) {
        $ChecksumsBomFree = $false
    }
}
Add-Check -Name 'checksums_bom_free' -Passed $ChecksumsBomFree -Detail $(if ($ChecksumsBomFree) { 'No BOM' } else { 'BOM DETECTED in runtime-checksums.sha256' })

$MutableGitkeepOk = $true
$MutableGitkeepDetail = @()
foreach ($dir in $MutableDirs) {
    $gk = Join-Path $BundleRoot "$dir\.gitkeep"
    if (-not (Test-Path $gk)) {
        $MutableGitkeepOk = $false
        $MutableGitkeepDetail += "$dir/.gitkeep missing"
    }
}
Add-Check -Name 'mutable_gitkeep_present' -Passed $MutableGitkeepOk `
    -Detail $(if ($MutableGitkeepOk) { '4 mutable dirs have .gitkeep' } else { $MutableGitkeepDetail -join '; ' })

$BomFiles = @()
$JsonFiles = @(Get-ChildItem -Path $BundleRoot -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue)
foreach ($jf in $JsonFiles) {
    $raw = [System.IO.File]::ReadAllBytes($jf.FullName)
    if ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) {
        $BomFiles += $jf.FullName.Substring($BundleRoot.Length + 1)
    }
}
Add-Check -Name 'json_bom_free' -Passed ($BomFiles.Count -eq 0) `
    -Detail $(if ($BomFiles.Count -eq 0) { "$($JsonFiles.Count) JSON files BOM-free" } else { "BOM found in: $($BomFiles -join ', ')" })

$ChecksumsPath = Join-Path $BundleRoot 'runtime-checksums.sha256'
if (Test-Path $ChecksumsPath) {
    $checksumLines = (Get-Content -LiteralPath $ChecksumsPath) | Where-Object { $_.Trim() -ne '' }
    $hashMismatches = @()
    foreach ($line in $checksumLines) {
        $parts = $line -split '  ', 2
        if ($parts.Count -ne 2) { continue }
        $expectedHash = $parts[0].Trim()
        $relPath = $parts[1].Trim()
        $fullPath = Join-Path $BundleRoot ($relPath -replace '/', '\')
        if ($relPath -eq 'runtime-checksums.sha256') { continue }
        if (-not (Test-Path $fullPath)) {
            $hashMismatches += "$relPath (missing)"
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        $computed = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        if ($computed -ne $expectedHash) {
            $hashMismatches += "$relPath (hash mismatch)"
        }
    }
    Add-Check -Name 'checksums_match' -Passed ($hashMismatches.Count -eq 0) `
        -Detail $(if ($hashMismatches.Count -eq 0) { "$($checksumLines.Count) files verified" } else { "Mismatches: $($hashMismatches -join '; ')" })
} else {
    Add-Check -Name 'checksums_match' -Passed $false -Detail 'runtime-checksums.sha256 not found'
}

$Result = @{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    bundle_root   = $BundleRoot
    verdict       = $Verdict
    checks        = $Checks
    total_checks  = $Checks.Count
    passed_checks = ($Checks | Where-Object { $_.passed }).Count
    failed_checks = ($Checks | Where-Object { -not $_.passed }).Count
}

Write-Host "Runtime bundle verification: $Verdict ($($Result.passed_checks)/$($Result.total_checks) checks passed)"
$Result | ConvertTo-Json -Depth 4
return $Result
