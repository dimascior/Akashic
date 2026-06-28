# Test-HeliosAdapterPackage.ps1 — Verify a TCE Helios adapter package
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PackageRoot
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PackageRoot)) {
    throw "Package root not found: $PackageRoot"
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$Checks = @()
$Verdict = 'PASS'

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Checks += @{ check = $Name; passed = $Passed; detail = $Detail }
    if (-not $Passed) { $script:Verdict = 'FAIL' }
}

$ManifestPath = Join-Path $PackageRoot 'package-manifest.json'
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
    Add-Check -Name 'manifest_exists' -Passed $false -Detail 'package-manifest.json not found'
    $Manifest = $null
}

if ($Manifest -and $Manifest.source_branch) {
    $branchOk = $Manifest.source_branch -eq 'helios-integrity-adapter'
    Add-Check -Name 'source_branch' -Passed $branchOk -Detail "branch: $($Manifest.source_branch)"
}

$BridgePath = Join-Path $PackageRoot 'HeliosIntegrityBridge.ps1'
Add-Check -Name 'bridge_exists' -Passed (Test-Path $BridgePath) -Detail $BridgePath

$RequiredFiles = @(
    'HeliosIntegrityBridge.ps1'
    'README.md'
    'docs\tce-helios-integrity-adapter-spec.md'
    'docs\package-architecture.md'
    'docs\install-sequence.md'
    'schemas\helios-envelope.schema.json'
    'schemas\helios-baseline.schema.json'
    'schemas\helios-command-evidence.schema.json'
    'tools\Sync-HeliosBridge.ps1'
    'tools\New-HeliosEnvelopeManifest.ps1'
    'tools\Test-HeliosEnvelopeIntegrity.ps1'
    'tools\Test-HeliosAdapterPackage.ps1'
    'tools\New-HeliosInstallPlan.ps1'
    'tools\New-HeliosRuntimeBundle.ps1'
    'tools\Test-HeliosRuntimeBundle.ps1'
    'tools\New-HeliosCombinedInstallPlan.ps1'
    'tools\Test-HeliosEndToEndInstallPlan.ps1'
)

$MissingRequired = @()
foreach ($rel in $RequiredFiles) {
    $fullPath = Join-Path $PackageRoot $rel
    if (-not (Test-Path $fullPath)) {
        $MissingRequired += $rel
    }
}

if ($MissingRequired.Count -eq 0) {
    Add-Check -Name 'required_files' -Passed $true -Detail "$($RequiredFiles.Count) required files present"
} else {
    Add-Check -Name 'required_files' -Passed $false -Detail "Missing: $($MissingRequired -join ', ')"
}

$SchemaDir = Join-Path $PackageRoot 'schemas'
if (Test-Path $SchemaDir) {
    $schemas = @(Get-ChildItem -Path $SchemaDir -Filter '*.json' -File)
    $schemasValid = $true
    foreach ($s in $schemas) {
        try {
            Get-Content -LiteralPath $s.FullName -Raw | ConvertFrom-Json | Out-Null
        } catch {
            $schemasValid = $false
        }
    }
    Add-Check -Name 'schemas_valid' -Passed $schemasValid -Detail "$($schemas.Count) schema files"
} else {
    Add-Check -Name 'schemas_valid' -Passed $false -Detail 'schemas/ directory not found'
}

$ToolsDir = Join-Path $PackageRoot 'tools'
if (Test-Path $ToolsDir) {
    $tools = @(Get-ChildItem -Path $ToolsDir -Filter '*.ps1' -File)
    Add-Check -Name 'tools_exist' -Passed ($tools.Count -gt 0) -Detail "$($tools.Count) tool files"
} else {
    Add-Check -Name 'tools_exist' -Passed $false -Detail 'tools/ directory not found'
}

$DocsDir = Join-Path $PackageRoot 'docs'
if (Test-Path $DocsDir) {
    $docs = @(Get-ChildItem -Path $DocsDir -Filter '*.md' -File)
    Add-Check -Name 'docs_exist' -Passed ($docs.Count -gt 0) -Detail "$($docs.Count) doc files"
} else {
    Add-Check -Name 'docs_exist' -Passed $false -Detail 'docs/ directory not found'
}

$GapTestDir = Join-Path $PackageRoot 'evidence\gap-tests'
if (Test-Path $GapTestDir) {
    $gapDirs = @(Get-ChildItem -Path $GapTestDir -Directory)
    Add-Check -Name 'gap_test_evidence' -Passed ($gapDirs.Count -gt 0) -Detail "$($gapDirs.Count) gap-test directories"
} else {
    Add-Check -Name 'gap_test_evidence' -Passed $false -Detail 'evidence/gap-tests/ not found'
}

$ChecksumsPath = Join-Path $PackageRoot 'checksums.sha256'
if (Test-Path $ChecksumsPath) {
    $checksumLines = (Get-Content -LiteralPath $ChecksumsPath) | Where-Object { $_.Trim() -ne '' }
    $hashMismatches = @()

    foreach ($line in $checksumLines) {
        $parts = $line -split '  ', 2
        if ($parts.Count -ne 2) { continue }
        $expectedHash = $parts[0].Trim()
        $relPath = $parts[1].Trim()
        $fullPath = Join-Path $PackageRoot ($relPath -replace '/', '\')

        if ($relPath -eq 'checksums.sha256') { continue }

        if (-not (Test-Path $fullPath)) {
            $hashMismatches += "$relPath (file missing)"
            continue
        }

        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        $computed = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''

        if ($computed -ne $expectedHash) {
            $hashMismatches += "$relPath (expected: $($expectedHash.Substring(0,12))..., got: $($computed.Substring(0,12))...)"
        }
    }

    if ($hashMismatches.Count -eq 0) {
        Add-Check -Name 'checksums_match' -Passed $true -Detail "$($checksumLines.Count) files verified"
    } else {
        Add-Check -Name 'checksums_match' -Passed $false -Detail "Mismatches: $($hashMismatches -join '; ')"
    }
} else {
    Add-Check -Name 'checksums_match' -Passed $false -Detail 'checksums.sha256 not found'
}

$BomChecks = @{ package_manifest_bom_free = $true; checksums_bom_free = $true; json_bom_free = $true }
if (Test-Path $ManifestPath) {
    $mRaw = [System.IO.File]::ReadAllBytes($ManifestPath)
    if ($mRaw.Length -ge 3 -and $mRaw[0] -eq 0xEF -and $mRaw[1] -eq 0xBB -and $mRaw[2] -eq 0xBF) {
        $BomChecks.package_manifest_bom_free = $false
    }
}
if (Test-Path $ChecksumsPath) {
    $cRaw = [System.IO.File]::ReadAllBytes($ChecksumsPath)
    if ($cRaw.Length -ge 3 -and $cRaw[0] -eq 0xEF -and $cRaw[1] -eq 0xBB -and $cRaw[2] -eq 0xBF) {
        $BomChecks.checksums_bom_free = $false
    }
}
$BomJsonFiles = @(Get-ChildItem -Path $PackageRoot -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue)
$BomJsonFails = @()
foreach ($jf in $BomJsonFiles) {
    $jRaw = [System.IO.File]::ReadAllBytes($jf.FullName)
    if ($jRaw.Length -ge 3 -and $jRaw[0] -eq 0xEF -and $jRaw[1] -eq 0xBB -and $jRaw[2] -eq 0xBF) {
        $BomJsonFails += $jf.FullName.Substring($PackageRoot.Length + 1)
    }
}
if ($BomJsonFails.Count -gt 0) { $BomChecks.json_bom_free = $false }

Add-Check -Name 'package_manifest_bom_free' -Passed $BomChecks.package_manifest_bom_free -Detail $(if ($BomChecks.package_manifest_bom_free) { 'No BOM' } else { 'BOM DETECTED in package-manifest.json' })
Add-Check -Name 'checksums_bom_free' -Passed $BomChecks.checksums_bom_free -Detail $(if ($BomChecks.checksums_bom_free) { 'No BOM' } else { 'BOM DETECTED in checksums.sha256' })
Add-Check -Name 'json_bom_free' -Passed ($BomJsonFails.Count -eq 0) `
    -Detail $(if ($BomJsonFails.Count -eq 0) { "$($BomJsonFiles.Count) JSON files BOM-free" } else { "BOM found in: $($BomJsonFails -join ', ')" })

$Result = @{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    package_root  = $PackageRoot
    verdict       = $Verdict
    checks        = $Checks
    bom_check     = $BomChecks
    total_checks  = $Checks.Count
    passed_checks = ($Checks | Where-Object { $_.passed }).Count
    failed_checks = ($Checks | Where-Object { -not $_.passed }).Count
}

Write-Host "Package verification: $Verdict ($($Result.passed_checks)/$($Result.total_checks) checks passed)"
$Result | ConvertTo-Json -Depth 4
return $Result
