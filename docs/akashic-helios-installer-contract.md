# Akashic-Helios Installer Contract

## Purpose

This document defines the contract between Akashic (the integrity adapter) and Helios (the runtime gate system) for installation, verification, and platform activation. It is the prerequisite for claiming cross-platform support.

Having a lock backend in code does not constitute platform support. Platform support requires all three layers to work together:

1. **Akashic package install** — the installer knows where Akashic is installed, what tools are included, and can verify package integrity.
2. **Helios runtime install** — the installer knows where the target `.command-gate` lives, how to copy or verify hooks, policy, schemas, manifest, and the vendored bridge.
3. **Platform activation** — the installer verifies prerequisites (pwsh, lock backend, settings paths, file permissions), runs the disposable fixture, generates the manifest, and only then allows a plan for active runtime lock activation.

## Current Verified State

### Phase 4.1 — Akashic Cross-Platform Framework Validation: PASS

| Component | Status |
|---|---|
| Windows lock fixture | PASS |
| Windows installer PlanOnly/Prepare | PASS |
| Void Linux lock fixture | PASS |
| Void Linux installer PlanOnly/Prepare | PASS |
| macOS lock fixture | PASS |
| macOS installer PlanOnly/Prepare | PASS |
| Akashic installer | Validated (PlanOnly + Prepare on all three platforms) |
| Helios runtime install contract | Defined here |
| Raw validation logs | All three platforms |

Phase 4.1 proves that Akashic can safely prepare a Helios runtime on Windows, Void Linux, and macOS. It does not prove Helios is actively running.

### Phase 4.2 — Helios Live Operational Verification: PENDING

| Platform | Live Status |
|---|---|
| Windows | PASS (steps 1–9) — MythosJustAFable `.command-gate` active. Interception, gate approval, success/failure evidence capture, manifest integrity all verified. Locking deferred (step 10). |
| Void Linux | Ready for live install/activation. Not yet operational. |
| macOS | Ready for live install/activation. Not yet operational. |

Active runtime locking deferred until live operational proof passes per platform.

## Akashic Source Package Layout

The Akashic adapter package is a directory containing:

| Path | Role | Required |
|---|---|---|
| `AkashicIntegrityBridge.ps1` | Source-of-truth bridge implementation | Yes |
| `tools/` | Adapter tools (sync, manifest, lock, install, etc.) | Yes |
| `tools/lib/` | Shared lock backend dispatch and inventory | Yes |
| `schemas/` | JSON Schema definitions | Yes |
| `docs/` | Documentation | No |
| `Tests/` | Pester test suite | No |
| `evidence/` | Gap-test and validation evidence | No |
| `package-manifest.json` | Package metadata (version, checksums) | For release artifacts |
| `checksums.sha256` | Per-file checksums | For release artifacts |

### Required Tools

The installer verifies these tools exist in the Akashic root:

| Tool | Purpose |
|---|---|
| `tools/Get-AkashicLockStrategy.ps1` | OS lock backend detection |
| `tools/lib/AkashicLockTargets.ps1` | Protected file and mutable dir inventory |
| `tools/lib/AkashicLockBackend.ps1` | Backend dispatch (lock/unlock/status/evidence) |
| `tools/Lock-AkashicProtectedFiles.ps1` | Apply OS-native locks |
| `tools/Unlock-AkashicProtectedFiles.ps1` | Remove locks for maintenance |
| `tools/AkashicLockStatus.ps1` | Verify lock state |
| `tools/Test-AkashicOsLockFixture.ps1` | Disposable fixture validation |
| `tools/Invoke-AkashicRebaseline.ps1` | Unlock-update-relock cycle |
| `tools/Sync-AkashicBridge.ps1` | Bridge sync to vendor location |
| `tools/AkashicEnvelopeManifest.ps1` | Manifest rebaseline |
| `tools/AkashicEnvelopeIntegrityValidation.ps1` | Envelope integrity check |
| `tools/AkashicSettingsIntegrity.ps1` | Settings hook entry verification |

## Helios Runtime Target Layout

The Helios runtime lives in a `.command-gate/` directory at the target repo root.

### Protected Runtime Files

These files must not change during gated execution. Lock targets.

| Relative Path | Role |
|---|---|
| `hooks/helios_pretooluse.ps1` | Front controller |
| `hooks/gate_check.ps1` | Command validation |
| `hooks/evidence_capture.ps1` | Post-tool evidence |
| `hooks/tier_classifier.ps1` | Tier classification |
| `hooks/lib/HeliosIntegrityBridge.ps1` | Vendored bridge |
| `policy/command-policy.json` | Gate policy |
| `manifest/helios-envelope.json` | Durable manifest |
| `manifest/helios-envelope.sha256` | Sidecar hash |

### Mutable Lifecycle Directories

These directories must remain writable during gated execution.

| Directory | Role |
|---|---|
| `pending/` | Gates awaiting execution |
| `inflight/` | Gates currently executing |
| `evidence/` | Completed gate records |
| `blocked/` | Denied command records |

### Required Runtime Directories

Created during Prepare mode if absent:

```
hooks/, hooks/lib/, policy/, templates/, schemas/,
manifest/, pending/, inflight/, evidence/, blocked/,
maintenance/, evidence/integrity/, evidence/integrity/sessions/,
evidence/stale/, evidence/maintenance/
```

### Optional Trust Boundaries

| Target | Condition |
|---|---|
| `settings.json` | Locked with `-IncludeSettingsLock` |
| `templates/` | Locked with `-IncludeTemplatesLock` |

## Platform Prerequisites

### Windows

| Prerequisite | Check |
|---|---|
| PowerShell 5.1+ | `$PSVersionTable.PSEdition -eq 'Desktop'` or `$PSVersionTable.PSVersion.Major -ge 5` |
| icacls | `Get-Command icacls` |
| NTFS filesystem | `Get-Volume` on target drive |
| Claude settings path | `$env:USERPROFILE\.claude\settings.json` |
| Helios .command-gate path | User-supplied |

### Void Linux

| Prerequisite | Check |
|---|---|
| pwsh (PowerShell 7+) | `Get-Command pwsh` or running under pwsh |
| chattr | `Get-Command chattr` or path scan `/usr/bin/chattr`, `/sbin/chattr` |
| lsattr | `Get-Command lsattr` or path scan |
| Filesystem supports immutable | Fixture test on target filesystem |
| Privilege path resolved | One of: root, `sudo -n`, `doas` |
| No password prompt | `sudo -n true` or `doas true` with stdin closed |
| No stored credentials assumed | Strategy detection is non-interactive only |
| Claude settings path | `$env:HOME/.claude/settings.json` |

### macOS

| Prerequisite | Check |
|---|---|
| pwsh (PowerShell 7+) | `Get-Command pwsh` or running under pwsh |
| chflags | `Get-Command chflags` |
| ls -lO | `Get-Command ls` |
| User-owned fixture path | Temp dir write test |
| Claude settings path | `$env:HOME/.claude/settings.json` |

## Install Modes

### PlanOnly (default)

Generates the install plan JSON. No file changes. No runtime modifications. The plan describes what would happen in Prepare and Activate modes.

Output: `install-plan.json` at the Akashic root.

### Prepare

Creates required directories. Copies protected runtime files from Akashic to Helios target. Syncs the bridge. Generates or verifies the manifest. Runs the lock fixture if requested. Writes install evidence.

Does NOT:
- Activate settings hooks
- Apply runtime locks
- Modify settings.json

### Activate

**Planner behavior:** `AkashicHeliosInstallPlan.ps1` in Activate mode produces an activation approval plan. It runs all Prepare steps, then generates `APPROVAL_REQUIRED` plans for settings and lock activation. It does NOT modify `settings.json` or apply runtime locks.

**Activation tools (implemented):**

| Tool | Purpose |
|---|---|
| `tools/Apply-AkashicClaudeHooks.ps1` | Merge Helios hooks into Claude settings. Backs up, preserves non-Helios keys, idempotent. |
| `tools/Remove-AkashicClaudeHooks.ps1` | Remove Helios hooks from settings. Selective removal or full backup restore. |
| `tools/Test-HeliosLiveOperational.ps1` | Automated static verification of a live runtime (hooks, manifest, hashes, structure). |
| `tools/Install-AkashicHeliosRuntime.ps1` | Unified entrypoint: Prepare → optional `-ActivateClaudeHooks` → optional `-Verify` → optional `-LockRuntime`. |

**Unified install entrypoint:**

```
.\tools\Install-AkashicHeliosRuntime.ps1 `
  -AkashicRoot <path> `
  -RuntimeBundleRoot <path-to-Helios-.command-gate> `
  -HeliosGateRoot <live-target-path> `
  -ActivateClaudeHooks `
  -Verify
```

On Unix-like systems:

```
pwsh -NoProfile -File ./tools/Install-AkashicHeliosRuntime.ps1 \
  -AkashicRoot "$HOME/Engineering/Akashic" \
  -RuntimeBundleRoot "$HOME/Engineering/Helios-/.command-gate" \
  -HeliosGateRoot "$HOME/.helios/.command-gate" \
  -ActivateClaudeHooks \
  -Verify
```

## RuntimeBundleRoot

`RuntimeBundleRoot` is a **Helios runtime bundle source**, not an Akashic adapter path. It must point to a directory containing the complete set of protected runtime files that the installer will copy to `HeliosGateRoot`. The canonical source is the Helios repo's `.command-gate` directory or an export of an active Helios runtime.

The installer **copies** hook and policy files from RuntimeBundleRoot but does not **generate** them. It also generates `manifest/helios-envelope.json`, `manifest/helios-envelope.sha256`, and syncs `hooks/lib/HeliosIntegrityBridge.ps1` from Akashic — but the front controller and policy files must already exist in the bundle.

Missing protected runtime files in RuntimeBundleRoot cause Phase 2 to FAIL with a blocker. Prepare and Activate will not proceed with a partial protected file set.

## Install Plan Phases

Manifest generation happens AFTER all protected files and the vendored bridge are in final position.

| Phase | Action | Mode | Blocking |
|---|---|---|---|
| 1 | Verify Akashic package/root + tool availability | All | Yes |
| 2 | Verify RuntimeBundleRoot (missing protected files = FAIL) | All | Yes |
| 3 | Create runtime directories | PlanOnly: check; Prepare/Activate: create | Yes |
| 4 | Copy runtime protected files from RuntimeBundleRoot | PlanOnly: plan; Prepare/Activate: copy | Yes |
| 5 | Copy runtime support files from RuntimeBundleRoot | PlanOnly: plan; Prepare/Activate: copy | No |
| 6 | Sync Akashic bridge | PlanOnly: plan; Prepare/Activate: sync | Yes |
| 7 | Verify bridge byte identity | Prepare/Activate | Yes |
| 8 | Generate manifest (after all files in final position) | Prepare/Activate | Yes |
| 9 | Verify envelope integrity | Prepare/Activate | Yes |
| 10 | Detect lock strategy + run fixture (if requested) | All (fixture: Prepare/Activate) | Yes |
| 11 | Prepare settings activation plan (if requested) | All | No |
| 12 | Prepare lock activation plan | All | No |
| 13 | Prepare rollback plan | All | No |
| 14 | Write install evidence | Prepare/Activate | No |

## Rollback Behavior

The installer generates a rollback plan that covers:

1. Restore `settings.json` from backup (disables hooks immediately).
2. Remove deny ACLs from any locked files (`Unlock-AkashicProtectedFiles`).
3. Verify no hooks active (run a shell command, confirm no gate prompt).
4. Optionally remove `.command-gate/` directory.

Rollback evidence is written with timestamp and operator identity.

## Evidence Behavior

The installer writes evidence to `$EvidenceOutputDir` (default: `evidence/phase41/` relative to Akashic root).

Install evidence records:

| Field | Content |
|---|---|
| `schema_version` | `akashic-install-evidence.v1` |
| `timestamp_utc` | ISO 8601 |
| `mode` | PlanOnly, Prepare, or Activate |
| `platform` | Windows, Linux, macOS |
| `akashic_root` | Akashic package path |
| `helios_gate_root` | Helios target path |
| `lock_strategy` | Detected backend, strength, privilege mode |
| `fixture_result` | PASS, FAIL, BLOCKED, or NOT_RUN |
| `manifest_status` | CLEAN, DRIFT, or NOT_GENERATED |
| `settings_activation` | activated, skipped, or plan_only |
| `lock_activation` | activated, skipped, or plan_only |
| `blockers` | Any blocking issues |

## OS Lock Fixture Prerequisite

Active runtime locking is not permitted until the disposable fixture passes on the target machine.

The fixture (`Test-AkashicOsLockFixture.ps1`) creates a temporary directory with the same 8 protected files and 4 mutable directories as the live runtime. It runs a 7-phase lifecycle test: lock, verify locked, negative tests (write/delete/rename blocked), mutable dirs writable, unlock, verify unlocked, post-unlock writable.

The fixture must PASS before:
- `Lock-AkashicProtectedFiles.ps1` is called on live runtime files
- The installer enters Activate mode for lock activation
- Any claim of platform support for that OS

## Active Runtime Lock Approval Boundary

Active Helios runtime locking requires:

1. Disposable fixture PASS on the target machine.
2. Manifest generated and CLEAN on the target machine.
3. Explicit human approval (never automated).
4. Lock activation recorded in install evidence.

The installer never applies locks to active runtime files in PlanOnly or Prepare modes. Lock activation only occurs in Activate mode with explicit `-IncludeSettingsActivation` or as a separate step after Prepare completes.

## Claiming Platform Support

Platform support has two milestones:

### Milestone 1: Akashic Framework Validation (Phase 4.1)

Proves the lock backend, installer, and Prepare workflow function correctly on disposable fixtures.

1. Lock fixture PASS on that OS (evidence in `evidence/phase41/os-lock-validation/<platform>.json`, schema `akashic-os-lock-evidence.v1`).
2. Installer PlanOnly generates a valid plan for that OS (no blockers, schema `akashic-helios-install-plan.v2`).
3. Installer Prepare completes on that OS (bridge synced, manifest CLEAN, evidence schema `akashic-install-evidence.v1`).

### Milestone 2: Helios Live Operational Verification (Phase 4.2)

Proves Helios is actively installed, hooked into Claude settings, enforcing gates, and capturing evidence as a live system.

1. Install or select the live `.command-gate` path.
2. Run Akashic Prepare against that target (or confirm prepared target already exists).
3. Generate a CLEAN manifest and sidecar in the live target.
4. Activate Claude settings: `PreToolUse` → `hooks/helios_pretooluse.ps1`, `PostToolUse`/`PostToolUseFailure` → `hooks/evidence_capture.ps1`.
5. Run a harmless command and prove it is intercepted by Helios.
6. Create a valid pending gate and prove the same command is allowed.
7. Prove evidence is captured after success (`PostToolUse`).
8. Run a controlled failure and prove `PostToolUseFailure` evidence is captured.
9. Test integrity behavior: manifest exists, protected hashes checked, drift denied or handled through maintenance corridor.
10. Apply live runtime locks with explicit approval (only after steps 1–9 pass).

Active runtime locking is not permitted until live operational verification passes. It requires fixture PASS + Prepare + live operational proof + explicit Activate approval.

## Status Summary

### Phase 4.1 — Akashic Framework Validation

| Platform | Fixture | Installer Plan | Prepare | Canonical Evidence |
|---|---|---|---|---|
| Windows | PASS | PASS | PASS | `os-lock-validation/windows.json` (tool) + `windows-validation-raw-results.md` (raw log) |
| Void Linux | PASS | PASS | PASS | `os-lock-validation/void-linux.json` (tool) + `void-linux-validation-raw-results.md` (raw log) |
| macOS | PASS | PASS | PASS | `os-lock-validation/macos.json` (tool) + `macos-validation-raw-results.md` (raw log) |

Evidence classification: see `evidence/phase41/EVIDENCE-INDEX.md`.

### Phase 4.2 — Helios Live Operational Verification

| Platform | Live Helios | Evidence |
|---|---|---|
| Windows | PASS (steps 1–9). Active MythosJustAFable runtime. Locking deferred. | `evidence/phase42/windows-helios-live-operational-raw-results.md` |
| Void Linux | Ready for live install/activation. Not yet operational. | `evidence/phase42/` (pending) |
| macOS | Ready for live install/activation. Not yet operational. | `evidence/phase42/` (pending) |

Remaining evidence artifacts:
- `evidence/phase42/void-linux-helios-live-operational-raw-results.md`
- `evidence/phase42/macos-helios-live-operational-raw-results.md`
