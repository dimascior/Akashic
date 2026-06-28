[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$CorrelationId,

    [int]$Last = 20,

    [switch]$Summary
)

$ErrorActionPreference = 'Stop'

$evidenceDir = Join-Path $HeliosGateRoot 'evidence'
if (-not (Test-Path $evidenceDir)) {
    Write-Host "No evidence directory: $evidenceDir"
    return @()
}

$pattern = if ($CorrelationId) { "$CorrelationId*" } else { '*.json' }
$files = Get-ChildItem -Path $evidenceDir -Filter $pattern -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $Last

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No evidence records found$(if ($CorrelationId) { " matching '$CorrelationId'" })."
    return @()
}

$results = @()
foreach ($file in $files) {
    try {
        $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        $record = $raw | ConvertFrom-Json

        if ($Summary) {
            $results += [ordered]@{
                file           = $file.Name
                correlation_id = $record.correlation_id
                timestamp      = $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
                command        = if ($record.command.Length -gt 60) { $record.command.Substring(0, 57) + '...' } else { $record.command }
                exit_code      = $record.exit_code
            }
        } else {
            $results += [ordered]@{
                file    = $file.Name
                content = $record
            }
        }
    } catch {
        $results += [ordered]@{
            file  = $file.Name
            error = $_.Exception.Message
        }
    }
}

if ($Summary) {
    Write-Host "Evidence records: $($results.Count)"
    foreach ($r in $results) {
        $exitInfo = if ($null -ne $r.exit_code) { "exit=$($r.exit_code)" } else { '' }
        Write-Host "  $($r.timestamp) | $($r.correlation_id) | $exitInfo | $($r.command)"
    }
}

return $results
