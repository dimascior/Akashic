# helios_pretooluse.ps1 — Helios PreToolUse front controller
# Integrity verification BEFORE any policy code loads.
# Replaces gate_check.ps1 as the PreToolUse hook entry point.
# When dot-sourced with $HeliosDotSourceFunctionsOnly = $true, exports
# helper functions without executing the main flow.

$ErrorActionPreference = 'Stop'

$GateRoot = Split-Path $PSScriptRoot -Parent

# --- Inline utilities (no external dependencies) ---

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash($Bytes)
    return ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Deny {
    param([string]$Reason)
    $Out = @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $Reason
        }
    }
    Write-Output ($Out | ConvertTo-Json -Depth 5 -Compress)
    exit 0
}

function DenyFatal {
    param([string]$Reason)
    Deny $Reason
}

function Write-IntegrityDecision {
    param([string]$SessionId, [string]$ToolUseId, [hashtable]$Data)
    try {
        $dir = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\commands"
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $path = Join-Path $dir "$ToolUseId.decision.json"
        $Data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {}
}

# --- Maintenance rebaseline corridor helpers ---

function Read-MaintenanceRebaselineRequest {
    param([string]$Root)
    $reqPath = Join-Path $Root 'maintenance\rebaseline-request.json'
    if (-not (Test-Path $reqPath)) { return $null }
    try {
        $req = Get-Content $reqPath -Raw | ConvertFrom-Json
        return @{ request = $req; path = $reqPath }
    } catch { return $null }
}

function Test-MaintenanceRebaselineRequest {
    param($Request, [string]$SidecarHash, [string[]]$ActualDriftPaths, [hashtable]$MHashes)
    if ($null -eq $Request) { return @{ valid = $false; reason = 'No maintenance request found' } }
    $req = $Request.request
    if ($req.schema_version -ne 'helios-maintenance-rebaseline.v1') {
        return @{ valid = $false; reason = "Invalid schema_version: $($req.schema_version)" }
    }
    if ($req.write_mode -ne 'front_controller_internal_rebaseline') {
        return @{ valid = $false; reason = "Invalid write_mode: $($req.write_mode)" }
    }
    try {
        $expires = [DateTime]::Parse($req.expires_utc).ToUniversalTime()
        if ($expires -le (Get-Date).ToUniversalTime()) {
            return @{ valid = $false; reason = "Request expired at $($req.expires_utc)" }
        }
    } catch {
        return @{ valid = $false; reason = "Cannot parse expires_utc: $($req.expires_utc)" }
    }
    if ($req.base_manifest_hash -ne $SidecarHash) {
        return @{ valid = $false; reason = "base_manifest_hash mismatch: request=$($req.base_manifest_hash) sidecar=$SidecarHash" }
    }
    $expectedPaths = @($req.expected_drift_paths | Sort-Object)
    $actualPaths = @($ActualDriftPaths | Sort-Object)
    if ($expectedPaths.Count -ne $actualPaths.Count) {
        return @{ valid = $false; reason = "Drift path count mismatch: expected=$($expectedPaths.Count) actual=$($actualPaths.Count)" }
    }
    for ($i = 0; $i -lt $expectedPaths.Count; $i++) {
        if ($expectedPaths[$i] -ne $actualPaths[$i]) {
            return @{ valid = $false; reason = "Drift path mismatch at index $i" }
        }
    }
    foreach ($p in $actualPaths) {
        if (-not $MHashes.ContainsKey($p)) {
            return @{ valid = $false; reason = "Drift path '$p' is not in manifest protected hashes" }
        }
    }
    return @{ valid = $true }
}

function Invoke-InternalRebaseline {
    param([string]$Root, $Request, [hashtable]$MHashes)
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $newHashes = [ordered]@{}
    foreach ($relPath in ($MHashes.Keys | Sort-Object)) {
        $fullPath = Join-Path $Root $relPath
        $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $hash = ($sha.ComputeHash($fileBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
        $newHashes[$relPath] = $hash
    }
    $req = $Request.request
    $manifest = [ordered]@{
        schema_version = 'helios-envelope.v1'
        created_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        rebaselined_by = $req.requested_by
        protected      = [ordered]@{
            description = 'Must not change during gated execution'
            paths       = @(
                'hooks/gate_check.ps1', 'hooks/evidence_capture.ps1',
                'hooks/tier_classifier.ps1', 'hooks/helios_pretooluse.ps1',
                'hooks/lib/HeliosIntegrityBridge.ps1', 'policy/command-policy.json',
                'manifest/helios-envelope.json', 'manifest/helios-envelope.sha256'
            )
            hashes      = $newHashes
        }
        mutable        = [ordered]@{
            description = 'Must change as part of gate lifecycle'
            dirs        = @('pending/', 'inflight/', 'evidence/', 'blocked/')
        }
        note           = $req.reason
    }
    $mPath = Join-Path $Root 'manifest\helios-envelope.json'
    $mJson = $manifest | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($mPath, $mJson, $Utf8NoBom)
    $mBytes = [System.IO.File]::ReadAllBytes($mPath)
    $mHash = ($sha.ComputeHash($mBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    $sPath = Join-Path $Root 'manifest\helios-envelope.sha256'
    [System.IO.File]::WriteAllText($sPath, $mHash, $Utf8NoBom)
    return @{ new_manifest_hash = $mHash; updated_hashes = $newHashes }
}

# --- Dot-source guard: export functions only ---
if ($HeliosDotSourceFunctionsOnly) { return }

# --- Step 1: Read stdin ---

$RawInput = $null
try {
    $RawInput = [Console]::In.ReadToEnd()
} catch {
    DenyFatal 'Cannot read stdin'
}

if ([string]::IsNullOrWhiteSpace($RawInput)) {
    DenyFatal 'Empty stdin'
}

$Payload = $null
try {
    $Payload = $RawInput | ConvertFrom-Json
} catch {
    DenyFatal "Cannot parse hook payload: $($_.Exception.Message)"
}

# --- Step 2: Non-shell passthrough ---

$ToolName = $Payload.tool_name
if ($ToolName -notin @('Bash', 'PowerShell')) {
    Write-Output '{}'
    exit 0
}

$SessionId  = $Payload.session_id
$ToolUseId  = $Payload.tool_use_id
$Cwd        = $Payload.cwd
$Shell      = $ToolName.ToLower()
$Command    = $null
if ($Payload.tool_input -and $Payload.tool_input.command) {
    $Command = $Payload.tool_input.command
}

$CommandHash = ''
if ($Command) {
    $CommandHash = Get-BytesSha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($Command))
}


# --- Step 3: Locate manifest ---

$ManifestPath = Join-Path $GateRoot 'manifest\helios-envelope.json'
$SidecarPath  = Join-Path $GateRoot 'manifest\helios-envelope.sha256'

if (-not (Test-Path $ManifestPath) -or -not (Test-Path $SidecarPath)) {
    Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
        timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
        verdict       = 'INTEGRITY_FAILURE'
        reason        = 'Manifest files missing'
        session_id    = $SessionId
        tool_use_id   = $ToolUseId
    }
    DenyFatal 'INTEGRITY: manifest files missing'
}

# --- Step 4: Sidecar verification ---

$ManifestBytes = [System.IO.File]::ReadAllBytes($ManifestPath)
$ManifestHash  = Get-BytesSha256 -Bytes $ManifestBytes
$SidecarHash   = ([System.IO.File]::ReadAllText($SidecarPath)).Trim().ToLower()

if ($ManifestHash -ne $SidecarHash) {
    Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
        timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
        verdict          = 'INTEGRITY_FAILURE'
        reason           = 'Manifest sidecar mismatch'
        computed_hash    = $ManifestHash
        sidecar_hash     = $SidecarHash
        session_id       = $SessionId
        tool_use_id      = $ToolUseId
        command_sha256   = $CommandHash
    }
    DenyFatal "INTEGRITY: manifest sidecar mismatch (computed=$ManifestHash sidecar=$SidecarHash)"
}

# --- Step 5: Parse manifest ---

# Get-Content -Raw handles BOM stripping; ReadAllBytes above preserves raw bytes for hash comparison
$Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json

$ManifestHashes = @{}
foreach ($prop in $Manifest.protected.hashes.PSObject.Properties) {
    $ManifestHashes[$prop.Name] = $prop.Value
}

# --- Step 6-7: Verify all protected file hashes ---

$DriftedFiles = @()
foreach ($relPath in $ManifestHashes.Keys) {
    $fullPath = Join-Path $GateRoot $relPath
    if (-not (Test-Path $fullPath)) {
        $DriftedFiles += @{ path = $relPath; reason = 'MISSING'; expected = $ManifestHashes[$relPath]; actual = $null }
        continue
    }
    $fileBytes = [System.IO.File]::ReadAllBytes($fullPath)
    $fileHash  = Get-BytesSha256 -Bytes $fileBytes
    if ($fileHash -ne $ManifestHashes[$relPath]) {
        $DriftedFiles += @{ path = $relPath; reason = 'HASH_MISMATCH'; expected = $ManifestHashes[$relPath]; actual = $fileHash }
    }
}

# --- Step 8: On drift, check maintenance corridor or deny ---

if ($DriftedFiles.Count -gt 0) {
    $driftPaths = ($DriftedFiles | ForEach-Object { $_.path }) -join ', '
    $driftPathList = @($DriftedFiles | ForEach-Object { $_.path })

    try {
        $beforeDir = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\commands"
        if (-not (Test-Path $beforeDir)) { New-Item -ItemType Directory -Path $beforeDir -Force | Out-Null }
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $beforeData = @{
            timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
            session_id     = $SessionId
            tool_use_id    = $ToolUseId
            command_sha256 = $CommandHash
            drifted_files  = $DriftedFiles
            integrity_status = 'DRIFT'
        }
        $beforePath = Join-Path $beforeDir "$ToolUseId.before.json"
        [System.IO.File]::WriteAllText($beforePath, ($beforeData | ConvertTo-Json -Depth 5), $Utf8NoBom)
    } catch {}

    # --- Maintenance rebaseline corridor ---
    $MaintReq = Read-MaintenanceRebaselineRequest -Root $GateRoot
    $MaintResult = Test-MaintenanceRebaselineRequest `
        -Request $MaintReq -SidecarHash $SidecarHash `
        -ActualDriftPaths $driftPathList -MHashes $ManifestHashes

    if ($MaintResult.valid) {
        try {
            $rebaseResult = Invoke-InternalRebaseline -Root $GateRoot -Request $MaintReq -MHashes $ManifestHashes

            $NowUtc = (Get-Date).ToUniversalTime()
            $Ts = $NowUtc.ToString('yyyyMMdd-HHmmss')
            $reqId = $MaintReq.request.request_id
            $evidenceDir = Join-Path $GateRoot 'evidence\maintenance'
            if (-not (Test-Path $evidenceDir)) { New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null }

            $Utf8Evi = New-Object System.Text.UTF8Encoding($false)
            $evidence = @{
                request_id                = $reqId
                requested_by              = $MaintReq.request.requested_by
                reason                    = $MaintReq.request.reason
                timestamp_utc             = $NowUtc.ToString('o')
                base_manifest_hash        = $MaintReq.request.base_manifest_hash
                new_manifest_hash         = $rebaseResult.new_manifest_hash
                expected_drift_paths      = @($MaintReq.request.expected_drift_paths)
                actual_drift_paths        = $driftPathList
                updated_hashes            = $rebaseResult.updated_hashes
                result                    = 'MAINTENANCE_REBASELINE_COMPLETE'
                triggering_tool_use_id    = $ToolUseId
                triggering_command_sha256 = $CommandHash
            }
            $evidencePath = Join-Path $evidenceDir "$Ts-$reqId.json"
            [System.IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 5), $Utf8Evi)

            $reqDest = Join-Path $evidenceDir "$Ts-$reqId.request.json"
            Move-Item -Path $MaintReq.path -Destination $reqDest -Force

            # Invalidate session baseline — hashes changed, baseline is stale
            $sessionBaselinePath = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\baseline.json"
            if (Test-Path $sessionBaselinePath) {
                $staleBaseline = Join-Path $evidenceDir "$Ts-$reqId.stale-baseline.json"
                Move-Item -Path $sessionBaselinePath -Destination $staleBaseline -Force
            }

            Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
                timestamp_utc     = $NowUtc.ToString('o')
                verdict           = 'MAINTENANCE_REBASELINE_COMPLETE'
                reason            = "Internal rebaseline completed. New manifest hash: $($rebaseResult.new_manifest_hash). Retry command."
                request_id        = $reqId
                new_manifest_hash = $rebaseResult.new_manifest_hash
                session_id        = $SessionId
                tool_use_id       = $ToolUseId
                command_sha256    = $CommandHash
            }

            Deny "MAINTENANCE_REBASELINE_COMPLETE: manifest repaired for drifted files: $driftPaths. New hash: $($rebaseResult.new_manifest_hash). Retry your command."
        } catch {
            Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
                timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
                verdict        = 'MAINTENANCE_REBASELINE_FAILED'
                reason         = "Internal rebaseline failed: $($_.Exception.Message)"
                session_id     = $SessionId
                tool_use_id    = $ToolUseId
                command_sha256 = $CommandHash
            }
            DenyFatal "INTEGRITY: maintenance rebaseline failed: $($_.Exception.Message). Protected drift in: $driftPaths"
        }
    }

    # No valid maintenance request — standard drift denial
    Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
        timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
        verdict          = 'INTEGRITY_FAILURE'
        reason           = "Protected envelope drift: $driftPaths"
        drifted_files    = $DriftedFiles
        maintenance_check = if ($MaintReq) { $MaintResult.reason } else { 'No maintenance request' }
        session_id       = $SessionId
        tool_use_id      = $ToolUseId
        command_sha256   = $CommandHash
    }
    DenyFatal "INTEGRITY: protected envelope drift detected in: $driftPaths"
}

# --- Step 9-10: Bridge is verified — dot-source it ---

. (Join-Path $GateRoot 'hooks\lib\HeliosIntegrityBridge.ps1')

# --- Step 11: Session baseline ---

$BaselinePath  = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\baseline.json"
$BaselineHashes = $null

if (-not (Test-Path $BaselinePath)) {
    $BaselineResult = New-HeliosSessionBaseline `
        -GateRoot $GateRoot -ManifestHashes $ManifestHashes `
        -SessionId $SessionId -ToolUseId $ToolUseId `
        -CommandSha256 $CommandHash -Cwd $Cwd -Shell $Shell

    if (-not $BaselineResult.created) {
        Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
            timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
            verdict        = 'INTEGRITY_FAILURE'
            reason         = "Cannot create session baseline: $($BaselineResult.reason)"
            session_id     = $SessionId
            tool_use_id    = $ToolUseId
            command_sha256 = $CommandHash
        }
        DenyFatal "INTEGRITY: cannot create session baseline: $($BaselineResult.reason)"
    }
    $BaselineHashes = $BaselineResult.baseline.protected_hashes
} else {
    $BaselineJson = Get-Content $BaselinePath -Raw | ConvertFrom-Json
    $BaselineHashes = @{}
    foreach ($prop in $BaselineJson.protected_hashes.PSObject.Properties) {
        $BaselineHashes[$prop.Name] = $prop.Value
    }
}

# --- Step 12: Compare current state against both durable manifest and session baseline ---

$Snapshot = Get-HeliosEnvelopeSnapshot `
    -GateRoot $GateRoot -ManifestHashes $ManifestHashes `
    -SessionId $SessionId -ToolUseId $ToolUseId `
    -CommandSha256 $CommandHash -Cwd $Cwd -Shell $Shell

$ProtectedResult = Compare-HeliosProtectedEnvelope `
    -CurrentSnapshot $Snapshot -ManifestHashes $ManifestHashes `
    -BaselineHashes $BaselineHashes

if ($ProtectedResult.verdict -ne 'CLEAN') {
    $driftDetails = @($ProtectedResult.details | Where-Object { $_.drift_source.Count -gt 0 })
    $driftPaths = ($driftDetails | ForEach-Object { $_.path }) -join ', '

    Write-HeliosIntegrityEvidence -GateRoot $GateRoot -SessionId $SessionId -ToolUseId $ToolUseId `
        -EvidenceType 'before' -Data @{
            timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
            session_id       = $SessionId
            tool_use_id      = $ToolUseId
            command_sha256   = $CommandHash
            protected        = $Snapshot.protected
            mutable          = $Snapshot.mutable
            context          = $Snapshot.context
            integrity_status = 'DRIFT'
        } | Out-Null

    Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
        timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
        verdict          = 'INTEGRITY_FAILURE'
        reason           = "Protected envelope drift (baseline comparison): $driftPaths"
        drift_details    = $driftDetails
        session_id       = $SessionId
        tool_use_id      = $ToolUseId
        command_sha256   = $CommandHash
    }
    DenyFatal "INTEGRITY: protected envelope drift (vs baseline and/or manifest): $driftPaths"
}

# --- Step 13: Write before snapshot ---

$ControlPlaneSnapshot = $null
$CPWatcherPath = Join-Path $GateRoot 'hooks\control_plane_watcher.ps1'
try {
    if (Test-Path $CPWatcherPath) {
        . $CPWatcherPath
        $ControlPlaneSnapshot = Get-ControlPlaneSnapshot -GateRoot $GateRoot
    }
} catch {}

# --- Step 13b: Session continuity check ---
$ContinuityBreak = $false
$SCPath = Join-Path $GateRoot 'hooks\session_continuity.ps1'
try {
    if (Test-Path $SCPath) {
        . $SCPath
        $LedgerEntries = Get-SessionLedger -GateRoot $GateRoot -SessionId $SessionId
        if ($LedgerEntries.Count -gt 0) {
            $lastEntry = $LedgerEntries[$LedgerEntries.Count - 1]
            if ($lastEntry.event_type -eq 'pretooluse_seen' -or $lastEntry.event_type -eq 'gate_consumed') {
                $ContinuityBreak = $true
            }
        }

        $policyHashForLedger = $null
        try {
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $plPath = Join-Path $GateRoot 'policy\command-policy.json'
            if (Test-Path $plPath) {
                $plBytes = [System.IO.File]::ReadAllBytes($plPath)
                $policyHashForLedger = ($sha.ComputeHash($plBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            }
        } catch {}

        Write-SessionLedgerEntry -GateRoot $GateRoot -SessionId $SessionId `
            -EventType 'pretooluse_seen' -Data @{
                command_sha256     = $CommandHash
                tool_use_id        = $ToolUseId
                policy_hash        = $policyHashForLedger
                continuity_break   = $ContinuityBreak
            }
    }
} catch {}

Write-HeliosIntegrityEvidence -GateRoot $GateRoot -SessionId $SessionId -ToolUseId $ToolUseId `
    -EvidenceType 'before' -Data @{
        timestamp_utc          = (Get-Date).ToUniversalTime().ToString('o')
        session_id             = $SessionId
        tool_use_id            = $ToolUseId
        command_sha256         = $CommandHash
        protected              = $Snapshot.protected
        mutable                = $Snapshot.mutable
        context                = $Snapshot.context
        integrity_status       = 'CLEAN'
        control_plane_snapshot = $ControlPlaneSnapshot
        continuity_break       = $ContinuityBreak
    } | Out-Null

# --- Step 14: Load tier_classifier and gate_check (both now verified) ---

. (Join-Path $GateRoot 'hooks\tier_classifier.ps1')

$script:HeliosFrontControllerActive = $true
. (Join-Path $GateRoot 'hooks\gate_check.ps1')

# gate_check.ps1 overrides DenyFatal with Write-Error + exit 2, which does not
# produce deny JSON on stdout. Re-apply front controller's version.
function DenyFatal { param([string]$Reason); Deny $Reason }

$GateResult = Invoke-GateValidation -Payload $Payload

# --- Step 15: Write decision evidence ---

$DecisionVerdict = switch ($GateResult.action) {
    'allow'       { 'ALLOW' }
    'deny'        { 'DENY' }
    'fatal'       { 'DENY_FATAL' }
    'passthrough' { 'PASSTHROUGH' }
    default       { 'UNKNOWN' }
}

Write-IntegrityDecision -SessionId $SessionId -ToolUseId $ToolUseId -Data @{
    timestamp_utc    = (Get-Date).ToUniversalTime().ToString('o')
    verdict          = $DecisionVerdict
    reason           = if ($GateResult.reason) { $GateResult.reason } elseif ($GateResult.message) { $GateResult.message } else { $null }
    command_sha256   = $GateResult.hash
    tier             = $GateResult.tier
    correlation_id   = $GateResult.correlation_id
    integrity_status = 'CLEAN'
    session_id       = $SessionId
    tool_use_id      = $ToolUseId
}

try {
    if (Get-Command Write-SessionLedgerEntry -ErrorAction SilentlyContinue) {
        Write-SessionLedgerEntry -GateRoot $GateRoot -SessionId $SessionId `
            -EventType 'gate_consumed' -Data @{
                correlation_id = $GateResult.correlation_id
                command_sha256 = $GateResult.hash
                declared_tier  = $GateResult.tier
                tool_use_id    = $ToolUseId
                verdict        = $DecisionVerdict
            }
    }
} catch {}

# --- Step 16: Exit with appropriate behavior ---

switch ($GateResult.action) {
    'passthrough' { Write-Output '{}'; exit 0 }
    'allow'       { Write-Output '{}'; exit 0 }
    'deny'        { Deny $GateResult.reason }
    'fatal'       { DenyFatal $GateResult.message }
    default       { DenyFatal "Unexpected gate result: $($GateResult.action)" }
}
