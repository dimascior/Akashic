[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    $Detection,

    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [string]$AkashicEvidenceDir
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$sep = [System.IO.Path]::DirectorySeparatorChar
$evidencePaths = [System.Collections.Generic.List[string]]::new()

$ts = $Detection.timestamp_utc -replace '[:\-]', '' -replace 'T', '-' -replace 'Z', ''
$type = $Detection.detection_type

# --- Write detection evidence to HeliosGateRoot ---
$detectionsDir = Join-Path $HeliosGateRoot ('evidence\detections'.Replace('\', $sep))
if (-not (Test-Path $detectionsDir)) {
    New-Item -ItemType Directory -Path $detectionsDir -Force | Out-Null
}

$detectionFileName = "$ts-$type.json"
$detectionPath = Join-Path $detectionsDir $detectionFileName
$Detection.evidence_paths = @($detectionPath)
$detectionJson = $Detection | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($detectionPath, $detectionJson, $Utf8NoBom)
$evidencePaths.Add($detectionPath)
Write-Host "Detection evidence: $detectionPath"

# --- Write to Akashic evidence directory if provided ---
if ($AkashicEvidenceDir) {
    if (-not (Test-Path $AkashicEvidenceDir)) {
        New-Item -ItemType Directory -Path $AkashicEvidenceDir -Force | Out-Null
    }
    $akashicEvidencePath = Join-Path $AkashicEvidenceDir $detectionFileName
    [System.IO.File]::WriteAllText($akashicEvidencePath, $detectionJson, $Utf8NoBom)
    $evidencePaths.Add($akashicEvidencePath)
    Write-Host "Akashic evidence:  $akashicEvidencePath"
}

# --- Terminal summary ---
Write-Host ''
Write-Host '=== Detection Summary ==='
Write-Host ''

$severityColor = switch ($Detection.severity) {
    'CRITICAL' { 'Red' }
    'HIGH'     { 'Yellow' }
    'MEDIUM'   { 'Cyan' }
    'INFO'     { 'Green' }
    default    { 'White' }
}

Write-Host "  Detection:    " -NoNewline
Write-Host $Detection.detection_type -ForegroundColor $severityColor
Write-Host "  Severity:     " -NoNewline
Write-Host $Detection.severity -ForegroundColor $severityColor
Write-Host "  Action:       $($Detection.recommended_action)"
Write-Host "  Mode:         $($Detection.automation_mode)"
Write-Host "  Result:       $($Detection.automation_result)"
Write-Host ''
Write-Host "  Manifest:     $($Detection.current_manifest_verdict)"
Write-Host "  Sidecar:      $($Detection.sidecar_verdict)"
Write-Host "  Origin:       $($Detection.origin_verdict)"
Write-Host "  Source repo:  $($Detection.source_repo_status.verdict)"
Write-Host "  Bridge:       $($Detection.bridge_status.verdict)"

if ($Detection.affected_files -and $Detection.affected_files.Count -gt 0) {
    Write-Host ''
    Write-Host '  Affected files:'
    foreach ($f in $Detection.affected_files) {
        $mark = switch ($f.status) { 'DRIFT' { '~' }; 'MISSING' { '-' }; 'UNTRACKED' { '?' }; default { ' ' } }
        Write-Host "    [$mark] $($f.path)"
    }
}

if ($Detection.source_repo_status.changed_source_files -and $Detection.source_repo_status.changed_source_files.Count -gt 0) {
    Write-Host ''
    Write-Host '  Changed source files:'
    foreach ($f in $Detection.source_repo_status.changed_source_files) {
        Write-Host "    [~] $f"
    }
}

Write-Host ''
Write-Host "  Akashic HEAD:  $($Detection.akashic_head)"
Write-Host "  Helios HEAD:   $($Detection.helios_head)"
Write-Host ''

$Detection.evidence_paths = [string[]]$evidencePaths

return [ordered]@{
    detection_type  = $Detection.detection_type
    severity        = $Detection.severity
    evidence_paths  = [string[]]$evidencePaths
    evidence_count  = $evidencePaths.Count
}
