# Test-HeliosLiveOperational.ps1 — Verify Helios runtime is correctly
# installed, hooked into Claude settings, and structurally sound.
# Covers automated static checks. Live hook execution requires real
# Claude tool calls and cannot be tested from within a script.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$ClaudeSettingsPath,

    [ValidateSet('Auto', 'Windows', 'Linux', 'macOS')]
    [string]$Platform = 'Auto',

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($Platform -eq 'Auto') {
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { $Platform = 'Windows' }
    elseif ($IsMacOS) { $Platform = 'macOS' }
    elseif ($IsLinux) { $Platform = 'Linux' }
    else { $Platform = 'Windows' }
}

if (-not $ClaudeSettingsPath) {
    $ClaudeSettingsPath = switch ($Platform) {
        'Windows' { Join-Path $env:USERPROFILE '.claude\settings.json' }
        default   { Join-Path $env:HOME '.claude/settings.json' }
    }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
function Get-FileHash256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

$checks = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Check([string]$Name, [string]$Status, [string]$Detail) {
    $checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
    if ($Status -eq 'FAIL') { $failures.Add("$Name`: $Detail") }
    $mark = switch ($Status) { 'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }; default { "[${Status}]" } }
    Write-Host "$mark $Name — $Detail"
}

# --- 1. Runtime target exists ---
if (Test-Path $HeliosGateRoot) {
    Add-Check 'Runtime target exists' 'PASS' $HeliosGateRoot
} else {
    Add-Check 'Runtime target exists' 'FAIL' "Not found: $HeliosGateRoot"
}

# --- 2. Required hooks exist ---
$hookFiles = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1'
)
$hookMissing = @()
foreach ($f in $hookFiles) {
    $full = Join-Path $HeliosGateRoot ($f.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path $full)) { $hookMissing += $f }
}
if ($hookMissing.Count -eq 0) {
    Add-Check 'Required hooks present' 'PASS' "4/4 hooks found"
} else {
    Add-Check 'Required hooks present' 'FAIL' "Missing: $($hookMissing -join ', ')"
}

# --- 3. Bridge exists ---
$bridgePath = Join-Path $HeliosGateRoot (& { if ($Platform -eq 'Windows') { 'hooks\lib\HeliosIntegrityBridge.ps1' } else { 'hooks/lib/HeliosIntegrityBridge.ps1' } })
if (Test-Path $bridgePath) {
    Add-Check 'Bridge exists' 'PASS' $bridgePath
} else {
    Add-Check 'Bridge exists' 'FAIL' "Not found: $bridgePath"
}

# --- 4. Policy exists ---
$policyPath = Join-Path $HeliosGateRoot (& { if ($Platform -eq 'Windows') { 'policy\command-policy.json' } else { 'policy/command-policy.json' } })
if (Test-Path $policyPath) {
    Add-Check 'Policy exists' 'PASS' $policyPath
} else {
    Add-Check 'Policy exists' 'FAIL' "Not found: $policyPath"
}

# --- 5. Manifest and sidecar exist ---
$manifestPath = Join-Path $HeliosGateRoot (& { if ($Platform -eq 'Windows') { 'manifest\helios-envelope.json' } else { 'manifest/helios-envelope.json' } })
$sidecarPath  = Join-Path $HeliosGateRoot (& { if ($Platform -eq 'Windows') { 'manifest\helios-envelope.sha256' } else { 'manifest/helios-envelope.sha256' } })

$manifestExists = Test-Path $manifestPath
$sidecarExists  = Test-Path $sidecarPath

if ($manifestExists -and $sidecarExists) {
    Add-Check 'Manifest and sidecar exist' 'PASS' 'Both present'
} else {
    $missing = @()
    if (-not $manifestExists) { $missing += 'manifest' }
    if (-not $sidecarExists) { $missing += 'sidecar' }
    Add-Check 'Manifest and sidecar exist' 'FAIL' "Missing: $($missing -join ', ')"
}

# --- 6. Manifest hash matches sidecar ---
$manifestIntegrity = 'SKIP'
$manifestDetail = 'Manifest or sidecar missing'
if ($manifestExists -and $sidecarExists) {
    $computedHash = Get-FileHash256 $manifestPath
    $sidecarHash = [System.IO.File]::ReadAllText($sidecarPath).Trim()
    if ($computedHash -eq $sidecarHash) {
        $manifestIntegrity = 'CLEAN'
        Add-Check 'Manifest sidecar integrity' 'PASS' "Match: $computedHash"
    } else {
        $manifestIntegrity = 'DRIFT'
        Add-Check 'Manifest sidecar integrity' 'FAIL' "Computed: $computedHash, Sidecar: $sidecarHash"
    }
}

# --- 7. Protected file hashes match manifest ---
$hashResults = [ordered]@{}
$allHashesMatch = $true
if ($manifestExists) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.protected -and $manifest.protected.hashes) {
        foreach ($prop in $manifest.protected.hashes.PSObject.Properties) {
            $relPath = $prop.Name
            $expectedHash = $prop.Value
            $fullPath = Join-Path $HeliosGateRoot ($relPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            if (Test-Path $fullPath) {
                $actualHash = Get-FileHash256 $fullPath
                $match = $actualHash -eq $expectedHash
                $hashResults[$relPath] = [ordered]@{ expected = $expectedHash; actual = $actualHash; match = $match }
                if (-not $match) { $allHashesMatch = $false }
            } else {
                $hashResults[$relPath] = [ordered]@{ expected = $expectedHash; actual = 'MISSING'; match = $false }
                $allHashesMatch = $false
            }
        }
    }
    $hashCount = $hashResults.Count
    if ($allHashesMatch -and $hashCount -gt 0) {
        Add-Check 'Protected file hashes' 'PASS' "$hashCount/$hashCount match manifest"
    } elseif ($hashCount -gt 0) {
        $drifted = @($hashResults.Keys | Where-Object { -not $hashResults[$_].match })
        Add-Check 'Protected file hashes' 'FAIL' "Drift in: $($drifted -join ', ')"
    }
} else {
    Add-Check 'Protected file hashes' 'FAIL' 'No manifest to verify against'
    $allHashesMatch = $false
}

# --- 8. Mutable directories exist and are writable ---
$mutableDirs = @('pending', 'inflight', 'evidence', 'blocked')
$mutableMissing = @()
$mutableNotWritable = @()
foreach ($d in $mutableDirs) {
    $full = Join-Path $HeliosGateRoot $d
    if (-not (Test-Path $full)) { $mutableMissing += $d; continue }
    $testFile = Join-Path $full '.write-test'
    try {
        [System.IO.File]::WriteAllText($testFile, 'test', $Utf8NoBom)
        Remove-Item $testFile -Force
    } catch {
        $mutableNotWritable += $d
    }
}
if ($mutableMissing.Count -eq 0 -and $mutableNotWritable.Count -eq 0) {
    Add-Check 'Mutable directories writable' 'PASS' "4/4 writable"
} else {
    $detail = @()
    if ($mutableMissing.Count -gt 0) { $detail += "Missing: $($mutableMissing -join ', ')" }
    if ($mutableNotWritable.Count -gt 0) { $detail += "Not writable: $($mutableNotWritable -join ', ')" }
    Add-Check 'Mutable directories writable' 'FAIL' ($detail -join '; ')
}

# --- 9. Settings point to intended hooks ---
$settingsCheck = 'FAIL'
$settingsDetail = "Settings not found: $ClaudeSettingsPath"
$hookPointsCorrect = $false
if (Test-Path $ClaudeSettingsPath) {
    $settingsRaw = [System.IO.File]::ReadAllText($ClaudeSettingsPath)
    $settings = $settingsRaw | ConvertFrom-Json
    if ($settings.hooks) {
        $preOk = $false; $postOk = $false; $failOk = $false
        if ($settings.hooks.PreToolUse) {
            foreach ($e in $settings.hooks.PreToolUse) {
                foreach ($h in $e.hooks) {
                    if ($h.command -like '*helios_pretooluse*') { $preOk = $true }
                }
            }
        }
        if ($settings.hooks.PostToolUse) {
            foreach ($e in $settings.hooks.PostToolUse) {
                foreach ($h in $e.hooks) {
                    if ($h.command -like '*evidence_capture*') { $postOk = $true }
                }
            }
        }
        if ($settings.hooks.PostToolUseFailure) {
            foreach ($e in $settings.hooks.PostToolUseFailure) {
                foreach ($h in $e.hooks) {
                    if ($h.command -like '*evidence_capture*') { $failOk = $true }
                }
            }
        }
        if ($preOk -and $postOk -and $failOk) {
            $settingsCheck = 'PASS'
            $settingsDetail = 'PreToolUse, PostToolUse, PostToolUseFailure all configured'
            $hookPointsCorrect = $true
        } else {
            $missing = @()
            if (-not $preOk) { $missing += 'PreToolUse' }
            if (-not $postOk) { $missing += 'PostToolUse' }
            if (-not $failOk) { $missing += 'PostToolUseFailure' }
            $settingsDetail = "Missing hooks: $($missing -join ', ')"
        }
    } else {
        $settingsDetail = 'No hooks section in settings'
    }
}
Add-Check 'Settings hook configuration' $settingsCheck $settingsDetail

# --- 10. Lock status ---
$lockStatus = 'UNKNOWN'
$lockDetail = 'Lock status check not implemented in this tool (use AkashicLockStatus.ps1)'
Add-Check 'Lock status' 'INFO' $lockDetail

# --- 11. Gate lifecycle ---
$pendingDir = Join-Path $HeliosGateRoot 'pending'
$evidenceDir = Join-Path $HeliosGateRoot 'evidence'
$pendingCount = 0; $evidenceCount = 0
if (Test-Path $pendingDir) {
    $pendingCount = (Get-ChildItem $pendingDir -Filter '*.gate.json' -ErrorAction SilentlyContinue | Measure-Object).Count
}
if (Test-Path $evidenceDir) {
    $evidenceCount = (Get-ChildItem $evidenceDir -Filter '*.gate.json' -ErrorAction SilentlyContinue | Measure-Object).Count
}
Add-Check 'Gate lifecycle' 'INFO' "Pending: $pendingCount, Evidence: $evidenceCount"

# --- Summary ---
$overallStatus = if ($failures.Count -eq 0) { 'PASS' } else { 'FAIL' }
Write-Host ""
Write-Host "=== Overall: $overallStatus ($($checks.Count) checks, $($failures.Count) failures) ==="

$result = [ordered]@{
    schema_version      = 'helios-live-operational-check.v1'
    timestamp_utc       = (Get-Date).ToUniversalTime().ToString('o')
    helios_gate_root    = $HeliosGateRoot
    claude_settings_path = $ClaudeSettingsPath
    platform            = $Platform
    checks              = [object[]]$checks
    manifest_integrity  = $manifestIntegrity
    protected_hash_results = $hashResults
    hook_points_correct = $hookPointsCorrect
    pending_gates       = $pendingCount
    evidence_gates      = $evidenceCount
    failures            = [string[]]$failures
    overall_status      = $overallStatus
    note                = 'Automated static checks only. Live hook execution (interception, gate approval, evidence capture) requires real Claude tool calls.'
}

if ($EvidenceOutputDir) {
    if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
    $evPath = Join-Path $EvidenceOutputDir 'live-operational-check.json'
    [System.IO.File]::WriteAllText($evPath, ($result | ConvertTo-Json -Depth 10), $Utf8NoBom)
    Write-Host "Evidence: $evPath"
}

return $result
