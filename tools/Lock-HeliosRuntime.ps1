[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$HeliosGateRoot,

    [Parameter(Mandatory)]
    [string]$AkashicRoot,

    [switch]$RequireStrongLock,

    [switch]$RunFixtureFirst,

    [string]$EvidenceOutputDir
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $HeliosGateRoot)) {
    throw "Helios gate root not found: $HeliosGateRoot"
}

$lockScript = Join-Path $AkashicRoot 'tools' 'Lock-AkashicProtectedFiles.ps1'
if (-not (Test-Path $lockScript)) {
    throw "Lock script not found: $lockScript"
}

if ($RunFixtureFirst) {
    Write-Host '--- Fixture check ---'
    $fixtureScript = Join-Path $AkashicRoot 'tools' 'Test-AkashicOsLockFixture.ps1'
    if (-not (Test-Path $fixtureScript)) {
        throw "Fixture script not found: $fixtureScript"
    }
    $fixtureResult = & $fixtureScript -HeliosGateRoot $HeliosGateRoot
    if ($fixtureResult.overall_result -ne 'PASS') {
        throw "Fixture FAILED. Cannot lock runtime without passing fixture."
    }
    Write-Host "Fixture: PASS"
}

Write-Host '--- Locking runtime ---'
$lockArgs = @{ HeliosGateRoot = $HeliosGateRoot }
if ($RequireStrongLock) {
    $lockArgs['RequireStrongLock'] = $true
}
if ($EvidenceOutputDir) {
    $lockArgs['EvidenceOutputDir'] = $EvidenceOutputDir
}

$lockResult = & $lockScript @lockArgs
Write-Host "Lock result: $($lockResult.status)"

return $lockResult
