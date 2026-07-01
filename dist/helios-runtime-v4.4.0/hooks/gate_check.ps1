# gate_check.ps1 — PreToolUse hook (refactored for front-controller support)
# When invoked standalone: reads stdin, loads tier_classifier, runs validation.
# When dot-sourced by helios_pretooluse.ps1: provides Invoke-GateValidation only.
# Exit 0 + {} = allow (normal permission flow). Exit 2 + stderr = block.

$ErrorActionPreference = 'Stop'

$GateRoot = Split-Path $PSScriptRoot -Parent

$RequiredDirs = @('pending', 'inflight', 'evidence', 'blocked', 'policy', 'templates', 'manifest')

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

function Write-BlockedRecord {
    param([string]$Command, [string]$Hash, [string]$Reason, [int]$Tier)
    try {
        $Ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $Record = @{
            timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
            command = $Command
            command_sha256 = $Hash
            tier = $Tier
            reason = $Reason
        }
        $Path = Join-Path $GateRoot "blocked\$Ts-$($Hash.Substring(0,12)).blocked.json"
        [System.IO.File]::WriteAllText($Path, ($Record | ConvertTo-Json -Depth 3), [System.Text.Encoding]::UTF8)
    } catch {}
}

function Get-Sha256 {
    param([string]$Text)
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    $HashBytes = $Sha.ComputeHash($Bytes)
    return ($HashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Get-TierRequiredFields {
    param([int]$Tier)
    $PolicyPath = Join-Path $GateRoot 'policy\command-policy.json'
    if (Test-Path $PolicyPath) {
        try {
            $Policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json
            $Key = [string][Math]::Min($Tier, 3)
            $Fields = $Policy.tier_required_fields.$Key
            if ($Fields) { return @($Fields) }
        } catch {}
    }
    $Fallback = @{
        0 = @('need', 'expected', 'actual_means', 'next_logic')
        1 = @('need', 'expected', 'actual_means', 'next_logic')
        2 = @('need', 'expected', 'actual_means', 'next_logic', 'stop_conditions')
        3 = @('need', 'expected', 'actual_means', 'next_logic', 'stop_conditions', 'read_write_impact')
    }
    return $Fallback[[Math]::Min($Tier, 3)]
}

# --- Gate Validation Function ---
# Returns a hashtable: { action, reason, message, hash, tier, correlation_id }
# action values: passthrough, allow, deny, fatal

function Invoke-GateValidation {
    param([Parameter(Mandatory)]$Payload)

    $ToolName = $Payload.tool_name
    if ($ToolName -notin @('Bash', 'PowerShell')) {
        return @{ action = 'passthrough' }
    }

    $Command = $null
    if ($Payload.tool_input -and $Payload.tool_input.command) {
        $Command = $Payload.tool_input.command
    }
    if ([string]::IsNullOrWhiteSpace($Command)) {
        return @{ action = 'fatal'; message = 'No command field in tool_input' }
    }

    $Cwd = $Payload.cwd
    $ToolUseId = $Payload.tool_use_id
    $Shell = $ToolName.ToLower()

    # Directory integrity check
    if (-not (Test-Path $GateRoot -PathType Container)) {
        return @{ action = 'fatal'; message = "Gate root missing: $GateRoot" }
    }
    $RootAttrs = [System.IO.File]::GetAttributes($GateRoot)
    if ($RootAttrs -band [System.IO.FileAttributes]::ReparsePoint) {
        return @{ action = 'fatal'; message = 'Gate root is a reparse point (junction/symlink)' }
    }
    foreach ($dir in $RequiredDirs) {
        $DirPath = Join-Path $GateRoot $dir
        if (-not (Test-Path $DirPath -PathType Container)) {
            return @{ action = 'fatal'; message = "Required directory missing: $dir" }
        }
        $DirAttrs = [System.IO.File]::GetAttributes($DirPath)
        if ($DirAttrs -band [System.IO.FileAttributes]::ReparsePoint) {
            return @{ action = 'fatal'; message = "Directory is a reparse point: $dir" }
        }
    }

    # Step 1: Compute hash (needed for gate matching and blocked records)
    $Hash = Get-Sha256 $Command

    # Step 2: Tier 4 check (before gate matching — unconditional block)
    $TierResult = Get-CommandTier $Command
    if ($TierResult.Tier -eq 4) {
        $Reason = "TIER 4 FORBIDDEN: pattern '$($TierResult.MatchedPattern)' matched. This command is unconditionally blocked."
        Write-BlockedRecord $Command $Hash $Reason 4
        return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = 4 }
    }

    $DetectedTier = $TierResult.Tier
    $RequiredFields = Get-TierRequiredFields $DetectedTier
    $HasWriteIndicator = Test-WriteIndicator $Command

    # Step 3: Scan pending/ for candidate gate by identity, while collecting diagnostics
    $PendingDir = Join-Path $GateRoot 'pending'
    $NowUtc = (Get-Date).ToUniversalTime()
    $MatchedGate = $null
    $MatchedGateFile = $null
    $CandidateDiagnostics = @()

    $RequiredBaseFields = @(
        'schema_version',
        'correlation_id',
        'created_utc',
        'expires_utc',
        'command',
        'command_sha256',
        'working_directory',
        'shell',
        'risk_tier',
        'exit_capture',
        'multi_command',
        'segments',
        'need',
        'expected',
        'actual_means',
        'next_logic',
        'approval_boundary'
    )

    foreach ($gateFile in (Get-ChildItem $PendingDir -Filter '*.gate.json' -ErrorAction SilentlyContinue)) {
        try {
            $gate = Get-Content $gateFile.FullName -Raw | ConvertFrom-Json
        } catch {
            continue
        }

        $ShaMatch = ($gate.command_sha256 -eq $Hash)
        $CmdMatch = ($gate.command -eq $Command)

        if (-not $ShaMatch -and -not $CmdMatch) {
            continue
        }

        $MatchType = 'command'
        if ($ShaMatch) {
            $MatchType = 'sha256'
        }

        $Reasons = @()

        if (-not $CmdMatch) {
            $Reasons += 'command text mismatch: command_sha256 matched but command text differs'
        }

        if (-not $ShaMatch) {
            $Reasons += "command_sha256 mismatch: gate='$($gate.command_sha256)' expected='$Hash'"
        }

        if ($gate.working_directory -ne $Cwd) {
            $Reasons += "working_directory mismatch`n  gate:   $($gate.working_directory)`n  actual: $Cwd"
        }

        if ($gate.shell -ne $Shell) {
            $Reasons += "shell mismatch: gate='$($gate.shell)' actual='$Shell'"
        }

        $PropNames = @($gate.PSObject.Properties.Name)

        if ($PropNames -contains 'tier' -and -not ($PropNames -contains 'risk_tier')) {
            $Reasons += 'field name error: found "tier"; expected "risk_tier"'
        }

        $MissingBase = @()
        foreach ($f in $RequiredBaseFields) {
            if (-not ($PropNames -contains $f)) {
                $MissingBase += $f
                continue
            }

            $val = $gate.$f
            if ($null -eq $val) {
                $MissingBase += $f
            } elseif ($val -is [string] -and [string]::IsNullOrWhiteSpace($val)) {
                $MissingBase += $f
            }
        }

        if ($MissingBase.Count -gt 0) {
            $Reasons += "missing base fields: $($MissingBase -join ', ')"
        }

        $ExpiresUtc = $null
        try {
            $ExpiresUtc = [DateTime]::Parse($gate.expires_utc).ToUniversalTime()
            if ($ExpiresUtc -le $NowUtc) {
                $Reasons += "expired gate`n  expires_utc: $($gate.expires_utc)`n  now_utc:     $($NowUtc.ToString('o'))"
            }
        } catch {
            $Reasons += "expires_utc is missing or unparseable: '$($gate.expires_utc)'"
        }

        $GateTier = $null
        try {
            $GateTier = [int]$gate.risk_tier
            if ($GateTier -lt $DetectedTier) {
                $Reasons += "risk_tier too low: gate=$GateTier detected=$DetectedTier"
            }
        } catch {
            $Reasons += "risk_tier is missing or not an integer: '$($gate.risk_tier)'"
        }

        $MissingRequired = @()
        foreach ($f in $RequiredFields) {
            $val = $gate.$f
            if ($null -eq $val) {
                $MissingRequired += $f
            } elseif ($val -is [string] -and [string]::IsNullOrWhiteSpace($val)) {
                $MissingRequired += $f
            }
        }

        if ($MissingRequired.Count -gt 0) {
            $Reasons += "missing tier-required fields: $($MissingRequired -join ', ')"
        }

        if ($HasWriteIndicator) {
            $rwi = $gate.read_write_impact
            if ($null -eq $rwi -or $null -eq $rwi.writes) {
                $Reasons += 'write indicator detected but read_write_impact.writes is missing'
            } else {
                $writes = @($rwi.writes)
                if ($writes.Count -eq 0) {
                    $Reasons += 'write indicator detected but read_write_impact.writes is empty'
                } elseif ($writes.Count -eq 1 -and $writes[0] -eq 'none') {
                    $Reasons += 'write indicator detected but read_write_impact.writes is ["none"]'
                }
            }
        }

        # Capability-flag enforcement: hidden execution power requires read_write_impact
        if ($TierResult.CapabilityFlags) {
            $HasCapability = $false
            foreach ($flagKey in $TierResult.CapabilityFlags.Keys) {
                if ($TierResult.CapabilityFlags[$flagKey] -eq $true) {
                    $HasCapability = $true
                    break
                }
            }
            if ($HasCapability) {
                $rwi = $gate.read_write_impact
                if ($null -eq $rwi -or $null -eq $rwi.writes) {
                    $capNames = @($TierResult.CapabilityFlags.Keys | Where-Object { $TierResult.CapabilityFlags[$_] -eq $true })
                    $Reasons += "capability detection ($($capNames -join ', ')) requires read_write_impact.writes"
                } else {
                    $writes = @($rwi.writes)
                    if ($writes.Count -eq 0) {
                        $Reasons += 'capability detection active but read_write_impact.writes is empty'
                    } elseif ($writes.Count -eq 1 -and $writes[0] -eq 'none') {
                        $Reasons += 'capability detection active but read_write_impact.writes is ["none"]'
                    }
                }
            }
        }

        if ($Reasons.Count -eq 0) {
            $MatchedGate = $gate
            $MatchedGateFile = $gateFile
            break
        }

        $CandidateDiagnostics += [pscustomobject]@{
            file = $gateFile.Name
            match_type = $MatchType
            reasons = @($Reasons)
        }
    }

    if ($null -eq $MatchedGate) {
        $BestDiag = $null

        foreach ($d in $CandidateDiagnostics) {
            if ($null -eq $BestDiag) {
                $BestDiag = $d
                continue
            }

            if ($d.match_type -eq 'sha256' -and $BestDiag.match_type -ne 'sha256') {
                $BestDiag = $d
            }
        }

        if ($null -ne $BestDiag) {
            $DiagLines = @(
                "GATE REJECTED: closest gate $($BestDiag.file) matched $($BestDiag.match_type) but failed validation:"
            )

            foreach ($r in $BestDiag.reasons) {
                $DiagLines += "- $r"
            }

            $HasSchemaIssue = $false
            foreach ($r in $BestDiag.reasons) {
                if ($r -like 'missing base fields*' -or
                    $r -like 'missing tier-required fields*' -or
                    $r -like 'field name error*' -or
                    $r -like 'risk_tier is missing*' -or
                    $r -like 'expires_utc is missing*') {
                    $HasSchemaIssue = $true
                    break
                }
            }

            if ($HasSchemaIssue) {
                $DiagLines += ''
                $DiagLines += 'Required base fields: schema_version, correlation_id, created_utc, expires_utc, command, command_sha256, working_directory, shell, risk_tier, exit_capture, multi_command, segments, need, expected, actual_means, next_logic, approval_boundary'
            }

            $Reason = $DiagLines -join "`n"

            $BlockedRecord = @{
                timestamp_utc = $NowUtc.ToString('o')
                command = $Command
                command_sha256 = $Hash
                detected_tier = $DetectedTier
                closest_gate_file = $BestDiag.file
                closest_match_type = $BestDiag.match_type
                reject_reasons = @($BestDiag.reasons)
                reason = $Reason
            }

            if ($HasSchemaIssue) {
                $BlockedRecord.expected_schema_hint = @{
                    required_base_fields = $RequiredBaseFields
                }
            }

            try {
                $Ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
                $Path = Join-Path $GateRoot "blocked\$Ts-$($Hash.Substring(0,12)).blocked.json"
                [System.IO.File]::WriteAllText(
                    $Path,
                    ($BlockedRecord | ConvertTo-Json -Depth 6),
                    [System.Text.Encoding]::UTF8
                )
            } catch {}

            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }

        $TemplateSuggestion = ''
        if ($TierResult.MatchedTemplate) {
            $TemplateSuggestion = " Template: $($TierResult.MatchedTemplate)."
        } elseif ($TierResult.Name) {
            $TemplateSuggestion = " Category: $($TierResult.Name)."
        }

        $Reason = "GATE REQUIRED: No valid gate found in pending/ for this command. Tier: $DetectedTier. SHA256: $Hash.$TemplateSuggestion"
        Write-BlockedRecord $Command $Hash $Reason $DetectedTier
        return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
    }

    # Step 4: Exit-capture mode enforcement
    $PolicyPath = Join-Path $GateRoot 'policy\command-policy.json'
    $ExitSuffixes = @()
    $ValidNaReasons = @()
    $WrapperMustContain = $null
    $WrapperMustEndWith = $null
    try {
        $PolicyJson = Get-Content $PolicyPath -Raw | ConvertFrom-Json
        if ($PolicyJson.exit_capture_suffixes.$Shell) {
            $ExitSuffixes = @($PolicyJson.exit_capture_suffixes.$Shell)
        }
        if ($PolicyJson.exit_capture_not_applicable_reasons) {
            $ValidNaReasons = @($PolicyJson.exit_capture_not_applicable_reasons)
        }
        if ($PolicyJson.wrapper_validators.$Shell) {
            $WrapperMustContain = $PolicyJson.wrapper_validators.$Shell.must_contain
            $WrapperMustEndWith = $PolicyJson.wrapper_validators.$Shell.must_end_with
        }
    } catch {}

    $ExitCaptureMode = $MatchedGate.exit_capture
    $IsWrapperMode = $false

    if ($ExitCaptureMode -eq 'wrapper_required') {
        $IsWrapperMode = $true
        $WrapperOk = $true
        $WrapperFail = ''
        if ($WrapperMustContain -and -not $Command.Contains($WrapperMustContain)) {
            $WrapperOk = $false
            $WrapperFail = "command does not contain '$WrapperMustContain'"
        }
        $TrimmedCommand = $Command.TrimEnd()
        if ($WrapperMustEndWith -and -not $TrimmedCommand.EndsWith($WrapperMustEndWith)) {
            $WrapperOk = $false
            $WrapperFail = "command does not end with '$WrapperMustEndWith'"
        }
        if (-not $WrapperOk) {
            $Reason = "WRAPPER VALIDATION FAILED: exit_capture=wrapper_required but $WrapperFail. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
        $WrappedCmd = $MatchedGate.wrapped_command
        $WrappedHash = $MatchedGate.wrapped_command_sha256
        $WrapperReason = $MatchedGate.wrapper_reason
        if ([string]::IsNullOrWhiteSpace($WrappedCmd)) {
            $Reason = "WRAPPER IDENTITY: exit_capture=wrapper_required but no wrapped_command declared. The gate must document the semantic command being wrapped. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
        if ([string]::IsNullOrWhiteSpace($WrappedHash)) {
            $Reason = "WRAPPER IDENTITY: exit_capture=wrapper_required but no wrapped_command_sha256 declared. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
        $ExpectedWrappedHash = Get-Sha256 $WrappedCmd
        if ($WrappedHash -ne $ExpectedWrappedHash) {
            $Reason = "WRAPPER IDENTITY: wrapped_command_sha256 does not match the hash of wrapped_command. Declared: $WrappedHash, Computed: $ExpectedWrappedHash. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
        if (-not $Command.Contains($WrappedCmd)) {
            $Reason = "WRAPPER IDENTITY: wrapped_command is not found inside the full command. The wrapper must contain the declared semantic command. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
        if ([string]::IsNullOrWhiteSpace($WrapperReason)) {
            $Reason = "WRAPPER IDENTITY: exit_capture=wrapper_required but no wrapper_reason declared. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
    } elseif ($ExitCaptureMode -eq 'not_applicable') {
        $ecReason = $MatchedGate.exit_capture_reason
        if ([string]::IsNullOrWhiteSpace($ecReason)) {
            $Reason = "EXIT CAPTURE: gate declares exit_capture=not_applicable but no exit_capture_reason provided. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
        if ($ValidNaReasons.Count -gt 0 -and $ecReason -notin $ValidNaReasons) {
            $Reason = "EXIT CAPTURE: exit_capture_reason '$ecReason' is not in the approved list ($($ValidNaReasons -join ', ')). SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
    } else {
        $HasExitSuffix = $false
        foreach ($suffix in $ExitSuffixes) {
            if ($Command.EndsWith($suffix)) {
                $HasExitSuffix = $true
                break
            }
        }
        if (-not $HasExitSuffix) {
            $SuffixHint = ($ExitSuffixes | ForEach-Object { "'$_'" }) -join ' or '
            $Reason = "EXIT CAPTURE REQUIRED: command does not end with an approved exit-capture suffix ($SuffixHint) and gate does not declare exit_capture=wrapper_required or not_applicable. SHA256: $Hash"
            Write-BlockedRecord $Command $Hash $Reason $DetectedTier
            return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
        }
    }

    # Step 5: Chain validation and segment decomposition
    . (Join-Path $GateRoot 'hooks\command_decomposer.ps1')

    $DeclaredSegments = @()
    if ($MatchedGate.segments) { $DeclaredSegments = @($MatchedGate.segments) }
    $Decomposition = Get-CommandDecomposition -Command $Command -DeclaredSegments $DeclaredSegments

    if (-not $IsWrapperMode) {
        $IsChained = Test-ChainViolation $Command
        if ($IsChained) {
            if ($MatchedGate.multi_command -ne $true -or $DeclaredSegments.Count -eq 0) {
                $Reason = "UNDECLARED CHAINING: command contains chained operators (;, &&, ||, |) but the gate does not declare multi_command:true with segments. SHA256: $Hash"
                Write-BlockedRecord $Command $Hash $Reason -1
                return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = -1 }
            }
            if (-not $Decomposition.segments_match) {
                $detectedList = ($Decomposition.segments_detected | ForEach-Object { "'$_'" }) -join ', '
                $declaredList = ($DeclaredSegments | ForEach-Object { "'$_'" }) -join ', '
                $Reason = "SEGMENT MISMATCH: declared segments do not match decomposed command structure. Detected: [$detectedList] Declared: [$declaredList]. SHA256: $Hash"
                Write-BlockedRecord $Command $Hash $Reason $DetectedTier
                return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
            }
        }

        if ($Decomposition.ambiguous_parse -and $DetectedTier -lt 1) {
            $rwi = $MatchedGate.read_write_impact
            if ($null -eq $rwi -or $null -eq $rwi.writes) {
                $Reason = "AMBIGUOUS COMMAND: cannot safely decompose; requires tier >= 1 or explicit read_write_impact. SHA256: $Hash"
                Write-BlockedRecord $Command $Hash $Reason $DetectedTier
                return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
            }
        }
    }

    # Step 5b: Evidence chain linkage
    $SessionIdForChain = $Payload.session_id
    if ($SessionIdForChain) {
        $SCPathChain = Join-Path $GateRoot 'hooks\session_continuity.ps1'
        try {
            if (Test-Path $SCPathChain) {
                . $SCPathChain
                $ledger = Get-SessionLedger -GateRoot $GateRoot -SessionId $SessionIdForChain
                $lastEvidence = $null
                for ($li = $ledger.Count - 1; $li -ge 0; $li--) {
                    if ($ledger[$li].event_type -eq 'posttooluse_evidence_written') {
                        $lastEvidence = $ledger[$li]
                        break
                    }
                }
                if ($null -ne $lastEvidence) {
                    $hasPrevCorr = ($null -ne $MatchedGate.previous_correlation_id -and $MatchedGate.previous_correlation_id.Length -gt 0)
                    $hasNewChain = ($MatchedGate.new_chain -eq $true)
                    if (-not $hasPrevCorr -and -not $hasNewChain) {
                        $prevCorr = $lastEvidence.correlation_id
                        $Reason = "CHAIN LINKAGE: previous evidence exists (correlation_id: $prevCorr) but gate declares neither previous_correlation_id nor new_chain:true. SHA256: $Hash"
                        Write-BlockedRecord $Command $Hash $Reason $DetectedTier
                        return @{ action = 'deny'; reason = $Reason; hash = $Hash; tier = $DetectedTier }
                    }
                }
            }
        } catch {}
    }

    # Step 6: Valid gate — move to inflight
    $InflightDir = Join-Path $GateRoot 'inflight'
    $InflightName = $MatchedGateFile.Name
    if ($ToolUseId) {
        $InflightName = "$ToolUseId-$InflightName"
    }
    $InflightPath = Join-Path $InflightDir $InflightName
    Move-Item -Path $MatchedGateFile.FullName -Destination $InflightPath -Force

    return @{
        action              = 'allow'
        hash                = $Hash
        tier                = $DetectedTier
        correlation_id      = $MatchedGate.correlation_id
        capability_flags    = $TierResult.CapabilityFlags
        reason_codes        = $TierResult.ReasonCodes
        capability_escalated = $TierResult.CapabilityEscalated
        control_plane_paths = $TierResult.ControlPlanePaths
        decomposition       = $Decomposition
    }
}

# --- Standalone execution ---
# When invoked directly (not dot-sourced by helios_pretooluse.ps1),
# load tier_classifier, read stdin, and run gate validation.
if (-not $HeliosFrontControllerActive) {
    . (Join-Path $GateRoot 'hooks\tier_classifier.ps1')

    $RawInput = $null
    try {
        $RawInput = [Console]::In.ReadToEnd()
    } catch {
        DenyFatal 'Cannot read stdin'
    }

    if ([string]::IsNullOrWhiteSpace($RawInput)) {
        DenyFatal 'Empty stdin'
    }

    $StandalonePayload = $null
    try {
        $StandalonePayload = $RawInput | ConvertFrom-Json
    } catch {
        DenyFatal "Cannot parse hook payload: $($_.Exception.Message)"
    }

    $Result = Invoke-GateValidation -Payload $StandalonePayload

    switch ($Result.action) {
        'passthrough' { Write-Output '{}'; exit 0 }
        'allow'       { Write-Output '{}'; exit 0 }
        'deny'        { Deny $Result.reason }
        'fatal'       { DenyFatal $Result.message }
        default       { DenyFatal "Unexpected gate result: $($Result.action)" }
    }
}
