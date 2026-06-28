# Test-HeliosEndToEndInstallPlan.ps1 — Simulate a full install in a temp directory
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AdapterPackageRoot,

    [Parameter(Mandatory)]
    [string]$RuntimeBundleRoot,

    [string]$TempRoot
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha = [System.Security.Cryptography.SHA256]::Create()

if (-not $TempRoot) {
    $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "helios-install-sim-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$SimGateRoot = Join-Path $TempRoot '.command-gate'
$SimSettingsPath = Join-Path $TempRoot 'settings.json'

$Checks = @()
$Verdict = 'PASS'

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Checks += @{ check = $Name; passed = $Passed; detail = $Detail }
    if (-not $Passed) { $script:Verdict = 'FAIL' }
}

try {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    [System.IO.File]::WriteAllText($SimSettingsPath, '{}', $Utf8NoBom)

    # 1. Verify adapter package
    $adapterVerify = & (Join-Path $AdapterPackageRoot 'tools\Test-HeliosAdapterPackage.ps1') -PackageRoot $AdapterPackageRoot
    $avPassed = $adapterVerify.verdict -eq 'PASS'
    Add-Check -Name 'adapter_package_verifies' -Passed $avPassed -Detail "verdict: $($adapterVerify.verdict)"

    # 2. Verify runtime bundle
    $runtimeVerify = & (Join-Path $AdapterPackageRoot 'tools\Test-HeliosRuntimeBundle.ps1') -BundleRoot $RuntimeBundleRoot
    $rvPassed = $runtimeVerify.verdict -eq 'PASS'
    Add-Check -Name 'runtime_bundle_verifies' -Passed $rvPassed -Detail "verdict: $($runtimeVerify.verdict)"

    # 3. Generate combined install plan in Prepare mode
    $plan = & (Join-Path $AdapterPackageRoot 'tools\New-HeliosCombinedInstallPlan.ps1') `
        -AdapterPackageRoot $AdapterPackageRoot `
        -RuntimeBundleRoot $RuntimeBundleRoot `
        -TargetGateRoot $SimGateRoot `
        -ClaudeSettingsPath $SimSettingsPath `
        -Mode Prepare

    Add-Check -Name 'install_plan_generated' -Passed ($null -ne $plan) -Detail 'Combined install plan created'
    Add-Check -Name 'prepare_completed' -Passed ($plan.prepare_completed -eq $true) -Detail 'Prepare mode executed'

    # 4. Verify target scaffold
    $scaffoldOk = (Test-Path $SimGateRoot) -and
                  (Test-Path (Join-Path $SimGateRoot 'hooks')) -and
                  (Test-Path (Join-Path $SimGateRoot 'policy')) -and
                  (Test-Path (Join-Path $SimGateRoot 'pending')) -and
                  (Test-Path (Join-Path $SimGateRoot 'inflight')) -and
                  (Test-Path (Join-Path $SimGateRoot 'evidence')) -and
                  (Test-Path (Join-Path $SimGateRoot 'blocked'))
    Add-Check -Name 'target_scaffold_created' -Passed $scaffoldOk -Detail $SimGateRoot

    # 4b. Verify .gitkeep files
    $gitkeepDirs = @('pending', 'inflight', 'evidence', 'blocked', 'templates')
    $gitkeepMissing = @()
    foreach ($gkd in $gitkeepDirs) {
        $gkp = Join-Path $SimGateRoot "$gkd\.gitkeep"
        if (-not (Test-Path $gkp)) { $gitkeepMissing += "$gkd/.gitkeep" }
    }
    Add-Check -Name 'gitkeep_files_created' -Passed ($gitkeepMissing.Count -eq 0) `
        -Detail $(if ($gitkeepMissing.Count -eq 0) { "$($gitkeepDirs.Count) .gitkeep files present" } else { "Missing: $($gitkeepMissing -join ', ')" })

    # 4c. Verify protected runtime files copied (excludes bridge and manifest — those have separate install steps)
    $protectedFiles = @('hooks\helios_pretooluse.ps1', 'hooks\gate_check.ps1', 'hooks\evidence_capture.ps1', 'hooks\tier_classifier.ps1', 'policy\command-policy.json')
    $protMissing = @()
    foreach ($pf in $protectedFiles) {
        if (-not (Test-Path (Join-Path $SimGateRoot $pf))) { $protMissing += $pf }
    }
    Add-Check -Name 'protected_files_copied' -Passed ($protMissing.Count -eq 0) `
        -Detail $(if ($protMissing.Count -eq 0) { "$($protectedFiles.Count) protected files present" } else { "Missing: $($protMissing -join ', ')" })

    # 5. Verify bridge copied
    $bridgeDest = Join-Path $SimGateRoot 'hooks\lib\HeliosIntegrityBridge.ps1'
    $bridgeSource = Join-Path $AdapterPackageRoot 'HeliosIntegrityBridge.ps1'
    $bridgeCopied = Test-Path $bridgeDest
    Add-Check -Name 'bridge_copied' -Passed $bridgeCopied -Detail $bridgeDest

    # 6. Verify bridge byte identity
    if ($bridgeCopied -and (Test-Path $bridgeSource)) {
        $srcBytes = [System.IO.File]::ReadAllBytes($bridgeSource)
        $dstBytes = [System.IO.File]::ReadAllBytes($bridgeDest)
        $srcHash = ($sha.ComputeHash($srcBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $dstHash = ($sha.ComputeHash($dstBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        Add-Check -Name 'bridge_byte_identity' -Passed ($srcHash -eq $dstHash) -Detail "src=$($srcHash.Substring(0,12))... dst=$($dstHash.Substring(0,12))..."
    }

    # 7. Generate manifest
    $manifestTool = Join-Path $AdapterPackageRoot 'tools\New-HeliosEnvelopeManifest.ps1'
    if (Test-Path $manifestTool) {
        try {
            & $manifestTool -HeliosGateRoot $SimGateRoot -RebaselinedBy 'e2e-test' -Note 'End-to-end install simulation' | Out-Null
            $manifestGenerated = Test-Path (Join-Path $SimGateRoot 'manifest\helios-envelope.json')
            $sidecarGenerated = Test-Path (Join-Path $SimGateRoot 'manifest\helios-envelope.sha256')
            Add-Check -Name 'manifest_generated' -Passed $manifestGenerated -Detail (Join-Path $SimGateRoot 'manifest\helios-envelope.json')
            Add-Check -Name 'sidecar_generated' -Passed $sidecarGenerated -Detail (Join-Path $SimGateRoot 'manifest\helios-envelope.sha256')
        } catch {
            Add-Check -Name 'manifest_generated' -Passed $false -Detail $_.Exception.Message
        }
    }

    # 8. BOM check on manifest and sidecar
    $envPath = Join-Path $SimGateRoot 'manifest\helios-envelope.json'
    $sidPath = Join-Path $SimGateRoot 'manifest\helios-envelope.sha256'
    if (Test-Path $envPath) {
        $envBytes = [System.IO.File]::ReadAllBytes($envPath)
        $envBom = ($envBytes.Length -ge 3 -and $envBytes[0] -eq 0xEF -and $envBytes[1] -eq 0xBB -and $envBytes[2] -eq 0xBF)
        Add-Check -Name 'manifest_bom_free' -Passed (-not $envBom) -Detail $(if ($envBom) { 'BOM DETECTED' } else { 'No BOM' })
    }
    if (Test-Path $sidPath) {
        $sidBytes = [System.IO.File]::ReadAllBytes($sidPath)
        $sidBom = ($sidBytes.Length -ge 3 -and $sidBytes[0] -eq 0xEF -and $sidBytes[1] -eq 0xBB -and $sidBytes[2] -eq 0xBF)
        Add-Check -Name 'sidecar_bom_free' -Passed (-not $sidBom) -Detail $(if ($sidBom) { 'BOM DETECTED' } else { 'No BOM' })
    }

    # 9. Verify envelope integrity
    $integrityTool = Join-Path $AdapterPackageRoot 'tools\Test-HeliosEnvelopeIntegrity.ps1'
    if ((Test-Path $integrityTool) -and (Test-Path $envPath)) {
        try {
            $integrity = & $integrityTool -HeliosGateRoot $SimGateRoot
            $integrityOk = $integrity.verdict -eq 'CLEAN'
            Add-Check -Name 'envelope_integrity' -Passed $integrityOk -Detail "verdict: $($integrity.verdict)"
        } catch {
            Add-Check -Name 'envelope_integrity' -Passed $false -Detail $_.Exception.Message
        }
    }

    # 10. Verify settings activation plan in combined plan
    $settingsPlanOk = ($null -ne $plan.settings_activation_plan) -and ($plan.settings_activation_plan.requires_approval -eq $true)
    Add-Check -Name 'settings_plan_generated' -Passed $settingsPlanOk -Detail 'Settings activation plan requires approval'

    # 11. Verify rollback plan
    $rollbackOk = ($null -ne $plan.rollback_plan) -and ($null -ne $plan.rollback_plan.steps)
    Add-Check -Name 'rollback_plan_generated' -Passed $rollbackOk -Detail 'Rollback plan with steps'

} catch {
    Add-Check -Name 'simulation_error' -Passed $false -Detail $_.Exception.Message
} finally {
    if (Test-Path $TempRoot) {
        Remove-Item $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$Result = @{
    timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    verdict       = $Verdict
    temp_root     = $TempRoot
    checks        = $Checks
    total_checks  = $Checks.Count
    passed_checks = ($Checks | Where-Object { $_.passed }).Count
    failed_checks = ($Checks | Where-Object { -not $_.passed }).Count
}

Write-Host "End-to-end install simulation: $Verdict ($($Result.passed_checks)/$($Result.total_checks) checks passed)"
$Result | ConvertTo-Json -Depth 4
return $Result
