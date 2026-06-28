# Invoke-HeliosGapTest.ps1 — TCE-owned gap-test orchestration
# Captures pre/post state, applies controlled mutations, compares envelopes,
# ingests Helios evidence, emits TCE-local evidence, and records restoration.
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [string]$TestName,

    [Parameter(Mandatory)]
    [string]$EvidenceOutDir,

    [string]$SessionId = [guid]::NewGuid().ToString(),

    [switch]$DryRun,

    [ValidateSet('PlanOnly', 'FixtureOnly', 'LiveControlled')]
    [string]$Mode = 'LiveControlled'
)

$ErrorActionPreference = 'Stop'

$BridgePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'HeliosIntegrityBridge.ps1'
if (-not (Test-Path $BridgePath)) {
    throw "Bridge not found: $BridgePath"
}
. $BridgePath

$TestId = "$TestName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$TestDir = Join-Path $EvidenceOutDir $TestName
if (-not (Test-Path $TestDir)) {
    New-Item -ItemType Directory -Path $TestDir -Force | Out-Null
}

$ManifestPath = Join-Path $HeliosGateRoot 'manifest\helios-envelope.json'
$SidecarPath = Join-Path $HeliosGateRoot 'manifest\helios-envelope.sha256'

if (-not (Test-Path $ManifestPath)) { throw "Manifest not found: $ManifestPath" }
if (-not (Test-Path $SidecarPath)) { throw "Sidecar not found: $SidecarPath" }

$Manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$ManifestHashes = @{}
foreach ($prop in $Manifest.protected.hashes.PSObject.Properties) {
    $ManifestHashes[$prop.Name] = $prop.Value
}

function Write-TestEvidence {
    param(
        [string]$FileName,
        [hashtable]$Data
    )
    $Path = Join-Path $TestDir $FileName
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $Json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $Json, $Utf8NoBom)
    return $Path
}

$Result = @{
    test_name              = $TestName
    test_id                = $TestId
    timestamp_utc          = (Get-Date).ToUniversalTime().ToString('o')
    mode                   = $Mode
    dry_run                = $DryRun.IsPresent
    pre_snapshot_path      = $null
    post_snapshot_path     = $null
    compare_path           = $null
    helios_evidence_refs   = @()
    verdict                = 'NOT_EXECUTED'
    tce_classification     = $null
    failure_class          = $null
    lock_requirement_hint  = $null
    cleanup_result         = $null
    restoration_verified   = $false
    error                  = $null
}

if ($Mode -eq 'PlanOnly') {
    $Result.verdict = 'PLAN_ONLY'
    $PlanPath = Write-TestEvidence -FileName 'test-plan.json' -Data $Result
    $Result | ConvertTo-Json -Depth 5
    return $Result
}

try {
    $PreSnapshot = Get-HeliosEnvelopeSnapshot -GateRoot $HeliosGateRoot -ManifestHashes $ManifestHashes `
        -SessionId $SessionId -ToolUseId "gap-test-$TestId" -CommandSha256 'gap-test'
    $PrePath = Write-TestEvidence -FileName 'pre.json' -Data $PreSnapshot
    $Result.pre_snapshot_path = $PrePath

    $PreIntegrity = Compare-HeliosProtectedEnvelope -CurrentSnapshot $PreSnapshot -ManifestHashes $ManifestHashes
    if ($PreIntegrity.verdict -ne 'CLEAN') {
        $Result.verdict = 'ABORTED_PRE_DRIFT'
        $Result.error = 'Protected envelope is not clean before test — aborting to avoid compounding drift'
        Write-TestEvidence -FileName 'compare.json' -Data $PreIntegrity | Out-Null
        $Result | ConvertTo-Json -Depth 5
        return $Result
    }

    if ($DryRun) {
        $Result.verdict = 'DRY_RUN'
        $Result | ConvertTo-Json -Depth 5
        return $Result
    }

    $Result.verdict = 'PRE_CAPTURED'
} catch {
    $Result.verdict = 'ERROR'
    $Result.error = $_.Exception.Message
}

$Result | ConvertTo-Json -Depth 5
return $Result
