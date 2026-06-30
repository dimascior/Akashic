<#
.SYNOPSIS
    Forensic audit of a Helios session ledger.
.DESCRIPTION
    Reads the session ledger for a given session ID and verifies the
    pretooluse_seen / gate_consumed / posttooluse_evidence_written chain
    is complete for every command. Reports gaps and forcefield drops.
.PARAMETER GateRoot
    Path to .command-gate directory.
.PARAMETER SessionId
    Session ID to audit.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GateRoot,
    [Parameter(Mandatory)][string]$SessionId
)

$ErrorActionPreference = 'Stop'

$SCPath = Join-Path $GateRoot 'hooks\session_continuity.ps1'
if (-not (Test-Path $SCPath)) {
    Write-Host "ERROR: session_continuity.ps1 not found at $SCPath"
    return @{ status = 'error'; reason = 'session_continuity.ps1 not found' }
}

. $SCPath

$result = Test-SessionContinuity -GateRoot $GateRoot -SessionId $SessionId

Write-Host "=== Session Continuity Audit ==="
Write-Host "Session: $SessionId"
Write-Host "Total commands: $($result.total_commands)"
Write-Host "Verdict: $($result.continuity_verdict)"

if ($result.evidence_gaps.Count -gt 0) {
    Write-Host "`nEvidence gaps:"
    foreach ($gap in $result.evidence_gaps) {
        $gapType = if ($gap -is [PSCustomObject]) { $gap.type } else { $gap['type'] }
        $gapTs = if ($gap -is [PSCustomObject]) { $gap.timestamp } else { $gap['timestamp'] }
        $gapCorr = if ($gap -is [PSCustomObject]) { $gap.correlation_id } else { $gap['correlation_id'] }
        $gapCmd = if ($gap -is [PSCustomObject]) { $gap.command_sha256 } else { $gap['command_sha256'] }

        switch ($gapType) {
            'pretooluse_without_gate' {
                Write-Host "  [GAP] PreToolUse at $gapTs with no gate consumed (cmd: $gapCmd)"
            }
            'pretooluse_without_posttooluse' {
                Write-Host "  [GAP] PreToolUse at $gapTs with no PostToolUse evidence (cmd: $gapCmd)"
            }
            'forcefield_dropped' {
                Write-Host "  [CRITICAL] Forcefield dropped at $gapTs (correlation: $gapCorr)"
            }
            default {
                Write-Host "  [UNKNOWN] $gapType at $gapTs"
            }
        }
    }
}

if ($result.forcefield_dropped_at) {
    Write-Host "`nForcefield dropped after correlation_id: $($result.forcefield_dropped_at)"
}

Write-Host ""
$result
