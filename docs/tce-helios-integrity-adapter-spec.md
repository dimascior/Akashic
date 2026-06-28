# TCE Helios Integrity Adapter — Specification

## Purpose

This document defines the TCE-owned adapter model for Helios command-gate integrity verification. It translates the Helios runtime architecture into TCE-owned concepts, schemas, and evidence rules so that TCE is the adapter-side authority — not merely a vendor-copy supplier.

## Ownership Boundaries

### TCE Adapter Ownership (this branch)

TCE owns:
- Bridge source-of-truth implementation (`HeliosIntegrityBridge.ps1`)
- Local snapshot orchestration
- Evidence parser/normalizer
- Controlled gap-test matrix
- TCE-local evidence artifacts
- Phase 4 lock-requirement derivation
- Adapter schemas and tools

### TCE Main Preservation

Main remains the clean public-facing MyExporter module. Main does not include `Adapters/Helios/` in FileList or FunctionsToExport. No adapter work merges to main until a deliberate release decision is made.

### Helios Runtime Boundary

Helios owns:
- Runtime hook execution (PreToolUse, PostToolUse, PostToolUseFailure)
- Protected-envelope production and enforcement
- Mutable runtime lifecycle (pending → inflight → evidence/blocked)
- Per-command evidence production
- Vendored bridge consumption (byte-identical copy)
- Gate validation logic

TCE reads Helios evidence. TCE does not modify Helios runtime files except during controlled gap tests with documented restoration plans.

### Bridge Source-of-Truth Boundary

TCE source: `Adapters/Helios/HeliosIntegrityBridge.ps1`
Helios vendor copy: `.command-gate/hooks/lib/HeliosIntegrityBridge.ps1`
Sync tool: `tools/Sync-HeliosBridge.ps1` (deterministic copy with SHA-256 verification)

The vendored copy's hash is recorded in the Helios manifest (`helios-envelope.json`). Any bridge update requires: TCE source change → sync → rebaseline → verify.

### Phase 4 Lock-Requirement Derivation Boundary

TCE derives Phase 4 requirements from controlled gap-test evidence. The Helios `docs/phase4-lock-handoff.md` is a strong design draft. The final Phase 4 specification must be grounded in TCE-classified evidence, not assumptions.

### Phase 5 and Phase 6 Out-of-Scope Boundary

Phase 5 (helios-lock filesystem prevention package) and Phase 6 (lock verification evidence) are future implementation phases. This document covers only the adapter model needed to derive Phase 4 requirements.

## Envelope Concepts

### Protected Runtime Envelope

Files loaded by the active hook path that must not change during gated execution:

| Path | Role | Manifest Key |
|---|---|---|
| `hooks/helios_pretooluse.ps1` | Front controller | hashed |
| `hooks/gate_check.ps1` | Gate validation | hashed |
| `hooks/evidence_capture.ps1` | Evidence capture | hashed |
| `hooks/tier_classifier.ps1` | Tier classification | hashed |
| `hooks/lib/HeliosIntegrityBridge.ps1` | Vendored bridge | hashed |
| `policy/command-policy.json` | Gate policy | hashed |
| `manifest/helios-envelope.json` | Manifest | listed, not self-hashed |
| `manifest/helios-envelope.sha256` | Sidecar | listed, not self-hashed |

### Mutable Runtime Envelope

Directories that must change as part of the gate lifecycle:

| Directory | Role | Lock Status |
|---|---|---|
| `pending/` | Gates awaiting execution | Must remain writable |
| `inflight/` | Gates currently executing | Must remain writable |
| `evidence/` | Completed records and integrity evidence | Must remain writable |
| `blocked/` | Denied command records | Must remain writable |

### External Control-Plane

`settings.json` (at `C:\Users\dimas\.claude\settings.json`) controls which hooks fire. Removing the PreToolUse entry silently disables the entire gate system. This file is outside `.command-gate/` and is not covered by the manifest. It is the highest-severity bypass vector.

### Conditional Protected File

`templates/operating-catalog.json` — loaded by `tier_classifier.ps1` if present. Currently does not exist. When created, must be added to manifest hashes and rebaselined. Until then, creating this file is an undetected bypass for tier classification.

## Snapshot Phases

TCE orchestrates evidence production through snapshot phases:

1. **Pre-state capture** — `Get-HeliosEnvelopeSnapshot` before any mutation or trigger
2. **Mutation or trigger** — controlled change or shell command execution
3. **Post-state capture** — `Get-HeliosEnvelopeSnapshot` after the action
4. **Comparison** — `Compare-HeliosProtectedEnvelope` and `Compare-HeliosRuntimeTransition`
5. **Evidence normalization** — `ConvertFrom-HeliosEvidence` ingests Helios artifacts
6. **Classification** — TCE assigns failure class and lock-requirement hint

## Evidence Model

### Before / Decision / After / Compare

Helios produces four evidence types per gated command:

| Type | Written By | When | Content |
|---|---|---|---|
| `before` | helios_pretooluse.ps1 | Before command | Protected hashes + mutable state |
| `decision` | helios_pretooluse.ps1 | Before command | ALLOW / DENY / INTEGRITY_FAILURE |
| `after` | evidence_capture.ps1 | After command | Protected hashes + mutable state |
| `compare` | evidence_capture.ps1 | After command | Protected verdict + runtime verdict |

Denied commands produce `before` and `decision` only. Allowed commands produce all four.

### TCE Normalized Evidence Object

TCE ingests Helios evidence into a coherent local model:

| Field | Source | Description |
|---|---|---|
| `session_id` | Helios session | Claude Code session UUID |
| `tool_use_id` | Helios payload | Per-command identifier |
| `correlation_id` | Gate file | Gate correlation identifier |
| `gate_id` | Gate filename | Filename of the matched gate |
| `command_sha256` | Gate/payload | SHA-256 of the command text |
| `cwd` | Payload | Working directory at execution |
| `shell` | Payload | bash or powershell |
| `verdict` | Decision evidence | ALLOW / DENY / INTEGRITY_FAILURE |
| `protected_verdict` | Compare evidence | CLEAN / DRIFT |
| `runtime_verdict` | Compare evidence | EXPECTED / UNEXPECTED |
| `gate_lifecycle_state` | Mutable snapshot | pending → inflight → evidence |
| `stdout_path` | Side file | Path to captured stdout |
| `stderr_path` | Side file | Path to captured stderr |
| `result_path` | Evidence file | Path to result.json |
| `blocked_record_path` | blocked/ | Path to blocked record if denied |
| `maintenance_record_path` | maintenance/ | Path to maintenance record if applicable |
| `failure_class` | TCE classification | Failure taxonomy entry |
| `lock_requirement_hint` | TCE derivation | Phase 4 lock mapping |

## Failure Taxonomy

TCE classifies each observed failure or gap into a taxonomy that maps to Phase 4 requirements:

| Class | Description | Phase 4 Mapping |
|---|---|---|
| `protected_drift` | Protected file hash differs from manifest | Lock the drifted file |
| `missing_protected_file` | Protected file absent | Lock delete/rename on the file |
| `cwd_mismatch` | Gate working_directory does not match actual cwd | Gate identity enforcement (not filesystem lock) |
| `stale_gate` | Gate expires_utc has passed | Cleanup and TTL enforcement (not protected lock) |
| `write_indicator_missing_impact` | Write indicator detected, read_write_impact absent | Schema enforcement + policy protection |
| `undeclared_chain` | Chained command with multi_command false | Command identity enforcement |
| `mutable_evidence_tamper` | Evidence file modified after creation | Evidence audit/signing/append-only (not protected lock) |
| `failed_missing_tool_response` | PostToolUseFailure with missing tool_response | Post-hook robustness |
| `wrapper_validation_failure` | Wrapper-required gate fields mismatch | Wrapper identity enforcement |
| `external_control_plane_risk` | settings.json modified or at risk | settings.json lock requirement |
| `template_drift` | Template file modified when manifest-protected | Template lock |
| `template_unprotected_gap` | Template file modified when NOT manifest-protected | Monitored-template classification |

## Drift Taxonomy

Drift is distinguished by source:

| Source | Meaning | Severity |
|---|---|---|
| `MANIFEST` | File hash differs from durable manifest | High — install-time trust broken |
| `BASELINE` | File hash differs from session baseline | Medium — session-time drift |
| `MISSING` | File does not exist | High — deletion attack |
| `MANIFEST+BASELINE` | Both comparisons fail | High — persistent tampering |

## Orphan Evidence

Orphan evidence (PostToolUse without matching PreToolUse gate) means:
- The command executed WITHOUT PreToolUse authorization
- Root cause is typically PreToolUse hook crash (exit code ≠ 0 → Claude Code proceeds)
- Orphan correlation IDs use pattern `orphan-TIMESTAMP-HASH12`
- **Diagnostic evidence, not authorization proof**

## Maintenance Rebaseline

When the front controller detects drift and finds a valid `maintenance/rebaseline-request.json`:
1. Validates request: schema_version, write_mode, expiry, base_manifest_hash, exact drift paths
2. Recomputes all protected hashes
3. Writes BOM-free manifest + sidecar
4. Writes evidence to `evidence/maintenance/`
5. Invalidates session baseline
6. Denies with `MAINTENANCE_REBASELINE_COMPLETE`
7. Next command runs against updated manifest

Maintenance is a controlled self-repair mechanism, not a bypass. The request must match the exact drift state.

## TCE Evidence Ownership

TCE evidence lives at `Adapters/Helios/evidence/gap-tests/` on the adapter branch. It is separate from Helios runtime evidence and references Helios artifacts rather than replacing them.

Per gap-test evidence set:
- `pre.json` — TCE pre-state snapshot
- `post.json` — TCE post-state snapshot
- `compare.json` — TCE comparison result
- `normalized-evidence.json` — ingested Helios evidence
- `lock-requirement.json` — Phase 4 derivation
- `restoration.json` — restoration steps and verification (live tests only)
- `test-plan.json` — documented plan (fixture/Mode B tests only)

### lock-requirement.json Schema

| Field | Description |
|---|---|
| `classification` | Failure taxonomy class |
| `affected_envelope` | protected / mutable / external |
| `lock_target_candidate` | File or directory path |
| `prevention_need` | What Phase 4 must prevent |
| `detection_status` | Whether Helios currently detects this |
| `evidence_confidence` | high / medium / low |
| `phase4_recommendation` | Lock type and platform strategy |
| `platform_notes` | Windows icacls / Linux chattr / macOS chflags / POSIX chmod |
