[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [switch]$IncludeExpired
)

$ErrorActionPreference = 'Stop'

$pendingDir = Join-Path $HeliosGateRoot 'pending'
if (-not (Test-Path $pendingDir)) {
    Write-Host "No pending directory: $pendingDir"
    return @()
}

$gateFiles = Get-ChildItem -Path $pendingDir -Filter '*.gate.json' -File -ErrorAction SilentlyContinue
if (-not $gateFiles -or $gateFiles.Count -eq 0) {
    Write-Host 'No pending gates.'
    return @()
}

$nowUtc = (Get-Date).ToUniversalTime()
$results = @()

foreach ($file in $gateFiles) {
    try {
        $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        $gate = $raw | ConvertFrom-Json

        $expired = $false
        if ($gate.expires_utc) {
            $expiresAt = [DateTime]::Parse($gate.expires_utc).ToUniversalTime()
            $expired = $nowUtc -gt $expiresAt
        }

        if ($expired -and -not $IncludeExpired) { continue }

        $results += [ordered]@{
            file           = $file.Name
            correlation_id = $gate.correlation_id
            command        = if ($gate.command.Length -gt 80) { $gate.command.Substring(0, 77) + '...' } else { $gate.command }
            risk_tier      = $gate.risk_tier
            expires_utc    = $gate.expires_utc
            expired        = $expired
            shell          = $gate.shell
        }
    } catch {
        $results += [ordered]@{
            file  = $file.Name
            error = $_.Exception.Message
        }
    }
}

Write-Host "Pending gates: $($results.Count) found$(if (-not $IncludeExpired) { ' (active only)' })"
foreach ($r in $results) {
    $status = if ($r.expired) { 'EXPIRED' } elseif ($r.error) { 'PARSE_ERROR' } else { 'ACTIVE' }
    Write-Host "  [$status] $($r.correlation_id) | tier $($r.risk_tier) | $($r.command)"
}

return $results
