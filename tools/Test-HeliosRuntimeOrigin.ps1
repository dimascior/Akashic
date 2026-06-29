[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$RuntimeBundleRoot,

    [ValidateSet('Auto', 'Windows', 'macOS', 'Linux')]
    [string]$Platform = 'Auto',

    [ValidateSet('DetectOnly', 'LogOnly', 'PlanReset', 'AutoReset', 'AutoResetAndReactivate')]
    [string]$AutomationMode = 'LogOnly'
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sha256 = [System.Security.Cryptography.SHA256]::Create()
$sep = [System.IO.Path]::DirectorySeparatorChar
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ($Platform -eq 'Auto') {
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { $Platform = 'Windows' }
    elseif ($IsMacOS) { $Platform = 'macOS' }
    elseif ($IsLinux) { $Platform = 'Linux' }
    else { $Platform = 'Windows' }
}

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
    } catch { try { Set-Location $prev } catch {} }
    return $null
}

function Normalize-RelPath([string]$Path) {
    $Path.Replace('\', '/')
}

$manifestPath = Join-Path $HeliosGateRoot ('manifest\helios-envelope.json'.Replace('\', $sep))
$sidecarPath  = Join-Path $HeliosGateRoot ('manifest\helios-envelope.sha256'.Replace('\', $sep))
$originPath   = Join-Path $HeliosGateRoot ('manifest\helios-install-origin.json'.Replace('\', $sep))

$protectedRelPaths = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1',
    'policy/command-policy.json'
)

$sourceProtectedRelPaths = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'policy/command-policy.json'
)

# --- Step 1: Current manifest check ---
Write-Host '=== Helios Runtime Origin Detection ==='
Write-Host ''

$manifestVerdict = 'NO_MANIFEST'
$sidecarVerdict = 'MISSING'
$manifestHashes = [ordered]@{}
$actualHashes = [ordered]@{}
$affectedFiles = [System.Collections.Generic.List[object]]::new()

if (Test-Path $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

    $manifestFileHash = Get-FileHash256 $manifestPath
    if (Test-Path $sidecarPath) {
        $sidecarValue = ([System.IO.File]::ReadAllText($sidecarPath, $Utf8NoBom)).Trim()
        if ($sidecarValue -eq $manifestFileHash) {
            $sidecarVerdict = 'MATCH'
        } else {
            $sidecarVerdict = 'MISMATCH'
        }
    }

    $driftCount = 0
    $manifestHashes = [ordered]@{}
    if ($manifest.protected -and $manifest.protected.hashes) {
        $hashObj = $manifest.protected.hashes
        foreach ($prop in $hashObj.PSObject.Properties) {
            $rel = Normalize-RelPath $prop.Name
            $manifestHashes[$rel] = $prop.Value
        }
    }

    foreach ($rel in $protectedRelPaths) {
        $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
        if (Test-Path $fullPath) {
            $hash = Get-FileHash256 $fullPath
            $actualHashes[$rel] = $hash
            $expectedHash = if ($manifestHashes.Contains($rel)) { $manifestHashes[$rel] } else { $null }
            if ($expectedHash -and $hash -ne $expectedHash) {
                $driftCount++
                $affectedFiles.Add([ordered]@{
                    path          = $rel
                    status        = 'DRIFT'
                    manifest_hash = $expectedHash
                    origin_hash   = $null
                    actual_hash   = $hash
                })
            } elseif (-not $expectedHash) {
                $affectedFiles.Add([ordered]@{
                    path          = $rel
                    status        = 'UNTRACKED'
                    manifest_hash = $null
                    origin_hash   = $null
                    actual_hash   = $hash
                })
            }
        } else {
            if ($manifestHashes.Contains($rel)) {
                $driftCount++
                $affectedFiles.Add([ordered]@{
                    path          = $rel
                    status        = 'MISSING'
                    manifest_hash = $manifestHashes[$rel]
                    origin_hash   = $null
                    actual_hash   = $null
                })
            }
            $actualHashes[$rel] = $null
        }
    }

    $manifestVerdict = if ($driftCount -eq 0) { 'CLEAN' } else { 'DRIFT' }
} else {
    $manifestVerdict = 'NO_MANIFEST'
    foreach ($rel in $protectedRelPaths) {
        $fullPath = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
        if (Test-Path $fullPath) {
            $actualHashes[$rel] = Get-FileHash256 $fullPath
        } else {
            $actualHashes[$rel] = $null
        }
    }
}

Write-Host "[$(if ($manifestVerdict -eq 'CLEAN') {'PASS'} else {'FAIL'})] Manifest verdict: $manifestVerdict"
Write-Host "[$(if ($sidecarVerdict -eq 'MATCH') {'PASS'} else {'FAIL'})] Sidecar verdict: $sidecarVerdict"

# --- Step 2: Origin lineage check ---
$originVerdict = 'NO_ORIGIN'
$originHashes = [ordered]@{}
$originData = $null

if (Test-Path $originPath) {
    $originData = Get-Content -LiteralPath $originPath -Raw | ConvertFrom-Json

    if ($originData.installed_runtime_hashes) {
        foreach ($prop in $originData.installed_runtime_hashes.PSObject.Properties) {
            $rel = Normalize-RelPath $prop.Name
            $originHashes[$rel] = $prop.Value
        }
    }

    $originDriftCount = 0
    foreach ($rel in $protectedRelPaths) {
        $currentHash = if ($actualHashes.Contains($rel)) { $actualHashes[$rel] } else { $null }
        $recordedHash = if ($originHashes.Contains($rel)) { $originHashes[$rel] } else { $null }

        if ($recordedHash -and $currentHash -and $currentHash -ne $recordedHash) {
            $originDriftCount++
            $existing = $affectedFiles | Where-Object { $_.path -eq $rel }
            if ($existing) {
                $existing.origin_hash = $recordedHash
            } else {
                $affectedFiles.Add([ordered]@{
                    path          = $rel
                    status        = 'DRIFT'
                    manifest_hash = if ($manifestHashes.Contains($rel)) { $manifestHashes[$rel] } else { $null }
                    origin_hash   = $recordedHash
                    actual_hash   = $currentHash
                })
            }
        } elseif ($recordedHash -and -not $currentHash) {
            $originDriftCount++
        }
    }

    if ($originDriftCount -eq 0) {
        $originVerdict = 'MATCH'
    } elseif ($manifestVerdict -eq 'CLEAN' -and $originDriftCount -gt 0) {
        $originVerdict = 'BASELINE_REWRITE_SUSPECTED'
    } else {
        $originVerdict = 'DRIFT'
    }
} else {
    $originVerdict = 'NO_ORIGIN'
}

Write-Host "[$(if ($originVerdict -eq 'MATCH') {'PASS'} else {'FAIL'})] Origin verdict: $originVerdict"

# --- Step 3: Source repo check ---
$sourceStatus = [ordered]@{
    verdict              = 'SOURCE_NOT_PROVIDED'
    current_akashic_head = $null
    recorded_akashic_head = if ($originData) { $originData.akashic_head } else { $null }
    current_helios_head  = $null
    recorded_helios_head = if ($originData) { $originData.helios_head } else { $null }
    changed_source_files = @()
}

$currentAkashicHead = Get-GitHead $AkashicRoot
$sourceStatus.current_akashic_head = $currentAkashicHead

if ($RuntimeBundleRoot) {
    if (Test-Path $RuntimeBundleRoot) {
        $heliosRepoRoot = $null
        try {
            $prev = $PWD
            Set-Location $RuntimeBundleRoot
            $heliosRepoRoot = (git rev-parse --show-toplevel 2>$null)
            Set-Location $prev
        } catch { try { Set-Location $prev } catch {} }

        $currentHeliosHead = if ($heliosRepoRoot) { Get-GitHead $heliosRepoRoot } else { $null }
        $sourceStatus.current_helios_head = $currentHeliosHead

        $changedFiles = @()
        if ($originData -and $originData.source_protected_hashes) {
            foreach ($prop in $originData.source_protected_hashes.PSObject.Properties) {
                $rel = Normalize-RelPath $prop.Name
                $fullPath = Join-Path $RuntimeBundleRoot ($rel.Replace('/', $sep))
                if (Test-Path $fullPath) {
                    $currentHash = Get-FileHash256 $fullPath
                    if ($currentHash -ne $prop.Value) {
                        $changedFiles += $rel
                    }
                } else {
                    $changedFiles += $rel
                }
            }
        }

        $sourceStatus.changed_source_files = $changedFiles
        $headsChanged = $false
        if ($originData) {
            if ($currentAkashicHead -and $originData.akashic_head -and $currentAkashicHead -ne $originData.akashic_head) { $headsChanged = $true }
            if ($currentHeliosHead -and $originData.helios_head -and $currentHeliosHead -ne $originData.helios_head) { $headsChanged = $true }
        }

        if ($changedFiles.Count -gt 0 -or $headsChanged) {
            $sourceStatus.verdict = 'SOURCE_REPO_CHANGED'
        } else {
            $sourceStatus.verdict = 'SOURCE_MATCH'
        }
    } else {
        $sourceStatus.verdict = 'SOURCE_REPO_MISSING'
    }
}

Write-Host "[$(if ($sourceStatus.verdict -eq 'SOURCE_MATCH' -or $sourceStatus.verdict -eq 'SOURCE_NOT_PROVIDED') {'INFO'} else {'WARN'})] Source repo: $($sourceStatus.verdict)"

# --- Step 4: Bridge check ---
$bridgeSourcePath    = Join-Path $AkashicRoot 'AkashicIntegrityBridge.ps1'
$bridgeInstalledPath = Join-Path $HeliosGateRoot ('hooks\lib\HeliosIntegrityBridge.ps1'.Replace('\', $sep))

$currentBridgeSourceHash    = if (Test-Path $bridgeSourcePath) { Get-FileHash256 $bridgeSourcePath } else { $null }
$currentBridgeInstalledHash = if (Test-Path $bridgeInstalledPath) { Get-FileHash256 $bridgeInstalledPath } else { $null }

$bridgeStatus = [ordered]@{
    verdict               = 'BRIDGE_MATCH'
    current_source_hash   = $currentBridgeSourceHash
    current_installed_hash = $currentBridgeInstalledHash
    origin_source_hash    = if ($originData) { $originData.bridge_source_hash } else { $null }
    origin_installed_hash = if ($originData) { $originData.bridge_installed_hash } else { $null }
}

if (-not $currentBridgeSourceHash) {
    $bridgeStatus.verdict = 'BRIDGE_SOURCE_MISSING'
} elseif (-not $currentBridgeInstalledHash) {
    $bridgeStatus.verdict = 'BRIDGE_INSTALLED_MISSING'
} elseif ($currentBridgeSourceHash -ne $currentBridgeInstalledHash) {
    $bridgeStatus.verdict = 'BRIDGE_ORIGIN_DRIFT'
} else {
    $bridgeStatus.verdict = 'BRIDGE_MATCH'
}

Write-Host "[$(if ($bridgeStatus.verdict -eq 'BRIDGE_MATCH') {'PASS'} else {'WARN'})] Bridge: $($bridgeStatus.verdict)"

# --- Step 5: Determine primary detection type ---
$detectionType = 'CURRENT_MANIFEST_CLEAN'
$severity = 'INFO'
$recommendedAction = 'NONE'

if ($originVerdict -eq 'BASELINE_REWRITE_SUSPECTED') {
    $detectionType = 'BASELINE_REWRITE_SUSPECTED'
    $severity = 'CRITICAL'
    $recommendedAction = 'RESET_FROM_REPO'
} elseif ($sidecarVerdict -eq 'MISMATCH') {
    $detectionType = 'SIDECAR_MISMATCH'
    $severity = 'HIGH'
    $recommendedAction = 'VERIFY_ORIGIN_THEN_REGENERATE_OR_RESET'
} elseif ($manifestVerdict -eq 'DRIFT' -or $manifestVerdict -eq 'NO_MANIFEST') {
    $detectionType = 'CURRENT_MANIFEST_DRIFT'
    $severity = 'HIGH'
    $recommendedAction = 'RESET_FROM_REPO'
} elseif ($originVerdict -eq 'NO_ORIGIN') {
    $detectionType = 'NO_INSTALL_ORIGIN'
    $severity = 'HIGH'
    $recommendedAction = 'RESET_FROM_REPO_TO_CREATE_ORIGIN'
} elseif ($originVerdict -eq 'DRIFT') {
    $detectionType = 'ORIGIN_DRIFT'
    $severity = 'HIGH'
    $recommendedAction = 'RESET_FROM_REPO'
} elseif ($sourceStatus.verdict -eq 'SOURCE_REPO_MISSING') {
    $detectionType = 'SOURCE_REPO_MISSING'
    $severity = 'HIGH'
    $recommendedAction = 'BLOCK_RESET_UNTIL_SOURCE_RESOLVED'
} elseif ($sourceStatus.verdict -eq 'SOURCE_REPO_CHANGED') {
    $detectionType = 'SOURCE_REPO_CHANGED'
    $severity = 'MEDIUM'
    $recommendedAction = 'PLAN_RESET_FROM_NEW_REPO_STATE'
} elseif ($bridgeStatus.verdict -eq 'BRIDGE_ORIGIN_DRIFT') {
    $detectionType = 'BRIDGE_ORIGIN_DRIFT'
    $severity = 'MEDIUM'
    $recommendedAction = 'RESET_FROM_REPO'
} elseif ($originVerdict -eq 'MATCH') {
    $detectionType = 'ORIGIN_MATCH'
    $severity = 'INFO'
    $recommendedAction = 'NONE'
} else {
    $detectionType = 'CURRENT_MANIFEST_CLEAN'
    $severity = 'INFO'
    $recommendedAction = 'NONE'
}

$autoResetAllowed = @(
    'BASELINE_REWRITE_SUSPECTED',
    'CURRENT_MANIFEST_DRIFT',
    'ORIGIN_DRIFT',
    'NO_INSTALL_ORIGIN',
    'BRIDGE_ORIGIN_DRIFT'
)

$automationResult = switch ($AutomationMode) {
    'DetectOnly' { 'DETECTED' }
    'LogOnly'    { 'LOGGED' }
    'PlanReset'  {
        if ($detectionType -eq 'CURRENT_MANIFEST_CLEAN' -or $detectionType -eq 'ORIGIN_MATCH') { 'DETECTED' }
        else { 'PLAN_GENERATED' }
    }
    'AutoReset' {
        if ($detectionType -eq 'CURRENT_MANIFEST_CLEAN' -or $detectionType -eq 'ORIGIN_MATCH') {
            'DETECTED'
        } elseif ($detectionType -notin $autoResetAllowed) {
            'RESET_BLOCKED'
        } elseif (-not $RuntimeBundleRoot) {
            'RESET_BLOCKED_NO_BUNDLE'
        } else {
            try {
                $resetResult = & (Join-Path $ScriptDir 'Reset-AkashicHeliosRuntime.ps1') `
                    -AkashicRoot $AkashicRoot `
                    -RuntimeBundleRoot $RuntimeBundleRoot `
                    -HeliosGateRoot $HeliosGateRoot `
                    -Platform $Platform
                if ($resetResult.overall -eq 'COMPLETE') { 'RESET_COMPLETE' }
                else { 'RESET_PARTIAL' }
            } catch {
                Write-Host "[FAIL] AutoReset failed: $_" -ForegroundColor Red
                'RESET_FAILED'
            }
        }
    }
    'AutoResetAndReactivate' {
        if ($detectionType -eq 'CURRENT_MANIFEST_CLEAN' -or $detectionType -eq 'ORIGIN_MATCH') {
            'DETECTED'
        } elseif ($detectionType -notin $autoResetAllowed) {
            'RESET_BLOCKED'
        } elseif (-not $RuntimeBundleRoot) {
            'RESET_BLOCKED_NO_BUNDLE'
        } else {
            try {
                $resetResult = & (Join-Path $ScriptDir 'Reset-AkashicHeliosRuntime.ps1') `
                    -AkashicRoot $AkashicRoot `
                    -RuntimeBundleRoot $RuntimeBundleRoot `
                    -HeliosGateRoot $HeliosGateRoot `
                    -Platform $Platform `
                    -DisableHooksDuringReset `
                    -ReactivateHooksAfterReset
                if ($resetResult.overall -eq 'COMPLETE') { 'RESET_AND_REACTIVATE_COMPLETE' }
                else { 'RESET_AND_REACTIVATE_PARTIAL' }
            } catch {
                Write-Host "[FAIL] AutoResetAndReactivate failed: $_" -ForegroundColor Red
                'RESET_FAILED'
            }
        }
    }
}

Write-Host ''
Write-Host "Detection type:     $detectionType"
Write-Host "Severity:           $severity"
Write-Host "Recommended action: $recommendedAction"
Write-Host "Automation mode:    $AutomationMode"
Write-Host "Automation result:  $automationResult"

$detection = [ordered]@{
    schema_version           = 'helios-runtime-detection.v1'
    timestamp_utc            = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    platform                 = $Platform
    akashic_head             = $currentAkashicHead
    helios_head              = $sourceStatus.current_helios_head
    runtime_bundle_root      = $RuntimeBundleRoot
    helios_gate_root         = $HeliosGateRoot
    manifest_path            = $manifestPath
    sidecar_path             = $sidecarPath
    install_origin_path      = $originPath
    current_manifest_verdict = $manifestVerdict
    sidecar_verdict          = $sidecarVerdict
    origin_verdict           = $originVerdict
    detection_type           = $detectionType
    severity                 = $severity
    recommended_action       = $recommendedAction
    automation_mode          = $AutomationMode
    affected_files           = [object[]]$affectedFiles
    expected_manifest_hashes = $manifestHashes
    actual_runtime_hashes    = $actualHashes
    expected_origin_hashes   = $originHashes
    source_repo_status       = $sourceStatus
    bridge_status            = $bridgeStatus
    evidence_paths           = @()
    automation_result        = $automationResult
}

return $detection
