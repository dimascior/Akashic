# Phase 4.3: Akashic Self-Integrity Boundary - Raw Results

## Platform

- OS: Windows 10 Home 10.0.19045
- PowerShell: 5.1 (Desktop edition)
- Date: 2026-06-29

## Parse Validation

18/18 new and modified scripts PARSE_OK under PS 5.1:

| Script | Status |
|--------|--------|
| tools/New-AkashicSelfManifest.ps1 | PARSE_OK |
| tools/Test-AkashicSelfIntegrity.ps1 | PARSE_OK |
| tools/Assert-AkashicTrusted.ps1 | PARSE_OK |
| tools/Lock-AkashicRoot.ps1 | PARSE_OK |
| tools/Unlock-AkashicRoot.ps1 | PARSE_OK |
| tools/Invoke-AkashicSelfRebaseline.ps1 | PARSE_OK |
| tools/Apply-AkashicClaudeHooks.ps1 | PARSE_OK |
| tools/Remove-AkashicClaudeHooks.ps1 | PARSE_OK |
| tools/Install-AkashicHeliosRuntime.ps1 | PARSE_OK |
| tools/Lock-AkashicProtectedFiles.ps1 | PARSE_OK |
| tools/Unlock-AkashicProtectedFiles.ps1 | PARSE_OK |
| tools/AkashicEnvelopeManifest.ps1 | PARSE_OK |
| tools/Invoke-AkashicRebaseline.ps1 | PARSE_OK |
| tools/Sync-AkashicBridge.ps1 | PARSE_OK |
| tools/Lock-HeliosRuntime.ps1 | PARSE_OK |
| tools/Unlock-HeliosRuntime.ps1 | PARSE_OK |
| tools/Invoke-HeliosRuntimeRebaseline.ps1 | PARSE_OK |
| tools/Rollback-AkashicHeliosRuntime.ps1 | PARSE_OK |

## Manifest Generation

- Protected file count: 90
- Manifest path: manifest/akashic-envelope.json
- Sidecar path: manifest/akashic-envelope.sha256
- Signature status: SIGNATURE_NOT_IMPLEMENTED

## Self-Integrity Test Results

| Test | Description | Result |
|------|-------------|--------|
| 1 | Generate initial manifest | 90 protected files |
| 2 | Clean state verification | PASS (verdict=CLEAN, 90/90 clean) |
| 3 | Assert-AkashicTrusted on CLEAN | PASS (returned $true) |
| 4 | Drift detection (tamper tool file) | PASS (verdict=DRIFT, drift_count=1) |
| 5 | Assert-AkashicTrusted on DRIFT | PASS (threw AKASHIC_UNTRUSTED) |
| 6 | Sidecar mismatch detection | PASS (verdict=SIDECAR_MISMATCH) |
| 7 | Rebaseline restores CLEAN | PASS (pre=DRIFT, post=CLEAN) |

## Protected File Categories

| Role | Count | Pattern |
|------|-------|---------|
| bridge | 1 | AkashicIntegrityBridge.ps1 |
| tool | ~45 | tools/*.ps1 (Akashic-prefixed tools) |
| compatibility-wrapper | ~15 | tools/*.ps1 (Helios-prefixed wrappers) |
| library | 2 | tools/lib/*.ps1 |
| schema | 8 | schemas/*.json |
| contract-doc | ~15 | docs/*.md |
| test | 1 | Tests/*.ps1 |

## Mutable Paths

- evidence/
- manifest/akashic-envelope.sig (placeholder)
- manifest/akashic-public-key.asc (placeholder)

## Trust Boundary Statement

Hash-only self-integrity detects drift but does not prevent an agent with write access to both files and manifests from rewriting them. Signed or external authority is required for that guarantee. Signature verification is SIGNATURE_NOT_IMPLEMENTED. The placeholder files manifest/akashic-envelope.sig and manifest/akashic-public-key.asc define the future interface but provide no cryptographic authority separation in this phase.

## Assert-AkashicTrusted Integration

12 high-impact tools now call Assert-AkashicTrusted.ps1 before modifying Helios, Claude settings, locks, manifests, sidecars, or runtime bundles:

- Apply-AkashicClaudeHooks.ps1
- Remove-AkashicClaudeHooks.ps1
- Install-AkashicHeliosRuntime.ps1
- Lock-AkashicProtectedFiles.ps1
- Unlock-AkashicProtectedFiles.ps1
- AkashicEnvelopeManifest.ps1
- Invoke-AkashicRebaseline.ps1
- Sync-AkashicBridge.ps1
- Lock-HeliosRuntime.ps1
- Unlock-HeliosRuntime.ps1
- Invoke-HeliosRuntimeRebaseline.ps1
- Rollback-AkashicHeliosRuntime.ps1

## Lock Status

Lock-AkashicRoot.ps1 and Unlock-AkashicRoot.ps1 are implemented and use the existing platform lock backend (Windows icacls, Linux chattr, macOS chflags). Locks were not applied in this test run because runtime locking is a post-verification step per the project roadmap.

## Fixes Applied During Implementation

- Invoke-AkashicRebaseline.ps1: replaced em dashes with ASCII dashes (8 occurrences) to fix PS 5.1 parse failure at line 118
