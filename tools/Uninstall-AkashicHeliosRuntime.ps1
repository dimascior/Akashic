[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [ValidateSet('Auto', 'Windows', 'macOS', 'Linux')]
    [string]$Platform = 'Auto',

    [switch]$RestoreSettingsBackup,
    [switch]$ForceDestructive,
    [switch]$RemoveEvidence,

    [string]$UninstalledBy = 'uninstall-tool',
    [string]$ClaudeSettingsPath,
    [string]$EvidenceOutputDir
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

if (-not $ClaudeSettingsPath) {
    $ClaudeSettingsPath = switch ($Platform) {
        'Windows' { Join-Path $env:USERPROFILE '.claude\settings.json' }
        default   { Join-Path $env:HOME '.claude/settings.json' }
    }
}

if (-not $EvidenceOutputDir) {
    $EvidenceOutputDir = Join-Path $AkashicRoot 'evidence\phase432c'
}

function Get-FileHash256([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

$steps = [System.Collections.Generic.List[object]]::new()
$ts = (Get-Date).ToUniversalTime()
$tsString = $ts.ToString('yyyy-MM-ddTHH:mm:ssZ')
$tsFileSafe = $ts.ToString('yyyyMMdd-HHmmss')

$hooksRemoved = $false
$settingsBackupRestored = $false
$filesUnlocked = $false
$runtimeArchived = $false
$runtimeRemoved = $false
$manifestArchived = $false
$originArchived = $false
$protectedArchived = $false
$evidencePreserved = $true
$runtimeArchivePath = $null
$settingsBackupPath = "$ClaudeSettingsPath.pre-helios-backup"
$settingsBackupHash = $null
$settingsAfterHash = $null
$preservedEvidencePath = $null

function Add-Step([string]$Name, [string]$Status, $Detail) {
    $steps.Add([ordered]@{ step = $Name; status = $Status; detail = $Detail })
    $mark = switch ($Status) {
        'PASS' { '[PASS]' }; 'FAIL' { '[FAIL]' }
        'SKIP' { '[SKIP]' }; 'WARN' { '[WARN]' }
        default { "[$Status]" }
    }
    Write-Host "$mark $Name"
}

Write-Host '=== Helios Runtime Uninstall ==='
Write-Host "Platform:       $Platform"
Write-Host "AkashicRoot:    $AkashicRoot"
Write-Host "HeliosGateRoot: $HeliosGateRoot"
Write-Host "Mode:           $(if ($ForceDestructive) { 'destructive' } else { 'archive' })"
Write-Host ''

# ============================================================
# Step 1: Assert Akashic trusted
# ============================================================
& (Join-Path $ScriptDir 'Assert-AkashicTrusted.ps1')
Add-Step 'Assert Akashic trusted' 'PASS' 'Self-integrity verified'

# ============================================================
# Step 2: Remove Helios hooks from Claude settings
# ============================================================
$preUninstallHooksActive = $null
if (Test-Path $ClaudeSettingsPath) {
    try {
        $settingsRaw = Get-Content -LiteralPath $ClaudeSettingsPath -Raw | ConvertFrom-Json
        $preUninstallHooksActive = ($settingsRaw.hooks -and $settingsRaw.hooks.PreToolUse)
    } catch {
        $preUninstallHooksActive = $null
    }
}

$removeArgs = @{
    ClaudeSettingsPath = $ClaudeSettingsPath
    Platform           = $Platform
}
if ($RestoreSettingsBackup) { $removeArgs['RestoreFromBackup'] = $true }

try {
    $hookResult = & (Join-Path $ScriptDir 'Remove-AkashicClaudeHooks.ps1') @removeArgs

    if ($hookResult.status -eq 'DEACTIVATED') {
        $hooksRemoved = $true
        if ($RestoreSettingsBackup) { $settingsBackupRestored = $true }
        Add-Step 'Remove Helios hooks' 'PASS' ([ordered]@{
            method = $hookResult.method
            status = $hookResult.status
        })
    } elseif ($hookResult.status -match 'NO.*HOOKS') {
        Add-Step 'Remove Helios hooks' 'SKIP' 'No Helios hooks found in settings'
    } else {
        Add-Step 'Remove Helios hooks' 'WARN' "Status: $($hookResult.status)"
    }
} catch {
    Add-Step 'Remove Helios hooks' 'FAIL' "Hook removal failed: $_"
}

$settingsBackupHash = if (Test-Path $settingsBackupPath) { Get-FileHash256 $settingsBackupPath } else { $null }
$settingsAfterHash  = if (Test-Path $ClaudeSettingsPath) { Get-FileHash256 $ClaudeSettingsPath } else { $null }

# Verify hooks are actually gone
$postUninstallHooksActive = $false
if (Test-Path $ClaudeSettingsPath) {
    try {
        $settingsCheck = Get-Content -LiteralPath $ClaudeSettingsPath -Raw | ConvertFrom-Json
        $postUninstallHooksActive = ($null -ne $settingsCheck.hooks -and $null -ne $settingsCheck.hooks.PreToolUse)
    } catch {}
}

# ============================================================
# Step 3: Unlock runtime protected files if locked
# ============================================================
$testLockFile = Join-Path $HeliosGateRoot ('hooks\gate_check.ps1'.Replace('\', $sep))
if (Test-Path $testLockFile) {
    $isLocked = $false
    try { [System.IO.File]::OpenWrite($testLockFile).Close() } catch { $isLocked = $true }
    if ($isLocked) {
        $unlockScript = Join-Path $ScriptDir 'Unlock-AkashicProtectedFiles.ps1'
        if (Test-Path $unlockScript) {
            & $unlockScript -HeliosGateRoot $HeliosGateRoot
            $filesUnlocked = $true
            Add-Step 'Unlock runtime files' 'PASS' 'Protected files unlocked'
        } else {
            Add-Step 'Unlock runtime files' 'WARN' 'Files locked but unlock tool not found'
        }
    } else {
        Add-Step 'Unlock runtime files' 'SKIP' 'Files already writable'
    }
} else {
    Add-Step 'Unlock runtime files' 'SKIP' 'No runtime files found to unlock'
}

# ============================================================
# Step 4-5: Archive HeliosGateRoot
# ============================================================
$archiveDir = Join-Path $HeliosGateRoot "maintenance\archives\$tsFileSafe-uninstall"
$archiveSubDirs = @('', 'manifest', 'protected', 'protected\hooks', 'protected\hooks\lib', 'protected\policy', 'metadata')
foreach ($d in $archiveSubDirs) {
    $p = if ($d) { Join-Path $archiveDir $d } else { $archiveDir }
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$archiveIndex = [ordered]@{
    archive_utc      = $tsString
    operation        = 'uninstall'
    source_authority = 'None'
    helios_gate_root = $HeliosGateRoot
    files            = [System.Collections.Generic.List[object]]::new()
}

$manifestPath = Join-Path $HeliosGateRoot ('manifest\helios-envelope.json'.Replace('\', $sep))
$originPath   = Join-Path $HeliosGateRoot ('manifest\helios-install-origin.json'.Replace('\', $sep))

foreach ($mf in @('helios-envelope.json', 'helios-envelope.sha256', 'helios-install-origin.json')) {
    $src = Join-Path $HeliosGateRoot "manifest\$mf"
    if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $archiveDir "manifest\$mf") -Force
        $h = Get-FileHash256 $src
        $archiveIndex.files.Add([ordered]@{ path = "manifest/$mf"; hash = $h; size = (Get-Item $src).Length })
        if ($mf -eq 'helios-envelope.json') { $manifestArchived = $true }
        if ($mf -eq 'helios-install-origin.json') { $originArchived = $true }
    }
}

$protectedRelPaths = @(
    'hooks/helios_pretooluse.ps1', 'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1', 'hooks/tier_classifier.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1', 'policy/command-policy.json'
)

$anyProtected = $false
foreach ($rel in $protectedRelPaths) {
    $src = Join-Path $HeliosGateRoot ($rel.Replace('/', $sep))
    if (Test-Path $src) {
        $anyProtected = $true
        $dest = Join-Path $archiveDir "protected\$($rel.Replace('/', $sep))"
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $h = Get-FileHash256 $src
        $archiveIndex.files.Add([ordered]@{ path = "protected/$rel"; hash = $h; size = (Get-Item $src).Length })
    }
}
if ($anyProtected) { $protectedArchived = $true }

$archiveIndexPath = Join-Path $archiveDir 'metadata\archive-index.json'
[System.IO.File]::WriteAllText($archiveIndexPath, ($archiveIndex | ConvertTo-Json -Depth 10), $Utf8NoBom)

$runtimeArchived = $true
$runtimeArchivePath = $archiveDir
Add-Step 'Archive runtime' 'PASS' ([ordered]@{
    archive_path = $archiveDir
    file_count   = $archiveIndex.files.Count
})

# ============================================================
# Step 5: Preserve evidence
# ============================================================
$evidenceDir = Join-Path $HeliosGateRoot 'evidence'
if ((Test-Path $evidenceDir) -and -not $RemoveEvidence) {
    $evidencePreserved = $true
    $preservedEvidencePath = $evidenceDir
    Add-Step 'Preserve evidence' 'PASS' "Evidence preserved at $evidenceDir"
} elseif ($RemoveEvidence) {
    $evidencePreserved = $false
    Add-Step 'Preserve evidence' 'SKIP' 'Evidence removal requested; will be removed with -ForceDestructive'
} else {
    Add-Step 'Preserve evidence' 'SKIP' 'No evidence directory found'
}

# ============================================================
# Step 6-7: Remove active runtime (destructive only)
# ============================================================
if ($ForceDestructive) {
    $removeDirs = @('hooks', 'policy', 'manifest', 'templates', 'schemas', 'pending', 'inflight', 'blocked')
    if ($RemoveEvidence) { $removeDirs += 'evidence' }

    $removedCount = 0
    foreach ($d in $removeDirs) {
        $dp = Join-Path $HeliosGateRoot $d
        if (Test-Path $dp) {
            Remove-Item -LiteralPath $dp -Recurse -Force -Confirm:$false
            $removedCount++
        }
    }

    $runtimeRemoved = $true
    Add-Step 'Remove active runtime' 'PASS' ([ordered]@{
        directories_removed = $removedCount
        evidence_removed    = [bool]$RemoveEvidence
    })
} else {
    Add-Step 'Remove active runtime' 'SKIP' 'Not requested (pass -ForceDestructive to remove)'
}

# ============================================================
# Determine overall
# ============================================================
$anyFail = $steps | Where-Object { $_.status -eq 'FAIL' }
$overall = if ($anyFail) { 'PARTIAL' } else { 'COMPLETE' }

# ============================================================
# Step 8: Write uninstall evidence
# ============================================================
$uninstallMode = if ($ForceDestructive) { 'destructive' } else { 'archive' }

$uninstallEvidence = [ordered]@{
    schema_version              = 'helios-runtime-uninstall-evidence.v1'
    timestamp_utc               = $tsString
    platform                    = $Platform
    uninstalled_by              = $UninstalledBy
    operation_type              = 'Uninstall'
    source_authority            = 'None'
    akashic_root                = $AkashicRoot
    helios_gate_root            = $HeliosGateRoot
    claude_settings_path        = $ClaudeSettingsPath

    uninstall_mode              = $uninstallMode
    pre_uninstall_hooks_active  = $preUninstallHooksActive
    post_uninstall_hooks_active = $postUninstallHooksActive
    hooks_removed               = $hooksRemoved
    settings_backup_path        = if (Test-Path $settingsBackupPath) { $settingsBackupPath } else { $null }
    settings_backup_hash        = $settingsBackupHash
    settings_after_hash         = $settingsAfterHash
    settings_backup_restored    = $settingsBackupRestored

    files_unlocked              = $filesUnlocked
    runtime_archived            = $runtimeArchived
    runtime_removed             = $runtimeRemoved
    runtime_archive_path        = $runtimeArchivePath
    manifest_archived           = $manifestArchived
    origin_archived             = $originArchived
    protected_files_archived    = $protectedArchived
    evidence_preserved          = $evidencePreserved
    preserved_evidence_path     = $preservedEvidencePath
    remove_evidence_requested   = [bool]$RemoveEvidence
    force_destructive           = [bool]$ForceDestructive

    steps                       = [object[]]$steps
    overall                     = $overall
}

$uninstallJson = $uninstallEvidence | ConvertTo-Json -Depth 10

if (-not (Test-Path $EvidenceOutputDir)) { New-Item -ItemType Directory -Path $EvidenceOutputDir -Force | Out-Null }
$phasePath = Join-Path $EvidenceOutputDir "uninstall-evidence-$tsFileSafe.json"
[System.IO.File]::WriteAllText($phasePath, $uninstallJson, $Utf8NoBom)

$archiveEvidencePath = Join-Path $archiveDir 'metadata\uninstall-evidence.json'
[System.IO.File]::WriteAllText($archiveEvidencePath, $uninstallJson, $Utf8NoBom)

Add-Step 'Write uninstall evidence' 'PASS' ([ordered]@{
    akashic_evidence = $phasePath
    archive_evidence = $archiveEvidencePath
})

Write-Host ''
Write-Host "=== Uninstall $overall ==="
Write-Host "  Mode:     $uninstallMode"
Write-Host "  Hooks:    $(if ($hooksRemoved) { 'removed' } else { 'unchanged' })"
Write-Host "  Runtime:  $(if ($runtimeRemoved) { 'removed' } elseif ($runtimeArchived) { 'archived' } else { 'unchanged' })"
Write-Host "  Evidence: $(if ($evidencePreserved) { 'preserved' } else { 'removed' })"
Write-Host "  Archive:  $runtimeArchivePath"
Write-Host ''

return $uninstallEvidence
