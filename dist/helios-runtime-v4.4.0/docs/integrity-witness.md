# Helios Integrity Witness

## Architecture

Three layers, each with a distinct role:

| Layer | Role | Status |
|---|---|---|
| **TCE** (TerminalContextExporter) | Source-of-truth owner of the integrity bridge adapter. Maintains the canonical implementation at `Adapters/Helios/HeliosIntegrityBridge.ps1` in its own repo. | Source-of-truth owner |
| **Helios** (command gate) | Runtime command enforcement. Gates Bash/PowerShell tool uses via PreToolUse/PostToolUse hooks. Vendors a byte-identical copy of the TCE bridge for integrity verification. | Active runtime |
| **helios-lock** | Filesystem prevention. OS-native locks (icacls/chattr/chflags/chmod) that prevent modification of protected files between integrity checks. | Phase 4+ (not yet implemented) |

Helios owns the command-gate runtime. TCE owns the source-of-truth bridge implementation at `TerminalContextExporter/MyExporter/Adapters/Helios/HeliosIntegrityBridge.ps1`. Helios vendors a byte-identical copy at `hooks/lib/HeliosIntegrityBridge.ps1` inside its protected envelope. The vendored copy's hash is recorded in the Helios manifest. helios-lock will close the gap between detection and prevention.

## Current Detection Model

The integrity witness provides **detection-on-next-shell-action**, not prevention:

1. A model (or external actor) modifies a protected file.
2. The modification is not blocked at mutation time.
3. On the next Bash or PowerShell tool use, `helios_pretooluse.ps1` hashes all protected files.
4. Hash mismatch against the durable manifest triggers INTEGRITY_FAILURE and deny.
5. The command that would have executed against tampered policy is never run.

Direct file-edit tools (Edit, Write, NotebookEdit) do not trigger shell hooks. A protected file can be modified by these tools, and the modification is only detected when the next shell command fires. Phase 4 helios-lock addresses this gap with filesystem-level prevention.

## Envelope Model

### Runtime Protected Envelope

Files loaded by the active hook path. Must not change during gated execution:

| Relative Path | Loaded By | Role |
|---|---|---|
| `hooks/helios_pretooluse.ps1` | settings.json PreToolUse | Front controller entry point |
| `hooks/gate_check.ps1` | helios_pretooluse.ps1 (dot-sourced) | Gate validation logic |
| `hooks/evidence_capture.ps1` | settings.json PostToolUse/Failure | Post-command evidence capture |
| `hooks/tier_classifier.ps1` | helios_pretooluse.ps1 (dot-sourced) | Tier classification |
| `hooks/lib/HeliosIntegrityBridge.ps1` | helios_pretooluse.ps1, evidence_capture.ps1 (dot-sourced) | Vendored TCE witness bridge |
| `policy/command-policy.json` | tier_classifier.ps1, gate_check.ps1 | Tier patterns and gate policy |
| `templates/operating-catalog.json` | tier_classifier.ps1 (if present) | Tier override catalog |

### Durable Trust Anchors

| File | Role |
|---|---|
| `manifest/helios-envelope.json` | SHA256 hash registry for all protected files |
| `manifest/helios-envelope.sha256` | SHA256 of the manifest JSON (sidecar avoids self-hash) |

The manifest is the root of trust. It is valid only if created by a human-approved rebaseline step and has not drifted since. The sidecar is verified before the manifest is parsed.

### External Control-Plane File

`C:\Users\dimas\.claude\settings.json` controls which hooks fire. Removing or modifying the PreToolUse entry disables the entire gate system. This file is outside the `.command-gate/` tree and is not currently covered by the manifest. Phase 4 helios-lock should protect it.

### Mutable Runtime Envelope

Directories that must change as part of the gate lifecycle:

- `pending/` — gates awaiting execution
- `inflight/` — gates currently executing
- `evidence/` — completed gate records and integrity evidence
- `blocked/` — denied command records

### Repo-Controlled Support Assets

Files not loaded by the active hook path. Development and maintenance aids:

- `docs/` — architecture documentation
- `schemas/` — JSON Schema definitions for validation
- `tools/` — offline rebaseline, verification, cleanup tools
- `tests/` — Pester test suite

These are not part of the runtime protected envelope. Do not add them to `helios-envelope.json` unless a file is loaded by the active hook path.

## Session Baseline

`evidence/integrity/sessions/<session_id>/baseline.json` — snapshot of protected hashes at session start.

The session baseline is **evidence, not policy**:
- Created only after verifying the current envelope matches the durable manifest.
- Provides session continuity evidence ("the session started clean").
- Does not replace or override the durable manifest as root of trust.
- Drift against the baseline means something changed since the session started, even if the manifest hasn't been rebaselined.

## Dual Comparison

Every PreToolUse check compares current state against **both**:
1. **Durable manifest** — "Does the envelope match the known-good install state?"
2. **Session baseline** — "Has anything changed since this session started clean?"

If either comparison fails, Helios denies. Protected drift comparison (`Compare-HeliosProtectedEnvelope`) is separate from mutable runtime transition comparison (`Compare-HeliosRuntimeTransition`).

## Front Controller

`helios_pretooluse.ps1` is the configured PreToolUse entry point. Integrity verification happens **before** any policy code is loaded:

1. Read payload from stdin
2. Pass through non-Bash/PowerShell tools
3. Locate manifest and sidecar (fixed relative path)
4. Verify sidecar hash matches computed hash of manifest
5. Parse manifest, hash all protected files
6. Compare against manifest hashes — if drift: deny (policy code never loads)
7. Dot-source `hooks/lib/HeliosIntegrityBridge.ps1` (now verified)
8. Check/create session baseline
9. Compare against both manifest and baseline
10. Write before snapshot
11. Dot-source `tier_classifier.ps1` and `gate_check.ps1` (both now verified)
12. Re-define DenyFatal after dot-source (gate_check.ps1 override protection)
13. Run gate validation
14. Write decision evidence
15. Exit with allow or deny

The critical ordering: integrity verification at steps 4-6 happens before `tier_classifier.ps1` is loaded (step 11) and before `command-policy.json` is parsed. If those files are tampered, the tampered code never runs.

## Per-Command Evidence

```
evidence/integrity/sessions/<session_id>/
  baseline.json
  commands/
    <tool_use_id>.before.json    — pre-command protected snapshot
    <tool_use_id>.decision.json  — allow/deny/integrity_failure verdict
    <tool_use_id>.after.json     — post-command snapshot (if executed)
    <tool_use_id>.compare.json   — protected + runtime comparison (if executed)
```

Denied commands get `before.json` and `decision.json`. Allowed commands get all four files.

## Bridge API

Seven functions vendored from TCE source-of-truth. Self-contained, no module imports. PowerShell 5.1+ compatible.

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

`Compare-HeliosRuntimeTransition` takes an `ExpectedMutationProfile`:

- `ALLOW_PRETOOL` — pending loses gate, inflight gains gate
- `ALLOW_POSTTOOL` — inflight loses gate, evidence gains result
- `DENY_PRETOOL` — all dirs stable, blocked gains record
- `INTEGRITY_FAILURE` — all dirs stable

## DenyFatal Invariant

`DenyFatal` must produce deny JSON on stdout and exit 0. Claude Code treats non-zero exit codes as "hook error, proceed normally" — a non-zero exit silently allows the command. The front controller re-defines DenyFatal after dot-sourcing `gate_check.ps1` to prevent override.

## Stdout Purity Rule

Hook stdout must contain only the final hook JSON response. All helper return values must be piped to `Out-Null` or captured in variables.

## Maintenance Rebaseline Corridor

When the front controller detects protected drift, it checks for a maintenance request at `maintenance/rebaseline-request.json`. This solves the bootstrap problem: the gate blocks all commands during drift, including the rebaseline tool.

### Flow

1. Front controller detects drift in protected files.
2. Reads `maintenance/rebaseline-request.json` (if present).
3. Validates: `schema_version`, `write_mode`, expiry, `base_manifest_hash` vs sidecar, drift paths exact match.
4. If valid: recomputes all protected file hashes, writes BOM-free manifest+sidecar, writes evidence to `evidence/maintenance/`, moves the request to evidence, invalidates the session baseline.
5. Denies with `MAINTENANCE_REBASELINE_COMPLETE` — the triggering command is never executed.
6. Next command runs against the updated manifest and passes integrity checks.

If the request is invalid or absent, standard `INTEGRITY_FAILURE` denial occurs.

### Request Schema

See `schemas/helios-maintenance-rebaseline.v1.schema.json`. Required fields:
- `schema_version`: `"helios-maintenance-rebaseline.v1"`
- `write_mode`: `"front_controller_internal_rebaseline"`
- `base_manifest_hash`: must match current sidecar hash
- `expected_drift_paths`: must exactly match actual drift
- `expires_utc`: must be in the future
- `requested_by`: who authorized the rebaseline

### Evidence

Maintenance evidence is written to `evidence/maintenance/`:
- `<timestamp>-<request_id>.json` — rebaseline result with old/new hashes
- `<timestamp>-<request_id>.request.json` — the consumed request
- `<timestamp>-<request_id>.stale-baseline.json` — invalidated session baseline (if one existed)

## BOM Safety

PowerShell 5.1's `Set-Content -Encoding UTF8` writes UTF-8 WITH BOM (bytes 0xEF, 0xBB, 0xBF). `ConvertFrom-Json` cannot parse JSON with a leading BOM character. All manifest and sidecar writes use:

```powershell
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, $content, $Utf8NoBom)
```

Manifest reading uses `Get-Content -Raw` which strips BOM automatically. `[System.Text.Encoding]::UTF8.GetString()` preserves BOM and must NOT be used for JSON parsing.

## Orphan Evidence

PostToolUse evidence without a matching PreToolUse gate (orphan evidence) means:
- The command executed WITHOUT PreToolUse authorization.
- PostToolUse ran after execution and found no matching inflight gate.
- Orphan correlation IDs use the pattern `orphan-TIMESTAMP-HASH12`.
- This is DIAGNOSTIC evidence, not authorization proof. Orphans indicate the gate was bypassed, not that the command was approved.

### Root Cause of Orphans

The most common cause is PreToolUse hook crash → non-zero exit → Claude Code treats as "hook error, proceed normally." The BOM crash (Phase 3.96 fix) produced orphans because `ConvertFrom-Json` threw on BOM-prefixed manifest JSON, causing exit 1.

## CAPI Actuator Boundary

CAPI (CODEAPI) is Robert's separate IDE actuator program. It is NOT part of the Helios security architecture. Helios gates the outer CAPI-Term invocation at the shell level. CAPI terminal commands require a declared workspace, target repo, semantic operation, and write impact in the gate.

## Rebaseline Process

Two methods:

### Method 1: Maintenance Corridor (during drift)
1. Create `maintenance/rebaseline-request.json` per schema.
2. Trigger any shell command — the front controller performs internal rebaseline.
3. Retry the command — envelope is now clean.

### Method 2: Manual Tool (no current drift)
1. Run `tools/New-HeliosEnvelopeManifest.ps1 -GateRoot <path> -RebaselinedBy human`.
2. Verify: `tools/Test-HeliosEnvelopeIntegrity.ps1 -GateRoot <path>`.
3. Next gated command creates a new session baseline automatically.

## Schemas

See `schemas/` for JSON Schema definitions:

- `helios-envelope.v1.schema.json` — durable manifest
- `helios-baseline.v1.schema.json` — session baseline
- `helios-command-evidence.v1.schema.json` — per-command evidence
- `helios-maintenance-rebaseline.v1.schema.json` — maintenance rebaseline request
