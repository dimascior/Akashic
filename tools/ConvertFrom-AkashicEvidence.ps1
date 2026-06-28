# ConvertFrom-AkashicEvidence.ps1 — Akashic evidence parser/normalizer
# Ingests Helios runtime evidence artifacts and normalizes them into a TCE-local
# evidence object with failure classification and lock-requirement hints.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$CorrelationId,

    [string]$SessionId,

    [string]$ToolUseId,

    [string]$EvidenceOutPath
)

$ErrorActionPreference = 'Stop'

function Find-EvidenceFile {
    param([string]$Dir, [string]$Pattern)
    if (-not (Test-Path $Dir)) { return $null }
    $files = @(Get-ChildItem -Path $Dir -Filter $Pattern -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) { return $null }
    return $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Read-JsonSafe {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return @{ parse_error = $_.Exception.Message; path = $Path }
    }
}

$EvidenceDir = Join-Path $HeliosGateRoot 'evidence'
$BlockedDir = Join-Path $HeliosGateRoot 'blocked'
$PendingDir = Join-Path $HeliosGateRoot 'pending'
$InflightDir = Join-Path $HeliosGateRoot 'inflight'
$MaintenanceDir = Join-Path $HeliosGateRoot 'evidence\maintenance'
$IntegrityDir = Join-Path $HeliosGateRoot 'evidence\integrity'

$Normalized = @{
    timestamp_utc           = (Get-Date).ToUniversalTime().ToString('o')
    session_id              = $SessionId
    tool_use_id             = $ToolUseId
    correlation_id          = $CorrelationId
    gate_id                 = $null
    command_sha256          = $null
    cwd                     = $null
    shell                   = $null
    verdict                 = $null
    protected_verdict       = $null
    runtime_verdict         = $null
    gate_lifecycle_state    = $null
    stdout_path             = $null
    stderr_path             = $null
    result_path             = $null
    blocked_record_path     = $null
    maintenance_record_path = $null
    failure_class           = $null
    lock_requirement_hint   = $null
    source_files            = @{}
    ingestion_errors        = @()
}

$GateFile = $null
$ResultFile = $null
$ToolResponseFile = $null

if ($CorrelationId) {
    $GateFile = Find-EvidenceFile -Dir $EvidenceDir -Pattern "*$CorrelationId*.gate.json"
    $ResultFile = Find-EvidenceFile -Dir $EvidenceDir -Pattern "*$CorrelationId*.result.json"
    $ToolResponseFile = Find-EvidenceFile -Dir $EvidenceDir -Pattern "*$CorrelationId*.tool_response.json"

    if (-not $GateFile) {
        $GateFile = Find-EvidenceFile -Dir $PendingDir -Pattern "*$CorrelationId*.gate.json"
    }
    if (-not $GateFile) {
        $GateFile = Find-EvidenceFile -Dir $InflightDir -Pattern "*$CorrelationId*.gate.json"
    }
}

if ($GateFile) {
    $Normalized.gate_id = $GateFile.Name
    $Normalized.source_files['gate'] = $GateFile.FullName
    $gate = Read-JsonSafe $GateFile.FullName
    if ($gate -and -not $gate.parse_error) {
        $Normalized.command_sha256 = $gate.command_sha256
        $Normalized.cwd = $gate.working_directory
        $Normalized.shell = $gate.shell
        $Normalized.correlation_id = $gate.correlation_id
    }
}

if ($ResultFile) {
    $Normalized.result_path = $ResultFile.FullName
    $Normalized.source_files['result'] = $ResultFile.FullName
    $result = Read-JsonSafe $ResultFile.FullName
    if ($result -and -not $result.parse_error) {
        if ($result.verdict) { $Normalized.verdict = $result.verdict }
        if ($result.hook_event -eq 'PostToolUse' -or $result.hook_event -eq 'PostToolUseFailure') {
            $Normalized.gate_lifecycle_state = 'post_execution'
        }
    }
}

if ($ToolResponseFile) {
    $Normalized.source_files['tool_response'] = $ToolResponseFile.FullName
}

$BeforeFile = $null
$DecisionFile = $null
$AfterFile = $null
$CompareFile = $null

if ($SessionId -and $ToolUseId) {
    $CmdDir = Join-Path $IntegrityDir "sessions\$SessionId\commands"
    if (Test-Path $CmdDir) {
        $BeforeFile = Join-Path $CmdDir "$ToolUseId.before.json"
        $DecisionFile = Join-Path $CmdDir "$ToolUseId.decision.json"
        $AfterFile = Join-Path $CmdDir "$ToolUseId.after.json"
        $CompareFile = Join-Path $CmdDir "$ToolUseId.compare.json"
    }
}

if ($BeforeFile -and (Test-Path $BeforeFile)) {
    $Normalized.source_files['before'] = $BeforeFile
}

if ($DecisionFile -and (Test-Path $DecisionFile)) {
    $Normalized.source_files['decision'] = $DecisionFile
    $decision = Read-JsonSafe $DecisionFile
    if ($decision -and -not $decision.parse_error) {
        if (-not $Normalized.verdict) { $Normalized.verdict = $decision.verdict }
    }
}

if ($AfterFile -and (Test-Path $AfterFile)) {
    $Normalized.source_files['after'] = $AfterFile
}

if ($CompareFile -and (Test-Path $CompareFile)) {
    $Normalized.source_files['compare'] = $CompareFile
    $compare = Read-JsonSafe $CompareFile
    if ($compare -and -not $compare.parse_error) {
        $Normalized.protected_verdict = $compare.protected_verdict
        $Normalized.runtime_verdict = $compare.runtime_verdict
    }
}

$BlockedFile = $null
if ($CorrelationId) {
    $BlockedFile = Find-EvidenceFile -Dir $BlockedDir -Pattern "*$CorrelationId*"
}
if (-not $BlockedFile -and $Normalized.command_sha256) {
    $hash12 = $Normalized.command_sha256.Substring(0, [Math]::Min(12, $Normalized.command_sha256.Length))
    $BlockedFile = Find-EvidenceFile -Dir $BlockedDir -Pattern "*$hash12*"
}
if ($BlockedFile) {
    $Normalized.blocked_record_path = $BlockedFile.FullName
    $Normalized.source_files['blocked'] = $BlockedFile.FullName
    if (-not $Normalized.verdict) { $Normalized.verdict = 'DENY' }
}

$MaintFile = $null
if (Test-Path $MaintenanceDir) {
    $MaintFile = Find-EvidenceFile -Dir $MaintenanceDir -Pattern '*.json'
}
if ($MaintFile) {
    $Normalized.maintenance_record_path = $MaintFile.FullName
    $Normalized.source_files['maintenance'] = $MaintFile.FullName
}

if ($CorrelationId -and $CorrelationId -match '^orphan-') {
    $Normalized.failure_class = 'orphan_evidence'
    $Normalized.lock_requirement_hint = 'post-hook robustness and fail-closed enforcement'
}

if (-not $Normalized.gate_lifecycle_state) {
    if ($GateFile -and $GateFile.DirectoryName -like '*pending*') {
        $Normalized.gate_lifecycle_state = 'pending'
    } elseif ($GateFile -and $GateFile.DirectoryName -like '*inflight*') {
        $Normalized.gate_lifecycle_state = 'inflight'
    } elseif ($GateFile -and $GateFile.DirectoryName -like '*evidence*') {
        $Normalized.gate_lifecycle_state = 'completed'
    }
}

if ($EvidenceOutPath) {
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $Json = $Normalized | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($EvidenceOutPath, $Json, $Utf8NoBom)
}

$Normalized | ConvertTo-Json -Depth 5
return $Normalized
