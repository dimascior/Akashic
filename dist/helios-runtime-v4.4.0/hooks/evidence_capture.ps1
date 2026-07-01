# evidence_capture.ps1 — PostToolUse and PostToolUseFailure hook
# Captures what happened after a shell command executed (or failed).
# Best-effort — never blocks (exit 0 always).

$ErrorActionPreference = 'SilentlyContinue'

$GateRoot = Split-Path $PSScriptRoot -Parent

# --- Diagnostic heartbeat & error logging ---
$script:HB_Sid = 'pre-init'
$script:HB_Tuid = 'pre-init'
$PostToolErrorDir = Join-Path $GateRoot 'posttooluse-errors'
try {
    if (-not (Test-Path $PostToolErrorDir)) {
        New-Item -ItemType Directory -Path $PostToolErrorDir -Force -ErrorAction Stop | Out-Null
    }
} catch {}

function Write-PostToolHeartbeat {
    param([string]$Checkpoint, [string]$Detail)
    try {
        $entry = [ordered]@{
            ts   = (Get-Date).ToUniversalTime().ToString('o')
            sid  = $script:HB_Sid
            tuid = $script:HB_Tuid
            cp   = $Checkpoint
        }
        if ($Detail) { $entry['d'] = $Detail }
        $line = ($entry | ConvertTo-Json -Compress) + "`n"
        $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $hbPath = Join-Path $PostToolErrorDir "heartbeat-$day.jsonl"
        [System.IO.File]::AppendAllText($hbPath, $line, [System.Text.UTF8Encoding]::new($false))
    } catch {}
}

function Save-PostToolError {
    param([string]$RawPayload, [string]$Checkpoint, [string]$ErrorMessage)
    try {
        $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $payloadPath = Join-Path $PostToolErrorDir "$ts.error.json"
        $wrapper = [ordered]@{
            saved_utc  = (Get-Date).ToUniversalTime().ToString('o')
            checkpoint = $Checkpoint
            error      = $ErrorMessage
            sid        = $script:HB_Sid
            tuid       = $script:HB_Tuid
        }
        if ($RawPayload -and $RawPayload.Length -le 65536) {
            $wrapper['payload'] = $RawPayload
        } elseif ($RawPayload) {
            $wrapper['payload_truncated'] = $RawPayload.Substring(0, 65536)
            $wrapper['payload_bytes'] = $RawPayload.Length
        }
        [System.IO.File]::WriteAllText($payloadPath, ($wrapper | ConvertTo-Json -Depth 3), [System.Text.UTF8Encoding]::new($false))
        $errFiles = Get-ChildItem $PostToolErrorDir -Filter '*.error.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($errFiles.Count -gt 20) {
            $errFiles | Select-Object -Skip 20 | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

function Get-Sha256 {
    param([string]$Text)
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $Sha.ComputeHash($Bytes)
    return ($HashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Parse-ExitMarker {
    param([string]$Stdout, [string]$Stderr)
    # Parse EXIT=<number> from stdout or stderr (last occurrence wins)
    $Combined = ''
    if ($Stdout) { $Combined += $Stdout }
    if ($Stderr) { $Combined += "`n" + $Stderr }
    $Matches = [regex]::Matches($Combined, 'EXIT=(\d+)')
    if ($Matches.Count -gt 0) {
        return [int]$Matches[$Matches.Count - 1].Groups[1].Value
    }
    return $null
}

# --- MAIN ---

Write-PostToolHeartbeat -Checkpoint 'started'

$RawInput = $null
try {
    $RawInput = [Console]::In.ReadToEnd()
} catch {
    Write-PostToolHeartbeat -Checkpoint 'stdin_fail' -Detail $_.Exception.Message
    Write-Output '{}'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RawInput)) {
    Write-PostToolHeartbeat -Checkpoint 'skip' -Detail 'empty_stdin'
    Write-Output '{}'
    exit 0
}

$Payload = $null
try {
    $Payload = $RawInput | ConvertFrom-Json
} catch {
    Write-PostToolHeartbeat -Checkpoint 'skip' -Detail 'json_parse_fail'
    Save-PostToolError -RawPayload $RawInput -Checkpoint 'json_parse' -ErrorMessage $_.Exception.Message
    Write-Output '{}'
    exit 0
}

Write-PostToolHeartbeat -Checkpoint 'parsed'

$ToolName = $Payload.tool_name
if ($ToolName -notin @('Bash', 'PowerShell')) {
    Write-PostToolHeartbeat -Checkpoint 'skip' -Detail "tool=$ToolName"
    Write-Output '{}'
    exit 0
}

$HookEvent = $Payload.hook_event_name
$Command = $null
if ($Payload.tool_input -and $Payload.tool_input.command) {
    $Command = $Payload.tool_input.command
}
if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-PostToolHeartbeat -Checkpoint 'skip' -Detail 'no_command'
    Write-Output '{}'
    exit 0
}

$Hash = Get-Sha256 $Command
$ToolUseId = $Payload.tool_use_id
$SessionId = $Payload.session_id
$script:HB_Sid = if ($SessionId) { $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length)) } else { 'none' }
$script:HB_Tuid = if ($ToolUseId) { $ToolUseId } else { 'none' }

Write-PostToolHeartbeat -Checkpoint 'identified' -Detail "event=$HookEvent"
$PayloadCwd = $Payload.cwd
$DurationMs = $Payload.duration_ms
$NowUtc = (Get-Date).ToUniversalTime()
$DatePrefix = $NowUtc.ToString('yyyyMMdd')

# Extract tool_response fields (discovered from debug payload)
$ToolResponse = $Payload.tool_response
$Stdout = $null
$Stderr = $null
$NativeExitCode = $null
$Interrupted = $null
$FieldsFound = @()
$FieldsMissing = @()

if ($null -ne $ToolResponse) {
    if ($null -ne $ToolResponse.stdout) {
        $Stdout = [string]$ToolResponse.stdout
        $FieldsFound += 'stdout'
    } else { $FieldsMissing += 'stdout' }

    if ($null -ne $ToolResponse.stderr) {
        $Stderr = [string]$ToolResponse.stderr
        $FieldsFound += 'stderr'
    } else { $FieldsMissing += 'stderr' }

    if ($null -ne $ToolResponse.exitCode) {
        $NativeExitCode = $ToolResponse.exitCode
        $FieldsFound += 'exitCode'
    } elseif ($null -ne $ToolResponse.exit_code) {
        $NativeExitCode = $ToolResponse.exit_code
        $FieldsFound += 'exit_code'
    } else { $FieldsMissing += 'exitCode' }

    if ($null -ne $ToolResponse.interrupted) {
        $Interrupted = $ToolResponse.interrupted
        $FieldsFound += 'interrupted'
    } else { $FieldsMissing += 'interrupted' }
} else {
    $FieldsMissing += 'tool_response'
}

# Exit code: native first, then parse EXIT=<N> marker from output
$ParsedExitCode = Parse-ExitMarker $Stdout $Stderr
$ExitCode = $NativeExitCode
$ExitCodeSource = 'native'
if ($null -eq $ExitCode -and $null -ne $ParsedExitCode) {
    $ExitCode = $ParsedExitCode
    $ExitCodeSource = 'parsed_marker'
    $FieldsFound += 'exit_code_parsed'
} elseif ($null -eq $ExitCode) {
    $ExitCodeSource = 'unavailable'
}

$OutputPreview = $null
$OutputBytes = 0
if ($Stdout) {
    $OutputBytes = $Stdout.Length
    if ($Stdout.Length -gt 2000) {
        $OutputPreview = $Stdout.Substring(0, 2000) + '... [truncated]'
    } else {
        $OutputPreview = $Stdout
    }
}

$Success = ($HookEvent -eq 'PostToolUse')

# Find matching gate in inflight/ — prefer tool_use_id, fall back to hash
$InflightDir = Join-Path $GateRoot 'inflight'
$EvidenceDir = Join-Path $GateRoot 'evidence'
$MatchedGateFile = $null
$CorrelationId = $null
$GateFileName = $null

# Pass 1: match by tool_use_id in filename (gate_check prefixes with tool_use_id)
if ($ToolUseId) {
    foreach ($gf in (Get-ChildItem $InflightDir -Filter '*.gate.json' -ErrorAction SilentlyContinue)) {
        if ($gf.Name.StartsWith($ToolUseId)) {
            try {
                $g = Get-Content $gf.FullName -Raw | ConvertFrom-Json
                $MatchedGateFile = $gf
                $CorrelationId = $g.correlation_id
                $GateFileName = $gf.Name
                break
            } catch {}
        }
    }
}

# Pass 2: fall back to command hash if tool_use_id match failed
if ($null -eq $MatchedGateFile) {
    foreach ($gf in (Get-ChildItem $InflightDir -Filter '*.gate.json' -ErrorAction SilentlyContinue)) {
        try {
            $g = Get-Content $gf.FullName -Raw | ConvertFrom-Json
            if ($g.command_sha256 -eq $Hash) {
                $MatchedGateFile = $gf
                $CorrelationId = $g.correlation_id
                $GateFileName = $gf.Name
                break
            }
        } catch {}
    }
}

# Orphan handling
$IsOrphan = ($null -eq $MatchedGateFile)
if ($IsOrphan) {
    $Ts = $NowUtc.ToString('yyyyMMdd-HHmmss')
    $Hash12 = $Hash.Substring(0, 12)
    $CorrelationId = "orphan-$Ts-$Hash12"
    $GateFileName = 'none'
    Write-PostToolHeartbeat -Checkpoint 'gate_orphan'
} else {
    Write-PostToolHeartbeat -Checkpoint 'gate_matched' -Detail "cid=$CorrelationId"
}

# --- Phase C: Uniform forensic classification ---
$DetectedTier = 0
$DetectedTierName = 'routine'
$FC_MatchedPattern = $null
$CapabilityEscalated = $false
$CapabilityFlags = @{}
$ClassifierReasonCodes = @()
$WriteIndicatorMatched = $false
$PolicyHash = $null
$HookVersions = @{}
$EnforcementSurface = 'shell-gated'
$SegmentsDeclared = @()
$SegmentsDetected = @()
$FC_SegmentsMatch = $true

$ClassifierPath = Join-Path $PSScriptRoot 'tier_classifier.ps1'
$DecomposerPath = Join-Path $PSScriptRoot 'command_decomposer.ps1'

try {
    if (Test-Path $ClassifierPath) {
        . $ClassifierPath
        $TierResult = Get-CommandTier $Command
        $DetectedTier = $TierResult.Tier
        $DetectedTierName = $TierResult.Name
        $FC_MatchedPattern = $TierResult.MatchedPattern
        $CapabilityEscalated = [bool]$TierResult.CapabilityEscalated
        $CapabilityFlags = $TierResult.CapabilityFlags
        $ClassifierReasonCodes = @($TierResult.ReasonCodes)
        $WriteIndicatorMatched = [bool](Test-WriteIndicator $Command)
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_classifier' -Detail $_.Exception.Message
}

try {
    if (Test-Path $DecomposerPath) {
        . $DecomposerPath
        $DeclaredSegs = @()
        if ($null -ne $g -and $g.segments) {
            $DeclaredSegs = @($g.segments)
        }
        $DecompResult = Get-CommandDecomposition -Command $Command -DeclaredSegments $DeclaredSegs
        $SegmentsDeclared = $DeclaredSegs
        $SegmentsDetected = @($DecompResult.segments_detected)
        $FC_SegmentsMatch = [bool]$DecompResult.segments_match
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_decomposer' -Detail $_.Exception.Message
}

$FileSha = [System.Security.Cryptography.SHA256]::Create()
try {
    $FC_PolicyPath = Join-Path $GateRoot 'policy\command-policy.json'
    if (Test-Path $FC_PolicyPath) {
        $pBytes = [System.IO.File]::ReadAllBytes($FC_PolicyPath)
        $PolicyHash = ($FileSha.ComputeHash($pBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
} catch {}

$HookFiles = @(
    'hooks\helios_pretooluse.ps1',
    'hooks\gate_check.ps1',
    'hooks\tier_classifier.ps1',
    'hooks\evidence_capture.ps1',
    'hooks\command_decomposer.ps1'
)
try {
    foreach ($hf in $HookFiles) {
        $hfPath = Join-Path $GateRoot $hf
        if (Test-Path $hfPath) {
            $hBytes = [System.IO.File]::ReadAllBytes($hfPath)
            $hHash = ($FileSha.ComputeHash($hBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
            $HookVersions[$hf] = $hHash
        }
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_hookhash' -Detail $_.Exception.Message
}

Write-PostToolHeartbeat -Checkpoint 'classification_done' -Detail "tier=$DetectedTier"

# --- Phase D: Control-plane snapshot ---
$WatchedPathDiffs = $null
$SettingsIntegrityAfter = $null
$WatcherPath = Join-Path $PSScriptRoot 'control_plane_watcher.ps1'
try {
    if (Test-Path $WatcherPath) {
        . $WatcherPath
        $AfterCPSnapshot = Get-ControlPlaneSnapshot -GateRoot $GateRoot
        $SettingsIntegrityAfter = $AfterCPSnapshot.hook_presence

        $BeforeEviPath = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\commands\$ToolUseId.before.json"
        if (Test-Path $BeforeEviPath) {
            try {
                $BeforeEvi = Get-Content $BeforeEviPath -Raw | ConvertFrom-Json
                if ($BeforeEvi.control_plane_snapshot) {
                    $BeforeCP = @{
                        files         = $BeforeEvi.control_plane_snapshot.files
                        hook_presence = $BeforeEvi.control_plane_snapshot.hook_presence
                    }
                    $CPCompare = Compare-ControlPlaneSnapshots -Before $BeforeCP -After $AfterCPSnapshot
                    if ($CPCompare.has_changes) {
                        $WatchedPathDiffs = $CPCompare.diffs
                    }
                }
            } catch {
                Write-PostToolHeartbeat -Checkpoint 'err_cp_compare' -Detail $_.Exception.Message
            }
        }
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_controlplane' -Detail $_.Exception.Message
}

# --- Phase E: Session continuity status ---
$SessionContinuityStatus = $null
$SCPath = Join-Path $PSScriptRoot 'session_continuity.ps1'
try {
    if (Test-Path $SCPath) {
        . $SCPath
        $hookPresAfter = $true
        if ($SettingsIntegrityAfter) {
            $hookPresAfter = [bool]$SettingsIntegrityAfter['all_hooks_present']
        }
        if ($hookPresAfter) {
            $SessionContinuityStatus = 'continuous'
        } else {
            $SessionContinuityStatus = 'broken_after_this_command'
        }
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_continuity' -Detail $_.Exception.Message
}

$FilePrefix = "$DatePrefix-$CorrelationId"

# Write .result.json
$Result = [ordered]@{
    correlation_id          = $CorrelationId
    tool_use_id             = $ToolUseId
    session_id              = $SessionId
    command                 = $Command
    command_sha256          = $Hash
    gate_file               = $GateFileName
    hook_event              = $HookEvent
    executed_utc            = $NowUtc.ToString('o')
    duration_ms             = $DurationMs
    cwd                     = $PayloadCwd
    exit_code               = $ExitCode
    exit_code_source        = $ExitCodeSource
    interrupted             = $Interrupted
    output_preview          = $OutputPreview
    output_bytes            = $OutputBytes
    success                 = $Success
    fields_found            = $FieldsFound
    fields_missing          = $FieldsMissing
    detected_tier           = $DetectedTier
    detected_tier_name      = $DetectedTierName
    matched_pattern         = $FC_MatchedPattern
    capability_escalated    = $CapabilityEscalated
    capability_flags        = $CapabilityFlags
    classifier_reason_codes = $ClassifierReasonCodes
    write_indicator_matched = $WriteIndicatorMatched
    policy_hash             = $PolicyHash
    hook_versions           = $HookVersions
    enforcement_surface     = $EnforcementSurface
    segments_declared       = $SegmentsDeclared
    segments_detected       = $SegmentsDetected
    segments_match          = $FC_SegmentsMatch
    watched_path_diffs      = $WatchedPathDiffs
    settings_integrity_after = $SettingsIntegrityAfter
    session_continuity_status = $SessionContinuityStatus
}

$ResultJson = $Result | ConvertTo-Json -Depth 5
$ResultPath = Join-Path $EvidenceDir "$FilePrefix.result.json"
try {
    [System.IO.File]::WriteAllText($ResultPath, $ResultJson, [System.Text.Encoding]::UTF8)
    if (Test-Path $ResultPath) {
        Write-PostToolHeartbeat -Checkpoint 'result_written' -Detail "cid=$CorrelationId"
    } else {
        Write-PostToolHeartbeat -Checkpoint 'result_write_nofile' -Detail $ResultPath
        Save-PostToolError -RawPayload $RawInput -Checkpoint 'result_write_nofile' -ErrorMessage "WriteAllText returned but file not found: $ResultPath"
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_result_write' -Detail $_.Exception.Message
    Save-PostToolError -RawPayload $RawInput -Checkpoint 'result_write' -ErrorMessage $_.Exception.Message
}

# Session ledger entry
try {
    if (Get-Command Write-SessionLedgerEntry -ErrorAction SilentlyContinue) {
        $hookPresAfterFlag = $true
        if ($SettingsIntegrityAfter) {
            $hookPresAfterFlag = [bool]$SettingsIntegrityAfter['all_hooks_present']
        }
        Write-SessionLedgerEntry -GateRoot $GateRoot -SessionId $SessionId `
            -EventType 'posttooluse_evidence_written' -Data @{
                correlation_id      = $CorrelationId
                tool_use_id         = $ToolUseId
                command_sha256      = $Hash
                exit_code           = $ExitCode
                hook_presence_after = $hookPresAfterFlag
                watched_path_changes = ($null -ne $WatchedPathDiffs -and $WatchedPathDiffs.Count -gt 0)
            }
        Write-PostToolHeartbeat -Checkpoint 'ledger_written'
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_ledger' -Detail $_.Exception.Message
}

# Write .tool_response.json (full, capped at 1MB)
if ($null -ne $ToolResponse) {
    $TrJson = $ToolResponse | ConvertTo-Json -Depth 10
    if ($TrJson.Length -gt 1048576) {
        $TrJson = $TrJson.Substring(0, 1048576) + "`n[TRUNCATED at 1MB]"
    }
    $TrPath = Join-Path $EvidenceDir "$FilePrefix.tool_response.json"
    try { [System.IO.File]::WriteAllText($TrPath, $TrJson, [System.Text.Encoding]::UTF8) } catch {}
}

# Write .stdout.txt
if ($Stdout) {
    $StdoutPath = Join-Path $EvidenceDir "$FilePrefix.stdout.txt"
    try { [System.IO.File]::WriteAllText($StdoutPath, $Stdout, [System.Text.Encoding]::UTF8) } catch {}
}

# Write .stderr.txt
if ($Stderr -and $Stderr.Length -gt 0) {
    $StderrPath = Join-Path $EvidenceDir "$FilePrefix.stderr.txt"
    try { [System.IO.File]::WriteAllText($StderrPath, $Stderr, [System.Text.Encoding]::UTF8) } catch {}
}

# Move gate from inflight to evidence
if (-not $IsOrphan -and $MatchedGateFile) {
    $GateDest = Join-Path $EvidenceDir "$FilePrefix.gate.json"
    try { Move-Item -Path $MatchedGateFile.FullName -Destination $GateDest -Force } catch {}
}

# --- Integrity evidence (Helios bridge) ---
Write-PostToolHeartbeat -Checkpoint 'bridge_start'
$IntegrityWarning = $null
try {
    $BridgePath = Join-Path $GateRoot 'hooks\lib\HeliosIntegrityBridge.ps1'
    if ((Test-Path $BridgePath) -and $SessionId -and $ToolUseId) {
        . $BridgePath

        $ManifestPath = Join-Path $GateRoot 'manifest\helios-envelope.json'
        $ManifestHashes = @{}
        if (Test-Path $ManifestPath) {
            $mJson = Get-Content $ManifestPath -Raw | ConvertFrom-Json
            foreach ($prop in $mJson.protected.hashes.PSObject.Properties) {
                $ManifestHashes[$prop.Name] = $prop.Value
            }
        }

        if ($ManifestHashes.Count -gt 0) {
            $PostSnapshot = Get-HeliosEnvelopeSnapshot `
                -GateRoot $GateRoot -ManifestHashes $ManifestHashes `
                -SessionId $SessionId -ToolUseId $ToolUseId `
                -CommandSha256 $Hash -CorrelationId $CorrelationId `
                -Cwd $PayloadCwd -Shell $ToolName.ToLower()

            Write-HeliosIntegrityEvidence -GateRoot $GateRoot `
                -SessionId $SessionId -ToolUseId $ToolUseId `
                -EvidenceType 'after' -Data @{
                    timestamp_utc  = (Get-Date).ToUniversalTime().ToString('o')
                    session_id     = $SessionId
                    tool_use_id    = $ToolUseId
                    command_sha256 = $Hash
                    correlation_id = $CorrelationId
                    hook_event     = $HookEvent
                    protected      = $PostSnapshot.protected
                    mutable        = $PostSnapshot.mutable
                    context        = $PostSnapshot.context
                } | Out-Null

            $BeforePath = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\commands\$ToolUseId.before.json"
            if (Test-Path $BeforePath) {
                $BeforeData = Get-Content $BeforePath -Raw | ConvertFrom-Json

                $BaselinePath = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId\baseline.json"
                $BaselineHashes = $null
                if (Test-Path $BaselinePath) {
                    $bJson = Get-Content $BaselinePath -Raw | ConvertFrom-Json
                    $BaselineHashes = @{}
                    foreach ($prop in $bJson.protected_hashes.PSObject.Properties) {
                        $BaselineHashes[$prop.Name] = $prop.Value
                    }
                }

                $ProtectedResult = Compare-HeliosProtectedEnvelope `
                    -CurrentSnapshot $PostSnapshot `
                    -ManifestHashes $ManifestHashes `
                    -BaselineHashes $BaselineHashes

                $BeforeMutable = @{}
                foreach ($prop in $BeforeData.mutable.PSObject.Properties) {
                    $BeforeMutable[$prop.Name] = @{
                        count = $prop.Value.count
                        files = @($prop.Value.files)
                    }
                }

                $MutationProfile = 'ALLOW_POSTTOOL'
                $RuntimeResult = Compare-HeliosRuntimeTransition `
                    -BeforeMutable $BeforeMutable `
                    -AfterMutable $PostSnapshot.mutable `
                    -ExpectedMutationProfile $MutationProfile

                Write-HeliosIntegrityEvidence -GateRoot $GateRoot `
                    -SessionId $SessionId -ToolUseId $ToolUseId `
                    -EvidenceType 'compare' -Data @{
                        timestamp_utc     = (Get-Date).ToUniversalTime().ToString('o')
                        session_id        = $SessionId
                        tool_use_id       = $ToolUseId
                        command_sha256    = $Hash
                        correlation_id    = $CorrelationId
                        hook_event        = $HookEvent
                        protected_verdict = $ProtectedResult.verdict
                        protected_details = $ProtectedResult.details
                        runtime_verdict   = $RuntimeResult.verdict
                        runtime_profile   = $RuntimeResult.profile
                        runtime_details   = $RuntimeResult.details
                    } | Out-Null

                if ($ProtectedResult.verdict -ne 'CLEAN') {
                    $driftPaths = @($ProtectedResult.details |
                        Where-Object { $_.drift_source.Count -gt 0 } |
                        ForEach-Object { $_.path }) -join ', '
                    $IntegrityWarning = " INTEGRITY WARNING: protected envelope drift in: $driftPaths"
                }
            }
        }
    }
} catch {
    Write-PostToolHeartbeat -Checkpoint 'err_bridge' -Detail $_.Exception.Message
    Save-PostToolError -RawPayload $RawInput -Checkpoint 'bridge' -ErrorMessage $_.Exception.Message
}

Write-PostToolHeartbeat -Checkpoint 'output_start'

# Output additionalContext
$StatusWord = if ($Success) { 'succeeded' } else { 'failed' }
$ExitInfo = ''
if ($null -ne $ExitCode) {
    $ExitInfo = " Exit=$ExitCode (source: $ExitCodeSource)."
}
$ContextMsg = "[EVIDENCE:$CorrelationId] Command $StatusWord.$ExitInfo Compare EXPECTED from the gate vs ACTUAL output before creating the next gate."
if ($IntegrityWarning) {
    $ContextMsg += $IntegrityWarning
}
if ($WatchedPathDiffs -and $WatchedPathDiffs.Count -gt 0) {
    $changedKeys = @($WatchedPathDiffs.Keys) -join ', '
    $ContextMsg += " CONTROL PLANE: watched files changed: $changedKeys."
    if ($SettingsIntegrityAfter -and -not $SettingsIntegrityAfter['all_hooks_present']) {
        $ContextMsg += " CONTROL PLANE: hook configuration removed -- forcefield compromised."
    }
}
$Out = @{
    hookSpecificOutput = @{
        hookEventName = $HookEvent
        additionalContext = $ContextMsg
    }
}

Write-PostToolHeartbeat -Checkpoint 'complete'

Write-Output ($Out | ConvertTo-Json -Depth 5 -Compress)
exit 0
