# Akashic

Trust witness, installer, and integrity tooling for the Helios command-gate system. Provides envelope verification, manifest generation and rebaseline, settings integrity verification, session continuity forensic auditing, maintenance transition evidence, lock tooling, and the Helios runtime installer.

## Purpose

Helios gates shell commands via PreToolUse/PostToolUse hooks but cannot prove its own enforcement files were intact when the gate decision was made. Akashic gives Helios a local integrity witness: it hashes protected files, compares them against a durable manifest and session baseline, and writes structured evidence for every command.

Akashic also owns the Helios installer. The installer prepares, validates, and activates a Helios runtime bundle. It copies files, verifies package and runtime bundle hashes, syncs the Akashic bridge into Helios, generates or verifies manifests, validates settings hooks, optionally runs lock fixture checks, and activates Claude settings when approved. Installer activation does not approve runtime commands — Helios remains the runtime gate for every command.

## Installer Role

Akashic owns the Helios runtime installer via `AkashicHeliosInstallPlan.ps1`. The installer operates in three modes:

| Mode | Behavior |
|---|---|
| `PlanOnly` | Produces the intended install/activation plan without writing runtime state. |
| `Prepare` | Copies/syncs files, generates manifests, validates bundle and package integrity. Does not activate hooks or modify Claude settings. |
| `Activate` | Updates Claude settings and hook wiring after human approval. |

The installer does not replace the live Helios gate. It prepares, validates, and activates a Helios runtime bundle. Its responsibilities include:

- Copying runtime files from the bundle to the target `.command-gate/` directory
- Syncing the Akashic bridge source into Helios (`Sync-AkashicBridge.ps1`)
- Generating or verifying manifests and sidecar hashes
- Validating package and runtime bundle checksums
- Validating settings hook entries
- Optionally running lock fixture checks
- Activating Claude settings only when explicitly approved

Installer activation is not the same as runtime command approval. Helios still gates every command at runtime.

## Envelope Model

### Protected Enforcement Envelope

Files that **must not change** during gated execution:

| Relative Path | Role |
|---|---|
| `hooks/helios_pretooluse.ps1` | Front controller (integrity check before policy load) |
| `hooks/gate_check.ps1` | Command validation logic |
| `hooks/evidence_capture.ps1` | PostToolUse/PostToolUseFailure evidence |
| `hooks/tier_classifier.ps1` | Command tier and capability classification |
| `hooks/lib/HeliosIntegrityBridge.ps1` | Vendored copy of this adapter |
| `policy/command-policy.json` | Tier patterns, capability patterns, and gate policy |

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

## Settings Integrity

`AkashicSettingsIntegrity.ps1` verifies Claude settings hook entries: checks that Helios hooks (PreToolUse, PostToolUse, PostToolUseFailure) are present in `settings.json`, that they point to the expected scripts, and returns hook commands, presence status, and a settings hash suitable for embedding in per-command evidence.

Helios `evidence_capture.ps1` includes `settings_integrity_after` in every PostToolUse evidence record, recording `all_hooks_present`, individual hook presence, hook commands, and `settings_hash`.

## Session Continuity Audit

`Test-HeliosSessionContinuity.ps1` is a forensic tool that reads the Helios session ledger for a given session ID, walks every entry, confirms matching gate/evidence chains, and reports: total commands, evidence gaps, and continuity verdict (`CONTINUOUS` or `BROKEN` at command N).

The session ledger (`session/session-ledger-<session_id>.jsonl`) is written by Helios at runtime. Each command produces up to three entries: `pretooluse_seen`, `gate_consumed`, and `posttooluse_evidence_written`. Gaps between these entries indicate dropped hooks, crashed scripts, or removed enforcement.

## Maintenance Transitions

`Enter-HeliosMaintenanceMode.ps1` and `Exit-HeliosMaintenanceMode.ps1` produce bounded maintenance transition evidence. They record the transition type, prior state snapshot, allowed operation, expected final state, actual final state, authorization, and expiry. These tools record the transition — they do not broadly disable enforcement.

## Schemas

See `schemas/` for JSON Schema definitions:

| Schema | Purpose |
|---|---|
| `helios-envelope.schema.json` | Durable manifest |
| `helios-baseline.schema.json` | Session baseline |
| `helios-command-evidence.schema.json` | Before, decision, after, compare evidence |
| `helios-rebaseline.schema.json` | Rebaseline audit record |
| `akashic-self-envelope.v1.json` | Akashic self-manifest |
| `akashic-settings-integrity-evidence.v1.json` | Expected vs actual hook configuration with hashes |
| `helios-maintenance-transition-evidence.v1.json` | Bounded administrative transition evidence |
| `helios-runtime-reset-evidence.v1.json` | Reset operation evidence with authority fields |
| `helios-runtime-restore-evidence.v1.json` | Restore operation evidence with authority fields |
| `helios-runtime-uninstall-evidence.v1.json` | Uninstall operation evidence |
| `helios-install-origin.v1.json` | Install origin metadata |
| `helios-runtime-detection.v1.json` | Runtime detection result |
| `akashic-self-integrity-evidence.v1.json` | Self-integrity verification evidence |
| `helios-settings-activation-evidence.schema.json` | Settings activation evidence |
| `helios-rollback-evidence.schema.json` | Rollback operation evidence |

Authority fields (`authority_type`, `authorization_method`, `authorization_proof_present`, `authorization_proof_ref`) are present in reset, restore, rebaseline, and uninstall evidence schemas. Current authority is claim-based (`self_reported` or `tool_reported`). Cryptographic signing is deferred.

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

### Integrity and Audit Tools

| Tool | Purpose |
|---|---|
| `tools/AkashicSettingsIntegrity.ps1` | Verify settings.json hook entries, expected scripts, hook presence, settings hash |
| `tools/Test-HeliosSessionContinuity.ps1` | Forensic audit of Helios session ledger: continuity verdict, evidence gaps |
| `tools/Enter-HeliosMaintenanceMode.ps1` | Bounded maintenance transition evidence (enter) |
| `tools/Exit-HeliosMaintenanceMode.ps1` | Bounded maintenance transition evidence (exit) |
| `tools/Apply-AkashicClaudeHooks.ps1` | Apply Helios hooks to Claude settings.json |
| `tools/Remove-AkashicClaudeHooks.ps1` | Remove Helios hooks from Claude settings.json |

### Lock Tools

| Tool | Purpose |
|---|---|
| `tools/Get-AkashicLockStrategy.ps1` | Resolve OS-native lock backend (icacls/chattr/chflags/chmod) |
| `tools/lib/AkashicLockTargets.ps1` | Protected file and mutable directory inventory |
| `tools/lib/AkashicLockBackend.ps1` | Backend dispatch: privilege wrapping, lock/unlock/status, evidence format |
| `tools/Lock-AkashicProtectedFiles.ps1` | Apply OS-native locks to protected files |
| `tools/Unlock-AkashicProtectedFiles.ps1` | Remove locks for maintenance rebaseline |
| `tools/AkashicLockStatus.ps1` | Verify all lock targets are in expected state |
| `tools/Invoke-AkashicRebaseline.ps1` | Coordinated unlock→update→rebaseline→relock→verify cycle |
| `tools/Test-AkashicOsLockFixture.ps1` | Disposable fixture test for lock backend validation |

### Runtime Operations Tools

| Tool | Purpose |
|---|---|
| `tools/Move-AkashicStaleGateArtifacts.ps1` | Clean expired pending/ and orphaned inflight/ gates |
| `tools/Reset-AkashicHeliosRuntime.ps1` | Reset Helios runtime to clean state |
| `tools/Restore-HeliosRuntimeFromBundle.ps1` | Restore runtime from a validated bundle |
| `tools/Uninstall-AkashicHeliosRuntime.ps1` | Remove Helios runtime from a project |
| `tools/Rollback-AkashicHeliosRuntime.ps1` | Roll back a failed install/activation |
| `tools/Test-HeliosRuntimeOrigin.ps1` | Verify runtime origin against install-origin.json |
| `tools/New-HeliosInstallOrigin.ps1` | Generate install-origin metadata |

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

**Phase:** 4.4 — compound bypass awareness. Phase 4.1 cross-platform lock tooling is complete; Phase 4.4 adds the Helios awareness layer (capability classification, segment decomposition, uniform evidence, control-plane watcher, session continuity, chain linkage, settings integrity, maintenance transitions, PostToolUse diagnostics). Akashic provides the trust witness, installer, forensic audit, and maintenance evidence tooling.

### Capability Status

| Capability | Helios | Akashic | Status |
|---|---|---|---|
| Command gate | Owns runtime enforcement | Installs/prepares runtime | Implemented |
| SHA-256 command hash | Validates exact command | N/A | Implemented |
| Protected-file manifest hash | Uses manifest/sidecar | Generates/verifies manifests | Implemented |
| PostToolUse evidence | Writes runtime evidence | Can audit via tools | Implemented |
| Capability classification | Owns classifier | N/A | Implemented |
| Segment decomposition | Owns decomposer | N/A | Implemented |
| Control-plane watcher | Owns live watcher | Verifies settings integrity | Implemented |
| Session continuity | Writes ledger and evidence | Provides forensic audit | Implemented |
| Installer | Consumes installed runtime | Owns PlanOnly/Prepare/Activate | Implemented |
| Signatures | Reads authority fields only | Schema language exists | Not implemented |
| File locks | Runtime target | Owns lock tooling | Tooling exists; active runtime locking deferred |

### Hashes

Implemented. Helios has `manifest/helios-envelope.json` containing protected-file SHA-256 hashes and `manifest/helios-envelope.sha256` as the manifest sidecar. Akashic has `manifest/akashic-envelope.json` and `manifest/akashic-envelope.sha256`. Hashes prove byte-level drift against a known manifest. They do not prove human authorization by themselves.

### Signatures

Not implemented yet. The schemas now support authority language (`authority_type`, `authorization_method`, `authorization_proof_present`, `authorization_proof_ref`), but cryptographic signing is deferred. Current authority is claim-based (`self_reported` or `tool_reported`). The sidecar is a SHA-256 hash, not a signature.

### File Locks

Lock tooling exists in Akashic. Backends are documented for Windows (`icacls`), Linux (`chattr`), macOS (`chflags`), and POSIX (`chmod`) fallback. Fixtures have been validated across platforms. Active Helios runtime locking remains deferred unless a later activation explicitly applies locks.

### Component Status

| Component | Status |
|---|---|
| Bridge implementation (7 functions) | Complete |
| Sync, manifest, integrity tools | Complete |
| Pester test suite (18 tests) | Complete |
| Schemas (15 JSON Schema files) | Complete |
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
| Lock tooling (4.1) | Windows, Void Linux, and macOS validated — `docs/phase41-lock-implementation.md` |
| Lock strategy resolver | Complete — `Get-AkashicLockStrategy.ps1` (icacls/chattr/chflags/chmod) |
| Lock dispatch layer | Complete — `lib/AkashicLockTargets.ps1` + `lib/AkashicLockBackend.ps1` (inventory + backend dispatch) |
| Lock/unlock tools | Windows fixture PASS. Void Linux fixture PASS. macOS fixture PASS |
| Lock fixture test | Windows PASS, Void Linux PASS, macOS PASS — `Test-AkashicOsLockFixture.ps1` |
| Installer contract | Defined — `docs/akashic-helios-installer-contract.md` |
| Unified installer | Created — `tools/AkashicHeliosInstallPlan.ps1` (16-phase, PlanOnly/Prepare/Activate) |
| Rebaseline workflow | Implemented — live 7-step cycle pending |
| Stale gate cleanup | Implemented — `tools/Move-AkashicStaleGateArtifacts.ps1` |
| Settings integrity | Implemented — `AkashicSettingsIntegrity.ps1` verifies hook entries and settings hash |
| Session continuity audit | Implemented — `Test-HeliosSessionContinuity.ps1` forensic audit tool |
| Maintenance transition evidence | Implemented — `Enter-HeliosMaintenanceMode.ps1` / `Exit-HeliosMaintenanceMode.ps1` |
| Authority schema fields | Implemented — `authority_type`, `authorization_method` in reset/restore/rebaseline schemas |
| Self-manifest/self-integrity | Implemented — `New-AkashicSelfManifest.ps1`, `Test-AkashicSelfIntegrity.ps1` |
| Rebaseline schema | Validated — fixture record matches `schemas/helios-rebaseline.schema.json` |
| Phase 4.1 evidence | Complete — `evidence/phase41/` (fixture + installer validation across Windows, Void Linux, macOS; live runtime deferred) |
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
| Phase 4.1 | Complete (cross-platform lock strategy — Windows PASS, Void Linux PASS, macOS PASS; active runtime locking deferred) |
| Phase 4.4 | Complete (compound bypass awareness — capability classification, segment decomposition, uniform evidence, control-plane watcher, session continuity, chain linkage, settings integrity, maintenance transitions, PostToolUse diagnostics) |
| Phase 4.2 | Future — live lock verification evidence |
| Phase 5 | Future — lock system packaging |
| Phase 6 | Future — long-term lock verification + audit strategy |
