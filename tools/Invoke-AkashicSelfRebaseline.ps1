# Invoke-AkashicSelfRebaseline.ps1 - Human maintenance rebaseline for Akashic self-manifest
# Unlock (if locked) -> regenerate manifest -> verify integrity -> optionally re-lock.
# This is the explicit path for accepting intentional changes to Akashic files.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$RebaselinedBy,

    [string]$Note,

    [switch]$RelockAfter,

    [ValidateSet('Auto', 'None', 'Sudo', 'Doas', 'RootOnly')]
    [string]$PrivilegeMode = 'Auto',

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $AkashicRoot 'evidence\phase43'
}

$steps = [System.Collections.Generic.List[object]]::new()

function Add-Step([string]$Name, [string]$Status, $Detail) {
    $steps.Add([ordered]@{ step = $Name; status = $Status; detail = $Detail })
    $mark = switch ($Status) { 'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }; 'SKIP' { '[SKIP]' }; default { "[$Status]" } }
    Write-Host "$mark $Name"
}

Write-Host '=== Akashic Self-Rebaseline ==='
Write-Host "  Root:          $AkashicRoot"
Write-Host "  RebaselinedBy: $RebaselinedBy"
Write-Host ''

# Step 1: Unlock if needed
$unlockScript = Join-Path $ScriptDir 'Unlock-AkashicRoot.ps1'
$manifestPath = Join-Path $AkashicRoot 'manifest\akashic-envelope.json'
if (Test-Path $manifestPath) {
    try {
        [System.IO.File]::OpenWrite($manifestPath).Close()
        Add-Step 'Unlock' 'SKIP' 'manifest is writable'
    } catch {
        if (Test-Path $unlockScript) {
            & $unlockScript -AkashicRoot $AkashicRoot -PrivilegeMode $PrivilegeMode
            Add-Step 'Unlock' 'PASS' 'unlocked protected files'
        } else {
            Add-Step 'Unlock' 'FAIL' 'Unlock-AkashicRoot.ps1 not found'
            throw 'Cannot rebaseline: files are locked and unlock tool is missing.'
        }
    }
} else {
    Add-Step 'Unlock' 'SKIP' 'no existing manifest'
}

# Step 2: Regenerate manifest
$manifestScript = Join-Path $ScriptDir 'New-AkashicSelfManifest.ps1'
$manifestArgs = @{
    AkashicRoot   = $AkashicRoot
    RebaselinedBy = $RebaselinedBy
}
if ($Note) { $manifestArgs['Note'] = $Note }
$manifestResult = & $manifestScript @manifestArgs
Add-Step 'Regenerate manifest' 'PASS' ([ordered]@{
    protected_count  = $manifestResult.protected_count
    manifest_hash    = $manifestResult.manifest_hash
    signature_status = $manifestResult.signature_status
})

# Step 3: Verify integrity
$verifyScript = Join-Path $ScriptDir 'Test-AkashicSelfIntegrity.ps1'
$verifyResult = & $verifyScript -AkashicRoot $AkashicRoot -EvidenceOutputDir $EvidenceOutputDir
if ($verifyResult.verdict -eq 'CLEAN') {
    Add-Step 'Verify integrity' 'PASS' ([ordered]@{
        verdict         = $verifyResult.verdict
        protected_count = $verifyResult.protected_file_count
        clean_count     = $verifyResult.clean_count
    })
} else {
    Add-Step 'Verify integrity' 'FAIL' ([ordered]@{
        verdict    = $verifyResult.verdict
        drift      = $verifyResult.drift_count
        missing    = $verifyResult.missing_count
    })
}

# Step 4: Re-lock if requested
if ($RelockAfter) {
    $lockScript = Join-Path $ScriptDir 'Lock-AkashicRoot.ps1'
    if (Test-Path $lockScript) {
        try {
            & $lockScript -AkashicRoot $AkashicRoot -PrivilegeMode $PrivilegeMode
            Add-Step 'Re-lock' 'PASS' 'protected files re-locked'
        } catch {
            Add-Step 'Re-lock' 'FAIL' $_.Exception.Message
        }
    } else {
        Add-Step 'Re-lock' 'FAIL' 'Lock-AkashicRoot.ps1 not found'
    }
} else {
    Add-Step 'Re-lock' 'SKIP' 'not requested (pass -RelockAfter)'
}

$overall = 'COMPLETE'
$anyFail = $steps | Where-Object { $_.status -eq 'FAIL' }
if ($anyFail) { $overall = 'PARTIAL' }

Write-Host ''
Write-Host "=== Rebaseline $overall ==="

$evidence = [ordered]@{
    schema_version   = 'akashic-self-integrity-evidence.v1'
    timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
    akashic_root     = $AkashicRoot
    rebaselined_by   = $RebaselinedBy
    overall          = $overall
    steps            = @($steps)
    manifest_hash    = $manifestResult.manifest_hash
    protected_count  = $manifestResult.protected_count
    signature_status = $manifestResult.signature_status
    verify_verdict   = $verifyResult.verdict
}

if ($EvidenceOutputDir) {
    if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
    $evPath = Join-Path $EvidenceOutputDir 'akashic-self-rebaseline-evidence.json'
    [System.IO.File]::WriteAllText($evPath, ($evidence | ConvertTo-Json -Depth 10), $Utf8NoBom)
    Write-Host "Evidence: $evPath"
}

return $evidence
