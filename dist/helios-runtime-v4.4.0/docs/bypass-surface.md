# Bypass Surface Analysis

Current mutation risks for the Helios command-gate system, organized by attack vector, detection capability, and which layer handles each risk.

## Bypass Vectors

### 1. Direct edit of hook files

| Detail | |
|---|---|
| **Target** | `hooks/helios_pretooluse.ps1`, `hooks/gate_check.ps1`, `hooks/evidence_capture.ps1`, `hooks/tier_classifier.ps1`, `hooks/lib/HeliosIntegrityBridge.ps1` |
| **Via** | Edit tool, Write tool, NotebookEdit tool |
| **Detected by** | TCE witness (hash mismatch on next PreToolUse) |
| **Detection timing** | Next shell command (detection-on-next-shell-action) |
| **Prevented by** | Phase 4 helios-lock (filesystem locks) |
| **Risk** | Modified policy code executes if the attacker also modifies the front controller to skip integrity checks, or if the modification is to evidence_capture.ps1 (PostToolUse, not checked before execution). |

### 2. Direct move or rename of hook files

| Detail | |
|---|---|
| **Target** | Any protected file |
| **Via** | Shell command (mv, Move-Item, Rename-Item) |
| **Detected by** | TCE witness (MISSING status on next PreToolUse) |
| **Detection timing** | Next shell command |
| **Prevented by** | Phase 4 helios-lock |
| **Risk** | File appears MISSING in manifest check. Front controller denies. But the rename itself is a shell command that would trigger the hook first — so it's detected at mutation time if the command goes through the gate. Ungated shells (outside Claude Code) are a different threat model. |

### 3. Direct edit of command-policy.json

| Detail | |
|---|---|
| **Target** | `policy/command-policy.json` |
| **Via** | Edit tool, Write tool |
| **Detected by** | TCE witness (hash mismatch) |
| **Detection timing** | Next shell command |
| **Prevented by** | Phase 4 helios-lock |
| **Risk** | Tampered policy could reclassify dangerous commands to lower tiers. But the tampered policy is never loaded — front controller checks integrity before dot-sourcing tier_classifier.ps1. |

### 4. Direct edit of manifest or sidecar

| Detail | |
|---|---|
| **Target** | `manifest/helios-envelope.json`, `manifest/helios-envelope.sha256` |
| **Via** | Edit tool, Write tool |
| **Detected by** | Sidecar mismatch (if only manifest is changed). If both are changed in coordination: **not detected** without helios-lock. |
| **Detection timing** | Next shell command (partial). Never (if coordinated). |
| **Prevented by** | Phase 4 helios-lock |
| **Risk** | Coordinated manifest+sidecar replacement is the bootstrap trust gap. The attacker can make the system accept tampered protected files. This is the primary motivation for Phase 4 locks. |

### 5. Direct edit of settings.json

| Detail | |
|---|---|
| **Target** | `C:\Users\dimas\.claude\settings.json` |
| **Via** | Edit tool, Write tool |
| **Detected by** | **Nothing**. No integrity check covers this file. |
| **Detection timing** | Never |
| **Prevented by** | Phase 4 helios-lock |
| **Risk** | Removing the PreToolUse hook entry silently disables the entire gate system. All commands proceed without gate validation or integrity checks. This is the highest-severity bypass. |

### 6. Direct write of pending gates

| Detail | |
|---|---|
| **Target** | `pending/*.gate.json` |
| **Via** | Write tool, Edit tool |
| **Detected by** | Helios gate validation (schema, hash, expiry checks) |
| **Detection timing** | At gate match time (PreToolUse) |
| **Prevented by** | Gate validation logic in gate_check.ps1 |
| **Risk** | A fabricated gate file could authorize a command the human never approved. Gate validation checks command_sha256, working_directory, shell, risk_tier, required fields, and expiry — but if all fields are correctly constructed, the gate is accepted. The human rebaseline boundary is the control: humans create gates, not models. |

### 7. Direct edit of session baseline

| Detail | |
|---|---|
| **Target** | `evidence/integrity/sessions/<session_id>/baseline.json` |
| **Via** | Edit tool, Write tool |
| **Detected by** | **Not directly detected.** The baseline is compared against current file hashes, not independently verified. |
| **Detection timing** | The durable manifest comparison still catches drift against the install-time state. Baseline tampering only masks drift that occurred after baseline creation. |
| **Prevented by** | Phase 4 helios-lock (evidence/ is writable, but baseline.json could be locked after creation) |
| **Risk** | Low — the durable manifest is the primary trust anchor. Baseline drift detection is secondary. |

### 8. Stale inflight gates

| Detail | |
|---|---|
| **Target** | `inflight/*.gate.json` |
| **Via** | Accumulation from crashed or interrupted sessions |
| **Detected by** | Manual review, `tools/Move-HeliosStaleGateArtifacts.ps1` |
| **Detection timing** | Manual |
| **Prevented by** | Cleanup process |
| **Risk** | Stale inflight gates are not reused (evidence_capture matches by tool_use_id). They create noise and may mask legitimate matching in edge cases. |

### 9. Templates directory manipulation

| Detail | |
|---|---|
| **Target** | `templates/operating-catalog.json` |
| **Via** | Write tool (create new file), Edit tool |
| **Detected by** | **Not detected by manifest** (templates/ is listed in required dirs but operating-catalog.json is not in the manifest hash list). |
| **Detection timing** | Never (for new file creation). tier_classifier.ps1 loads it on next command. |
| **Prevented by** | Phase 4 helios-lock (lock the templates/ directory) |
| **Risk** | An attacker can create or modify operating-catalog.json to override tier classification, potentially reclassifying dangerous commands to lower tiers. This bypasses the policy without modifying command-policy.json. **This should be added to the manifest hash list if the file exists.** |

## Layer Responsibility Summary

| Risk | TCE Witness | Helios Gate | helios-lock (Phase 4) |
|---|---|---|---|
| Hook file edit (Edit/Write) | Detects on next shell | — | Prevents |
| Hook file edit (shell) | Detects on next shell | Blocks if no gate | Prevents |
| Policy edit (Edit/Write) | Detects on next shell | — | Prevents |
| Manifest+sidecar coordinated edit | **Gap** | — | Prevents |
| settings.json edit | **Gap** | — | Prevents |
| Fabricated gate file | — | Validates schema/hash | — |
| Baseline tampering | Durable manifest catches primary drift | — | Could lock after creation |
| Stale inflight | — | — | Cleanup tool |
| Templates manipulation | **Gap** (not in manifest) | — | Prevents |
| PreToolUse crash (fail-open) | Orphan evidence diagnostic | — | — |
| Maintenance corridor abuse | Validates request fields | — | Prevents writes to maintenance/ |

### 10. PreToolUse hook crash (fail-open)

| Detail | |
|---|---|
| **Target** | `helios_pretooluse.ps1` (any crash path) |
| **Via** | BOM in manifest, malformed JSON, uncaught exception |
| **Detected by** | PostToolUse orphan evidence (orphan correlation IDs) |
| **Detection timing** | After execution (PostToolUse) — command already ran |
| **Prevented by** | BOM-safe parsing (Phase 3.96 fix), fail-closed error handling |
| **Risk** | Claude Code treats non-zero exit from PreToolUse as "hook error, proceed normally." A crash silently allows ALL commands. The BOM crash (Phase 3.96 root cause) produced orphan evidence but no PreToolUse denials. |

### 11. Maintenance corridor abuse

| Detail | |
|---|---|
| **Target** | `maintenance/rebaseline-request.json` |
| **Via** | Write tool (create request during drift) |
| **Detected by** | Front controller validates request: schema_version, write_mode, base_manifest_hash vs sidecar, expected_drift_paths exact match, expiry |
| **Detection timing** | At validation time (PreToolUse) |
| **Prevented by** | Validation logic: request must name the exact drifted files and match the current sidecar hash |
| **Risk** | An attacker who controls the drift AND the maintenance request could authorize their own rebaseline. Mitigated by: (a) the request must specify the exact drifted paths, (b) base_manifest_hash must match the sidecar at request creation time, (c) human authorization is required to create the request. Phase 4 helios-lock would prevent unauthorized writes to `maintenance/`. |

## Cleanup and Archive Requirements

- Stale pending gates: archive to `evidence/stale/` via `Move-HeliosStaleGateArtifacts.ps1`.
- Stale inflight gates: same tool.
- Obsolete helper scripts (e.g., `compute-hashes.ps1`): archive to `evidence/stale/`.
- Run cleanup before Phase 4 to establish a clean locked baseline.
