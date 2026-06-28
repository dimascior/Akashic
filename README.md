# Akashic

Integrity witness adapter for the Helios command-gate system. Provides envelope verification, evidence capture, and lock/control tooling for gated command execution.

## Purpose

Helios gates shell commands via PreToolUse/PostToolUse hooks but cannot prove its own enforcement files were intact when the gate decision was made. Akashic gives Helios a local integrity witness: it hashes protected files, compares them against a durable manifest and session baseline, and writes structured evidence for every command.

## Envelope Model

### Protected Enforcement Envelope

Files that **must not change** during gated execution:

| Relative Path | Role |
|---|---|
| `hooks/gate_check.ps1` | Command validation logic |
| `hooks/evidence_capture.ps1` | PostToolUse/PostToolUseFailure evidence |
| `hooks/tier_classifier.ps1` | Command tier classification |
| `hooks/helios_pretooluse.ps1` | Front controller (integrity check before policy load) |
| `hooks/lib/HeliosIntegrityBridge.ps1` | Vendored copy of this adapter |
| `policy/command-policy.json` | Tier patterns and gate policy |

### Mutable Runtime Envelope

Directories that **must change** as part of the gate lifecycle:

- `pending/` — gates awaiting execution
- `inflight/` — gates currently executing
- `evidence/` — completed gate records
- `blocked/` — denied command records

## Trust Model

### Durable Manifest

`manifest/helios-envelope.json` — contains expected SHA256 hashes for all protected files.
`manifest/helios-envelope.sha256` — SHA256 of the manifest JSON (sidecar, avoids self-hash).

The manifest is the root of trust. It is valid only if created by a human rebaseline step and has not drifted since.

### Session Baseline

`evidence/integrity/sessions/<session_id>/baseline.json` — snapshot of protected hashes at session start, created only after verifying against the durable manifest. Provides session continuity evidence.

### Dual Comparison

Every PreToolUse check compares current state against **both**:
1. Durable manifest — "Does the envelope match the known-good install state?"
2. Session baseline — "Has anything changed since this session started clean?"

If either comparison fails, Helios denies.

## Per-Command Evidence Layout

```
evidence/integrity/sessions/<session_id>/
  baseline.json
  commands/
    <tool_use_id>.before.json    — pre-command protected snapshot
    <tool_use_id>.decision.json  — allow/deny/integrity_failure verdict
    <tool_use_id>.after.json     — post-command snapshot (if executed)
    <tool_use_id>.compare.json   — protected + runtime comparison (if executed)
```

## Bridge API

All functions are self-contained (no module imports). PowerShell 5.1+ compatible.

| Function | Purpose |
|---|---|
| `Get-FileSha256` | Raw-byte SHA256 of a file, lowercase hex |
| `Get-HeliosEnvelopeSnapshot` | Hash protected files, capture mutable dir state |
| `Compare-HeliosProtectedEnvelope` | Compare snapshot against manifest and/or baseline |
| `Compare-HeliosRuntimeTransition` | Lifecycle-aware comparison of mutable dirs |
| `New-HeliosSessionBaseline` | Create baseline after verifying manifest integrity |
| `Test-HeliosIntegrity` | Quick pass/fail: current files vs manifest hashes |
| `Write-HeliosIntegrityEvidence` | Write before/decision/after/compare JSON files |

### Expected Mutation Profiles

`Compare-HeliosRuntimeTransition` takes an `ExpectedMutationProfile` parameter:

- `ALLOW_PRETOOL` — pending loses gate, inflight gains gate
- `ALLOW_POSTTOOL` — inflight loses gate, evidence gains result
- `DENY_PRETOOL` — all dirs stable, blocked gains record
- `INTEGRITY_FAILURE` — all dirs stable

## Sync Model

This repo (Akashic) owns the source bridge at `AkashicIntegrityBridge.ps1`.
Helios consumes a vendored copy at `.command-gate/hooks/lib/HeliosIntegrityBridge.ps1`.

Sync process:
1. Run `tools/Sync-AkashicBridge.ps1` to copy source to vendored location.
2. Verify byte-identity between source and destination.
3. Run `tools/AkashicEnvelopeManifest.ps1` to rebaseline the manifest.
4. Verify with `tools/AkashicEnvelopeIntegrityValidation.ps1`.

## Rebaseline

When any protected file changes (including the vendored bridge after sync):
1. Run `AkashicEnvelopeManifest.ps1 -HeliosGateRoot <path> -RebaselinedBy human`.
2. Verify: `AkashicEnvelopeIntegrityValidation.ps1 -HeliosGateRoot <path>`.
3. The manifest JSON and sidecar hash are regenerated.

## Cross-Platform Lock Strategy

Akashic decides **what** to protect. The OS backend decides **how** to protect it. Evidence proves **whether** protection worked on that machine.

PowerShell is the orchestration language for all lock operations. Native OS commands are backend lock mechanisms only, invoked through `& $CommandPath @Arguments`, never through shell strings or Invoke-Expression.

| Platform | Backend | Lock | Unlock | Status | Strength |
|---|---|---|---|---|---|
| Windows | icacls | `/deny "*S-1-1-0:(W,D)"` | `/remove:d "*S-1-1-0"` | Parse DENY ACE | strong |
| Linux | chattr | `+i` | `-i` | lsattr for `i` flag | strong_if_supported |
| macOS | chflags | `uchg` | `nouchg` | `ls -lO` for `uchg` | strong_user_immutable |
| POSIX | chmod | `a-w` | `u+w` | mode bits | weak_fallback (opt-in) |

`Get-AkashicLockStrategy.ps1` resolves the backend at runtime. Lock/unlock/status tools dot-source `tools/lib/AkashicLockTargets.ps1` (protected file inventory) and `tools/lib/AkashicLockBackend.ps1` (backend dispatch). No platform-specific `if` blocks in consumer tools.

Linux/macOS support requires fixture validation (`Test-AkashicOsLockFixture.ps1`) before being marked complete. Active Helios runtime locking remains deferred until explicitly approved.

The lock workflow: unlock → rebaseline → relock. This repo owns the lock/unlock tooling.

## Schemas

See `schemas/` for JSON Schema definitions of:

- `helios-envelope.v1` — durable manifest
- `helios-baseline.v1` — session baseline
- `helios-command-evidence.v1` — before, decision, after, compare evidence
- `helios-rebaseline.v1` — rebaseline audit record

## Packaging

### Distribution

Akashic is the standalone adapter repo for Helios integrity enforcement, extracted from the `helios-integrity-adapter` branch of [TerminalContextExporter](https://github.com/dimascior/TerminalContextExporter).

**Development:**
```bash
git clone https://github.com/dimascior/Akashic.git
```

### Package Tools

| Tool | Purpose |
|---|---|
| `tools/AkashicPackage.ps1` | Build a distributable Akashic adapter package |
| `tools/AkashicPackageValidation.ps1` | Verify adapter package contents and checksums |
| `tools/AkashicRuntimeBundle.ps1` | Build a distributable Helios runtime bundle |
| `tools/AkashicRuntimeBundleValidation.ps1` | Verify runtime bundle contents, checksums, BOM safety |
| `tools/AkashicHeliosInstallPlan.ps1` | Unified 16-phase install planner (PlanOnly/Prepare/Activate) |
| `tools/AkashicCombinedInstallPlan.ps1` | Legacy combined install plan |
| `tools/AkashicEndToEndInstallPlanValidation.ps1` | Simulate install in temp directory |
| `tools/AkashicInstallPlan.ps1` | Legacy adapter-only install plan |

### Lock Tools

| Tool | Purpose |
|---|---|
| `tools/Get-AkashicLockStrategy.ps1` | Resolve OS-native lock backend (icacls/chattr/chflags/chmod) |
| `tools/lib/AkashicLockTargets.ps1` | Protected file and mutable directory inventory |
| `tools/lib/AkashicLockBackend.ps1` | Backend dispatch: privilege wrapping, lock/unlock/status, evidence format |
| `tools/Lock-AkashicProtectedFiles.ps1` | Apply OS-native locks to protected files |
| `tools/Unlock-AkashicProtectedFiles.ps1` | Remove locks for maintenance rebaseline |
| `tools/AkashicLockStatus.ps1` | Verify all lock targets are in expected state |
| `tools/Invoke-AkashicRebaseline.ps1` | Coordinated unlock→update→relock→verify cycle |
| `tools/Test-AkashicOsLockFixture.ps1` | Disposable fixture test for lock backend validation |
| `tools/Move-AkashicStaleGateArtifacts.ps1` | Clean expired pending/ and orphaned inflight/ gates |
| `tools/AkashicSettingsIntegrity.ps1` | Verify settings.json hook entries (control-plane check) |

### Install Flow

1. Pull adapter package and runtime bundle.
2. Verify both: `AkashicPackageValidation.ps1` and `AkashicRuntimeBundleValidation.ps1`.
3. Generate unified install plan: `AkashicHeliosInstallPlan.ps1 -Mode PlanOnly`.
4. Review plan. If ready, run with `-Mode Prepare` to copy files, sync bridge, generate manifest.
5. Run lock fixture: `Test-AkashicOsLockFixture.ps1` — must PASS before any lock activation.
6. Verify envelope: `AkashicEnvelopeIntegrityValidation.ps1 -HeliosGateRoot <path>`.
7. When ready for activation: `-Mode Activate -IncludeSettingsActivation` (requires human approval).

See `docs/install-sequence.md` for the complete procedure, `docs/package-architecture.md` for the two-package model, and `docs/akashic-helios-installer-contract.md` for the installer contract.

## Current Status

**Phase:** 4.1 — cross-platform lock/unlock/rebaseline tooling. Windows fixture PASS. Linux/macOS lock backends designed but not validated on physical machines. Installer contract defined. Active Helios runtime locking deferred until fixture + installer pass per platform.

| Component | Status |
|---|---|
| Bridge implementation (7 functions) | Complete |
| Sync, manifest, integrity tools | Complete |
| Pester test suite (18 tests) | Complete |
| Schemas (4 JSON Schema files) | Complete |
| TCE adapter spec | Complete — `docs/tce-helios-integrity-adapter-spec.md` |
| Orchestration workflow | Complete — `tools/Invoke-AkashicGapTest.ps1` |
| Evidence parser/normalizer | Complete — `tools/ConvertFrom-AkashicEvidence.ps1` |
| Gap-test matrix (12 tests) | Complete — `evidence/gap-tests/` |
| Phase 4 lock requirements | Complete — `docs/phase4-lock-requirements-from-gap-tests.md` |
| Package architecture | Complete — `docs/package-architecture.md` |
| Adapter package tools (3) | Complete — build, verify, install-plan |
| Runtime bundle tools (2) | Complete — build, verify |
| Combined installer | Complete — `tools/AkashicCombinedInstallPlan.ps1` |
| End-to-end simulation | Complete — `tools/AkashicEndToEndInstallPlanValidation.ps1` |
| BOM hardening | Complete — manifest/sidecar writes BOM-free, integrity check includes BOM detection |
| Package validation (3.99.1) | Complete — adapter verifier BOM checks, runtime manifest completeness, e2e execution |
| Install sequence | Complete — `docs/install-sequence.md` |
| Lock design (4.0) | Complete — `docs/phase40-lock-design-from-gap-evidence.md` |
| Lock tooling (4.1) | Windows validated, Linux/macOS backends designed but not validated — `docs/phase41-lock-implementation.md` |
| Lock strategy resolver | Complete — `Get-AkashicLockStrategy.ps1` (icacls/chattr/chflags/chmod) |
| Lock dispatch layer | Complete — `lib/AkashicLockTargets.ps1` + `lib/AkashicLockBackend.ps1` (inventory + backend dispatch) |
| Lock/unlock tools | Windows fixture PASS. Linux/macOS backends exist in code but require physical machine fixture validation |
| Lock fixture test | Windows PASS — `Test-AkashicOsLockFixture.ps1`. Linux/macOS NOT_TESTED (requires physical machines) |
| Installer contract | Defined — `docs/akashic-helios-installer-contract.md` |
| Unified installer | Created — `tools/AkashicHeliosInstallPlan.ps1` (16-phase, PlanOnly/Prepare/Activate) |
| Rebaseline workflow | Implemented — live 7-step cycle pending |
| Stale gate cleanup | Implemented — `tools/Move-AkashicStaleGateArtifacts.ps1` |
| Settings integrity | Verified — `AkashicSettingsIntegrity` passes against live settings.json |
| Rebaseline schema | Validated — fixture record matches `schemas/helios-rebaseline.schema.json` |
| Phase 4.1 evidence | Partial — `evidence/phase41/` (10 evidence files, fixture validation complete, live runtime deferred) |
| TCE main preservation | Verified — TCE main preserved at `c594a75` with no adapter entries |

### Provenance

Originally extracted from [TerminalContextExporter](https://github.com/dimascior/TerminalContextExporter) branch `helios-integrity-adapter` at commit `d0ab1ff`. TCE main (`c594a75`) was preserved without adapter entries. The standalone repo ([Akashic](https://github.com/dimascior/Akashic)) is the active source. See `docs/standalone-repo-transition.md` for the extraction history.

### Phase Roadmap

| Phase | Status |
|---|---|
| Phase 0-3.96 | Complete (Helios runtime + TCE bridge) |
| Phase 3.97 | Complete (TCE gap-tests + lock derivation) |
| Phase 3.98 | Complete (packaging architecture + install tooling) |
| Phase 3.99 | Complete (runtime bundle + BOM hardening + e2e simulation) |
| Phase 3.99.1 | Complete (package validation + manifest hardening + execution proof) |
| Phase 3.99.2 | Complete (final readback audit) |
| Phase 4.0 | Complete (lock design from gap evidence) |
| Phase 4.1 | In progress (cross-platform lock strategy — Windows PASS, Linux/macOS pending physical test) |
| Phase 4.2 | Future — live lock verification evidence |
| Phase 5 | Future — lock system packaging |
| Phase 6 | Future — long-term lock verification + audit strategy |
