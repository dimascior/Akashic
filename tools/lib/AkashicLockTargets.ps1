# AkashicLockTargets.ps1 — Shared lock target inventory
# Dot-source from lock/unlock/status/fixture tools.

$script:AkashicProtectedFiles = @(
    'hooks/helios_pretooluse.ps1',
    'hooks/gate_check.ps1',
    'hooks/evidence_capture.ps1',
    'hooks/tier_classifier.ps1',
    'hooks/lib/HeliosIntegrityBridge.ps1',
    'policy/command-policy.json',
    'manifest/helios-envelope.json',
    'manifest/helios-envelope.sha256'
)

$script:AkashicMutableDirs = @(
    'pending',
    'inflight',
    'evidence',
    'blocked'
)
