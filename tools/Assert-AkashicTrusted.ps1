# Assert-AkashicTrusted.ps1 - Fail-closed self-integrity guard
# Callable by other Akashic tools before modifying Helios, Claude settings,
# locks, manifests, sidecars, or runtime bundles.
# Returns $true on CLEAN. Throws on any other state.
[CmdletBinding()]
param(
    [string]$AkashicRoot
)

$ErrorActionPreference = 'Stop'

if (-not $AkashicRoot) {
    $AkashicRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
}

$verifyScript = Join-Path $AkashicRoot 'tools\Test-AkashicSelfIntegrity.ps1'
if (-not (Test-Path $verifyScript)) {
    throw 'AKASHIC_UNTRUSTED: Test-AkashicSelfIntegrity.ps1 not found. Akashic self-integrity cannot be verified.'
}

$result = & $verifyScript -AkashicRoot $AkashicRoot

if ($result.verdict -eq 'CLEAN') {
    return $true
}

$reason = switch ($result.verdict) {
    'DRIFT'                    { "file drift detected ($($result.drift_count) drifted, $($result.missing_count) missing, $($result.unmanifested_files.Count) unmanifested)" }
    'NO_MANIFEST'              { 'akashic-envelope.json not found' }
    'SIDECAR_MISMATCH'         { 'akashic-envelope.sha256 does not match manifest hash' }
    'UNCLASSIFIED_FILES_FOUND' { "$($result.classification_audit.unknown_unclassified_count) unclassified file(s) found - update coverage policy in AkashicCoveragePolicy.ps1 and rebaseline" }
    default                    { "unknown verdict: $($result.verdict)" }
}

throw "AKASHIC_UNTRUSTED: $reason. Run Invoke-AkashicSelfRebaseline.ps1 after verifying changes are intentional."
