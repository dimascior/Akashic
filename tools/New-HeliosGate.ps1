[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Command,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$CorrelationId,

    [string]$WorkingDirectory,

    [ValidateSet('bash','powershell')]
    [string]$Shell = 'bash',

    [ValidateRange(0,3)]
    [int]$RiskTier = 0,

    [string]$Need,
    [string]$Expected,
    [string]$ActualMeans,
    [string]$NextLogic,

    [ValidateSet('not_applicable','stdout_capture','file_capture')]
    [string]$ExitCapture = 'not_applicable',

    [ValidateSet('pure_output','no_exit_code_semantic','interactive_tool','background_process')]
    [string]$ExitCaptureReason = 'pure_output',

    [int]$ExpiresInMinutes = 60,

    [string[]]$StopConditions,
    [string[]]$Reads,
    [string[]]$Writes,
    [string[]]$Deletes,

    [string]$ApprovalBoundary = 'This gate makes the command eligible for permission flow only; it does not auto-approve execution.'
)

$ErrorActionPreference = 'Stop'

$pendingDir = Join-Path $HeliosGateRoot 'pending'
if (-not (Test-Path $pendingDir)) {
    throw "Pending directory not found: $pendingDir"
}

if (-not $CorrelationId) {
    $CorrelationId = "gate-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString().Substring(0,8))"
}

if (-not $WorkingDirectory) {
    $WorkingDirectory = (Get-Location).Path
}

$nowUtc = (Get-Date).ToUniversalTime()
$createdUtc = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$expiresUtc = $nowUtc.AddMinutes($ExpiresInMinutes).ToString('yyyy-MM-ddTHH:mm:ssZ')

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$shaBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Utf8NoBom.GetBytes($Command))
$commandSha256 = ($shaBytes | ForEach-Object { $_.ToString('x2') }) -join ''

$hasChaining = $Command -match '(&&|\|\||;|\|)'
$multiCommand = $hasChaining

$segments = @()
if ($multiCommand) {
    $parts = $Command -split '\s*&&\s*'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $segments += [ordered]@{
            index   = $i
            command = $parts[$i].Trim()
            purpose = ''
        }
    }
}

$gate = [ordered]@{
    schema_version    = 'command-gate.v1'
    correlation_id    = $CorrelationId
    created_utc       = $createdUtc
    expires_utc       = $expiresUtc
    command           = $Command
    command_sha256    = $commandSha256
    working_directory = $WorkingDirectory
    shell             = $Shell
    risk_tier         = $RiskTier
    exit_capture      = $ExitCapture
    exit_capture_reason = $ExitCaptureReason
    multi_command     = $multiCommand
    segments          = $segments
    need              = if ($Need) { $Need } else { '' }
    expected          = if ($Expected) { $Expected } else { '' }
    actual_means      = if ($ActualMeans) { $ActualMeans } else { '' }
    next_logic        = if ($NextLogic) { $NextLogic } else { '' }
    approval_boundary = $ApprovalBoundary
}

if ($RiskTier -ge 3) {
    if (-not $StopConditions) {
        $StopConditions = @()
    }
    $gate['stop_conditions'] = $StopConditions
    $gate['read_write_impact'] = [ordered]@{
        reads   = if ($Reads) { $Reads } else { @() }
        writes  = if ($Writes) { $Writes } else { @() }
        deletes = if ($Deletes) { $Deletes } else { @() }
    }
}

if ($Writes -and $Writes.Count -gt 0 -and $RiskTier -lt 3) {
    $gate['read_write_impact'] = [ordered]@{
        reads   = if ($Reads) { $Reads } else { @() }
        writes  = $Writes
        deletes = if ($Deletes) { $Deletes } else { @() }
    }
}

$gateJson = $gate | ConvertTo-Json -Depth 10
$gatePath = Join-Path $pendingDir "$CorrelationId.gate.json"

[System.IO.File]::WriteAllText($gatePath, $gateJson, $Utf8NoBom)

Write-Host "Gate created: $gatePath"
Write-Host "Correlation ID: $CorrelationId"
Write-Host "Command SHA256: $commandSha256"
Write-Host "Expires: $expiresUtc"

return [ordered]@{
    gate_path      = $gatePath
    correlation_id = $CorrelationId
    command_sha256 = $commandSha256
    expires_utc    = $expiresUtc
}
