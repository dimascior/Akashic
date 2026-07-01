# Verify evidence chain completeness for a session.
# Checks that each command has the expected evidence files
# (before, decision, and optionally after + compare).
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GateRoot,

    [Parameter(Mandatory)]
    [string]$SessionId
)

$ErrorActionPreference = 'Stop'

$sessionDir = Join-Path $GateRoot "evidence\integrity\sessions\$SessionId"
if (-not (Test-Path $sessionDir)) {
    $result = @{
        verdict    = 'NO_SESSION'
        session_id = $SessionId
        reason     = "Session directory not found: $sessionDir"
        commands   = @()
    }
    $result | ConvertTo-Json -Depth 3
    return $result
}

$baselinePath = Join-Path $sessionDir 'baseline.json'
$hasBaseline = Test-Path $baselinePath

$commandsDir = Join-Path $sessionDir 'commands'
if (-not (Test-Path $commandsDir)) {
    $result = @{
        verdict      = 'NO_COMMANDS'
        session_id   = $SessionId
        has_baseline = $hasBaseline
        reason       = 'No commands directory found'
        commands     = @()
    }
    $result | ConvertTo-Json -Depth 3
    return $result
}

$evidenceFiles = Get-ChildItem -Path $commandsDir -Filter '*.json' -File
if ($evidenceFiles.Count -eq 0) {
    $result = @{
        verdict      = 'NO_COMMANDS'
        session_id   = $SessionId
        has_baseline = $hasBaseline
        reason       = 'Commands directory is empty'
        commands     = @()
    }
    $result | ConvertTo-Json -Depth 3
    return $result
}

$toolUseIds = @{}
foreach ($file in $evidenceFiles) {
    if ($file.Name -match '^(.+)\.(before|decision|after|compare)\.json$') {
        $id = $Matches[1]
        $type = $Matches[2]
        if (-not $toolUseIds.ContainsKey($id)) {
            $toolUseIds[$id] = @()
        }
        $toolUseIds[$id] += $type
    }
}

$commands = @()
$hasIncomplete = $false
$orphanCount = 0
$completeCount = 0

foreach ($id in ($toolUseIds.Keys | Sort-Object)) {
    $types = $toolUseIds[$id]

    $hasBefore   = 'before'   -in $types
    $hasDecision = 'decision' -in $types
    $hasAfter    = 'after'    -in $types
    $hasCompare  = 'compare'  -in $types

    $commandVerdict = 'COMPLETE'
    $missing = @()
    $classification = $null

    if (-not $hasBefore -and -not $hasDecision -and ($hasAfter -or $hasCompare)) {
        $commandVerdict = 'ORPHAN'
        $classification = 'cross_session_posttool'
        $orphanCount++
    } else {
        if (-not $hasBefore) {
            $missing += 'before'
            $commandVerdict = 'INCOMPLETE'
        }
        if (-not $hasDecision) {
            $missing += 'decision'
            $commandVerdict = 'INCOMPLETE'
        }

        if ($hasDecision) {
            $decisionPath = Join-Path $commandsDir "$id.decision.json"
            $decision = Get-Content -LiteralPath $decisionPath -Raw | ConvertFrom-Json
            $wasAllowed = $decision.verdict -eq 'ALLOW'

            if ($wasAllowed) {
                $classification = 'allow'
                if (-not $hasAfter) {
                    $missing += 'after'
                    $commandVerdict = 'INCOMPLETE'
                }
                if (-not $hasCompare) {
                    $missing += 'compare'
                    $commandVerdict = 'INCOMPLETE'
                }
            } else {
                $classification = 'deny'
            }
        }

        if ($commandVerdict -eq 'INCOMPLETE') {
            $hasIncomplete = $true
        } elseif ($commandVerdict -eq 'COMPLETE') {
            $completeCount++
        }
    }

    $entry = @{
        tool_use_id    = $id
        verdict        = $commandVerdict
        classification = $classification
        has_before     = $hasBefore
        has_decision   = $hasDecision
        has_after      = $hasAfter
        has_compare    = $hasCompare
        missing        = $missing
    }

    $commands += $entry
}

if ($hasIncomplete) {
    $verdict = 'INCOMPLETE'
} elseif ($orphanCount -gt 0) {
    $verdict = 'COMPLETE_WITH_ORPHANS'
} else {
    $verdict = 'COMPLETE'
}

$result = @{
    timestamp_utc   = (Get-Date).ToUniversalTime().ToString('o')
    verdict         = $verdict
    session_id      = $SessionId
    has_baseline    = $hasBaseline
    command_count   = $commands.Count
    complete_count  = $completeCount
    orphan_count    = $orphanCount
    incomplete_count = @($commands | Where-Object { $_.verdict -eq 'INCOMPLETE' }).Count
    commands        = $commands
}

$result | ConvertTo-Json -Depth 4
return $result
